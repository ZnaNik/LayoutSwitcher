import Cocoa
import IOKit.pwr_mgt
import IOKit.ps
import CoreAudio
import AudioToolbox

// MARK: - Режим «отошёл» (AppKit-обвязка; логика гашения в away.swift)
//
// Владелец уходит от Мака, но сессии на нём должны работать, а внешний монитор и Parsec
// не должны отваливаться. Системное гашение/сон дисплея для этого не годится (у владельца
// блокировка через 300 с после гашения, а при сне дисплея Parsec и монитор теряются).
// Поэтому гасим сами: чёрные окна поверх всего + яркость встроенного экрана в 0.
// Дисплей системно не спит, Мак не спит, блокировки нет.
// Любое движение мыши или клавиша возвращает экран; режим остаётся включён до повторного
// Cmd+Option+\ .
//
// Три добавки к гашению:
//  1. Звук: пока экран чёрный, выход по умолчанию заглушён (CoreAudio), вернулся экран — звук вернулся.
//     Возвращаем только то, что заглушили сами.
//  2. Батарея: раз в 30 с, если питание от батареи и заряд ниже порога (defaults awayBatteryMin,
//     по умолчанию 20), режим сам выключается.
//  3. Настоящее выключение встроенного экрана (приватный SkyLight, как у Lunar): только если есть
//     хотя бы ещё один активный экран. Единственный экран не выключается никогда (чёрное окно + яркость 0).

/// Флаг «режим включён» для внешних скриптов (~/bin/sleep-policy.sh): файл есть = режим включён.
let awayFlagPath = "/tmp/.layoutswitcher-away"
/// Ключ UserDefaults с яркостью до гашения: переживает падение и kill -9, возвращается при старте.
let awaySavedBrightnessKey = "awaySavedBrightness"
/// Ключи UserDefaults для звука: глушили мы (Bool) и громкость до гашения (Double, если шли через громкость).
let awayMutedByUsKey = "awayMutedByUs"
let awaySavedVolumeKey = "awaySavedVolume"
/// Ключ UserDefaults с ID встроенного экрана, выключенного нами: возвращается при старте, если ключ остался.
let awayDisabledDisplayKey = "awayDisabledDisplay"
/// Порог заряда батареи (проценты): ниже него на батарее режим выключается. defaults write ... awayBatteryMin 30
let awayBatteryMinKey = "awayBatteryMin"
let awayBatteryMinDefault = 20
/// Как часто смотреть на заряд, секунды.
let awayBatteryCheckInterval: TimeInterval = 30
/// Горячая клавиша: тот же keycode, что у скриншота, флаги ровно Cmd+Option.
let awayHotkeyFlags: CGEventFlags = [.maskCommand, .maskAlternate]
let awayAssertionName = "LayoutSwitcher: режим отошёл"

private let awayMode = AwayMode()
private var awayTimer: Timer?
private var awayWindows: [NSWindow] = []
private var awayStatusItem: NSStatusItem?
private var awayDisplayAssertion: IOPMAssertionID = 0
private var awaySystemAssertion: IOPMAssertionID = 0
private var awaySavedBrightness: Float?
private var awayBrightnessDisplay: CGDirectDisplayID = 0
private var awayScreenObserver: NSObjectProtocol?
private var awaySigtermSource: DispatchSourceSignal?
private var awayBatteryTimer: Timer?
/// Устройство вывода, которое заглушили мы (0 = не помним; при старте берём выход по умолчанию).
private var awayMutedDevice: AudioObjectID = 0
/// Встроенный экран, выключенный нами (нет = не выключали).
private var awayDisabledDisplay: CGDirectDisplayID?
/// Не чаще раза в 5 с повторять неудавшийся аварийный возврат встроенного экрана.
private var awaySafetyRetryAfter = Date.distantPast

// MARK: Яркость встроенного экрана (приватный DisplayServices, без него молча работаем без яркости)

private typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

private let displayServices: (get: DSGetBrightness, set: DSSetBrightness)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
          let setSym = dlsym(handle, "DisplayServicesSetBrightness") else {
        mtswipe_log("away: DisplayServices недоступен, яркость не трогаем")
        return nil
    }
    return (unsafeBitCast(getSym, to: DSGetBrightness.self),
            unsafeBitCast(setSym, to: DSSetBrightness.self))
}()

/// Встроенный экран: главный, если он встроенный, иначе первый встроенный из подключённых.
private func awayBuiltinDisplay() -> CGDirectDisplayID? {
    let mainID = CGMainDisplayID()
    if CGDisplayIsBuiltin(mainID) != 0 { return mainID }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
    return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
}

private func awayDimBrightness() {
    if awayDisabledDisplay != nil { return }  // встроенный выключен целиком: яркость ему уже не нужна
    guard let ds = displayServices, let display = awayBuiltinDisplay() else { return }
    if awaySavedBrightness == nil {
        var current: Float = 0
        guard ds.get(display, &current) == 0 else {
            mtswipe_log("away: не удалось прочитать яркость, не трогаем")
            return
        }
        awaySavedBrightness = current
        awayBrightnessDisplay = display
        UserDefaults.standard.set(Double(current), forKey: awaySavedBrightnessKey)
        UserDefaults.standard.synchronize()
    }
    if ds.set(display, 0) != 0 { mtswipe_log("away: не удалось выставить яркость 0") }
}

/// Вернуть яркость: сразу после включения встроенного экрана он может ещё не отвечать,
/// поэтому до 3 попыток с паузой 0.3 с (пауза только после неудачи).
private func awaySetBrightnessWithRetry(_ ds: (get: DSGetBrightness, set: DSSetBrightness),
                                        _ display: CGDirectDisplayID, _ value: Float) -> Int32 {
    var rc = ds.set(display, value)
    var attempt = 1
    while rc != 0 && attempt < 3 {
        Thread.sleep(forTimeInterval: 0.3)
        rc = ds.set(display, value)
        attempt += 1
    }
    return rc
}

private func awayRestoreBrightness() {
    if let saved = awaySavedBrightness, let ds = displayServices {
        if awaySetBrightnessWithRetry(ds, awayBrightnessDisplay, saved) != 0 { mtswipe_log("away: не удалось вернуть яркость") }
    }
    awaySavedBrightness = nil
    UserDefaults.standard.removeObject(forKey: awaySavedBrightnessKey)
    UserDefaults.standard.synchronize()
}

/// При старте: если прошлый процесс погиб погашенным, яркость лежит в UserDefaults.
private func awayRestoreBrightnessLeftover() {
    guard let saved = UserDefaults.standard.object(forKey: awaySavedBrightnessKey) as? Double else { return }
    if let ds = displayServices, let display = awayBuiltinDisplay() {
        let rc = awaySetBrightnessWithRetry(ds, display, Float(saved))
        mtswipe_log("away: вернул яркость после прошлого запуска (\(saved)), код \(rc)")
    }
    UserDefaults.standard.removeObject(forKey: awaySavedBrightnessKey)
    UserDefaults.standard.synchronize()
}

// MARK: Звук (CoreAudio): пока экран чёрный, звук выключен

private func awayAudioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(mSelector: selector,
                                      mScope: kAudioDevicePropertyScopeOutput,
                                      mElement: kAudioObjectPropertyElementMain)
}

/// Выход по умолчанию.
private func awayDefaultOutputDevice() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let rc = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    guard rc == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
    return device
}

/// Свойство есть у устройства и его можно менять.
private func awayAudioSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var addr = awayAudioAddress(selector)
    guard AudioObjectHasProperty(device, &addr) else { return false }
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
}

private func awayAudioGet<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = awayAudioAddress(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let rc = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
    }
    return rc == noErr ? value : nil
}

private func awayAudioSet<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> Bool {
    var addr = awayAudioAddress(selector)
    var v = value
    let rc = withUnsafePointer(to: &v) { ptr in
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
    }
    return rc == noErr
}

private func awayForgetMute() {
    UserDefaults.standard.removeObject(forKey: awayMutedByUsKey)
    UserDefaults.standard.removeObject(forKey: awaySavedVolumeKey)
    UserDefaults.standard.synchronize()
    awayMutedDevice = 0
}

/// На гашении: заглушить выход по умолчанию, если он не заглушён. Нет mute у устройства — громкость в 0
/// с запоминанием. Что заглушили мы, запоминается в UserDefaults (переживает kill -9).
private func awayMuteAudio() {
    if UserDefaults.standard.bool(forKey: awayMutedByUsKey) { return }  // уже глушили мы
    guard let device = awayDefaultOutputDevice() else {
        mtswipe_log("away: звук: нет выхода по умолчанию, не трогаем")
        return
    }
    if awayAudioSettable(device, kAudioDevicePropertyMute) {
        guard let muted = awayAudioGet(device, kAudioDevicePropertyMute, UInt32(0)) else {
            mtswipe_log("away: звук: не удалось прочитать mute, не трогаем")
            return
        }
        if muted != 0 {
            mtswipe_log("away: звук уже заглушён не нами, не трогаем")
            return
        }
        UserDefaults.standard.set(true, forKey: awayMutedByUsKey)  // ключ до действия: переживёт падение
        UserDefaults.standard.synchronize()
        awayMutedDevice = device
        if awayAudioSet(device, kAudioDevicePropertyMute, UInt32(1)) {
            mtswipe_log("away: звук заглушён (mute)")
        } else {
            mtswipe_log("away: не удалось заглушить звук (mute)")
            awayForgetMute()
        }
        return
    }
    if awayAudioSettable(device, AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)) {
        let selector = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard let volume = awayAudioGet(device, selector, Float32(0)) else {
            mtswipe_log("away: звук: не удалось прочитать громкость, не трогаем")
            return
        }
        if volume <= 0 {
            mtswipe_log("away: звук уже на нуле не нами, не трогаем")
            return
        }
        UserDefaults.standard.set(Double(volume), forKey: awaySavedVolumeKey)
        UserDefaults.standard.set(true, forKey: awayMutedByUsKey)
        UserDefaults.standard.synchronize()
        awayMutedDevice = device
        if awayAudioSet(device, selector, Float32(0)) {
            mtswipe_log("away: звук заглушён (громкость \(volume) -> 0)")
        } else {
            mtswipe_log("away: не удалось выставить громкость 0")
            awayForgetMute()
        }
        return
    }
    mtswipe_log("away: у выхода нет ни mute, ни громкости, звук не трогаем")
}

/// Вернуть звук, только если глушили мы. Вызывается и на undim, и при выключении, и на SIGTERM,
/// и при старте (ключ остался от прошлого процесса; тогда устройство = выход по умолчанию).
private func awayRestoreAudio() {
    guard UserDefaults.standard.bool(forKey: awayMutedByUsKey) else { return }
    let device = awayMutedDevice != 0 ? awayMutedDevice : (awayDefaultOutputDevice() ?? 0)
    defer { awayForgetMute() }
    guard device != 0 else {
        mtswipe_log("away: звук: нет устройства для возврата")
        return
    }
    if let saved = UserDefaults.standard.object(forKey: awaySavedVolumeKey) as? Double {
        let selector = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        // Громкость уже подняли руками, пока экран был чёрный, — это не наше дело.
        if let current = awayAudioGet(device, selector, Float32(0)), current > 0.001 {
            mtswipe_log("away: громкость уже изменена вручную (\(current)), не трогаем")
        } else if awayAudioSet(device, selector, Float32(saved)) {
            mtswipe_log("away: громкость возвращена (\(saved))")
        } else {
            mtswipe_log("away: не удалось вернуть громкость")
        }
    } else if awayAudioSet(device, kAudioDevicePropertyMute, UInt32(0)) {
        mtswipe_log("away: звук включён (mute снят)")
    } else {
        mtswipe_log("away: не удалось снять mute")
    }
}

// MARK: Батарея: ниже порога на батарее режим выключается сам

/// Питание от батареи и заряд в процентах. Нет встроенной батареи (десктоп): (false, nil).
private func awayReadBattery() -> (onBattery: Bool, percent: Int?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return (false, nil)
    }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        var percent: Int?
        if let current = desc[kIOPSCurrentCapacityKey] as? Int,
           let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 {
            percent = current * 100 / maxCapacity
        }
        return (onBattery, percent)
    }
    return (false, nil)
}

private func awayBatteryMinPercent() -> Int {
    return (UserDefaults.standard.object(forKey: awayBatteryMinKey) as? NSNumber)?.intValue ?? awayBatteryMinDefault
}

private func awayBatteryCheck() {
    guard awayMode.enabled else { return }
    let minPercent = awayBatteryMinPercent()
    let battery = awayReadBattery()
    guard awayShouldStopForBattery(onBattery: battery.onBattery, percent: battery.percent, minPercent: minPercent),
          let percent = battery.percent else { return }
    mtswipe_log("away: заряд \(percent)% ниже порога \(minPercent)%, режим выключаю")
    awayTurnOff()  // вернёт экран, яркость, звук и встроенный дисплей
    showHUD("🌙 Режим «отошёл» выключен: заряд \(percent)%")  // позже плашки «выключен» и заменяет её
}

private func awayStartBatteryTimer() {
    awayBatteryTimer?.invalidate()
    let t = Timer(timeInterval: awayBatteryCheckInterval, repeats: true) { _ in awayBatteryCheck() }
    RunLoop.main.add(t, forMode: .common)
    awayBatteryTimer = t
}

private func awayStopBatteryTimer() {
    awayBatteryTimer?.invalidate()
    awayBatteryTimer = nil
}

// MARK: Настоящее выключение встроенного экрана (приватный SkyLight; нет символа — остаёмся на яркости)

private typealias CGSConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

private let skyLightConfigureDisplayEnabled: CGSConfigureDisplayEnabledFn? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else {
        mtswipe_log("away: SkyLight недоступен, встроенный экран остаётся на яркости")
        return nil
    }
    return unsafeBitCast(sym, to: CGSConfigureDisplayEnabledFn.self)
}()

private func awayActiveDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

/// Включить или выключить экран на время сессии.
private func awaySetDisplayEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> CGError {
    guard let configure = skyLightConfigureDisplayEnabled else { return .failure }
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let cfg = config else { return begin == .success ? .failure : begin }
    let rc = configure(cfg, display, enabled)
    if rc != .success {
        CGCancelDisplayConfiguration(cfg)
        return rc
    }
    return CGCompleteDisplayConfiguration(cfg, .forSession)
}

/// ID выключенного нами экрана: в памяти, а после падения процесса из UserDefaults.
private func awayDisabledDisplayID() -> CGDirectDisplayID? {
    if let d = awayDisabledDisplay { return d }
    if let stored = UserDefaults.standard.object(forKey: awayDisabledDisplayKey) as? Int, stored > 0 {
        return CGDirectDisplayID(stored)
    }
    return nil
}

/// На гашении: выключить встроенный экран, но только если есть хотя бы один другой активный.
private func awayDisableBuiltinDisplay() {
    guard awayDisabledDisplayID() == nil, skyLightConfigureDisplayEnabled != nil,
          let builtin = awayBuiltinDisplay() else { return }
    let active = awayActiveDisplays()
    guard awayShouldDisableBuiltin(activeDisplays: active.count, builtinActive: active.contains(builtin)) else {
        return  // единственный экран: как раньше, чёрное окно + яркость 0
    }
    UserDefaults.standard.set(Int(builtin), forKey: awayDisabledDisplayKey)  // ключ до действия
    UserDefaults.standard.synchronize()
    let rc = awaySetDisplayEnabled(builtin, false)
    if rc == .success {
        awayDisabledDisplay = builtin
        mtswipe_log("away: встроенный экран \(builtin) выключен (активных экранов было \(active.count))")
    } else {
        UserDefaults.standard.removeObject(forKey: awayDisabledDisplayKey)
        UserDefaults.standard.synchronize()
        mtswipe_log("away: не удалось выключить встроенный экран \(builtin), код \(rc.rawValue); остаёмся на яркости")
    }
}

/// Включить встроенный экран обратно и удалить ключ. До 3 попыток с паузой 0.3 с, каждая ошибка в лог.
/// Неудача: ключ остаётся, следующий возврат (undim, выключение, SIGTERM, старт) попробует снова.
@discardableResult
private func awayRestoreBuiltinDisplay() -> Bool {
    guard let display = awayDisabledDisplayID() else { return true }
    for attempt in 1...3 {
        let rc = awaySetDisplayEnabled(display, true)
        if rc == .success {
            awayDisabledDisplay = nil
            UserDefaults.standard.removeObject(forKey: awayDisabledDisplayKey)
            UserDefaults.standard.synchronize()
            mtswipe_log("away: встроенный экран \(display) включён")
            return true
        }
        mtswipe_log("away: не удалось включить встроенный экран \(display), попытка \(attempt)/3, код \(rc.rawValue)")
        if attempt < 3 { Thread.sleep(forTimeInterval: 0.3) }
    }
    return false
}

/// Защита от бага Lunar: внешний отключили, а встроенный остался выключенным нами — вернуть сразу.
/// Истина, если встроенный вернули (тогда его надо снова накрыть чёрным окном).
private func awayCheckBuiltinSafety() -> Bool {
    guard let disabled = awayDisabledDisplayID() else { return false }
    let others = awayActiveDisplays().filter { $0 != disabled }
    guard awayShouldRestoreBuiltin(otherActiveDisplays: others.count), Date() >= awaySafetyRetryAfter else { return false }
    mtswipe_log("away: кроме выключенного встроенного активных экранов нет, возвращаю его сразу")
    if awayRestoreBuiltinDisplay() { return true }
    awaySafetyRetryAfter = Date().addingTimeInterval(5)
    return false
}

// MARK: Чёрные окна

private func awayRemoveWindows() {
    for w in awayWindows { w.orderOut(nil) }
    awayWindows.removeAll()
}

private func awayBuildWindows() {
    awayRemoveWindows()
    for screen in NSScreen.screens {
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.setFrame(screen.frame, display: false)
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false  // как у HUD: иначе close() освобождает окно раньше времени
        win.orderFrontRegardless()
        awayWindows.append(win)
    }
}

private func awayDim() {
    awayBuildWindows()
    awayDimBrightness()   // яркость 0 до выключения экрана: запомнится и вернётся после включения
    awayMuteAudio()
    awayDisableBuiltinDisplay()  // окна на оставшихся экранах перестроит didChangeScreenParameters
    mtswipe_log("away: экран погашен, окон \(awayWindows.count), встроенный выключен: \(awayDisabledDisplay != nil)")
}

private func awayUndim() {
    awayRemoveWindows()
    awayRestoreBuiltinDisplay()  // сначала экран, потом яркость: выключенному яркость не вернуть
    awayRestoreBrightness()
    awayRestoreAudio()
    mtswipe_log("away: экран возвращён")
}

private func awayApply(_ action: AwayAction) {
    switch action {
    case .dim: awayDim()
    case .undim: awayUndim()
    case .none: break
    }
}

// MARK: Не давать системе гасить дисплей и спать

private func awayHoldAssertions() {
    let name = awayAssertionName as CFString
    var displayID: IOPMAssertionID = 0
    var systemID: IOPMAssertionID = 0
    let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
    if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, level, name, &displayID) == kIOReturnSuccess {
        awayDisplayAssertion = displayID
    } else {
        mtswipe_log("away: не удалось создать assertion дисплея")
    }
    if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, level, name, &systemID) == kIOReturnSuccess {
        awaySystemAssertion = systemID
    } else {
        mtswipe_log("away: не удалось создать assertion системы")
    }
}

private func awayReleaseAssertions() {
    if awayDisplayAssertion != 0 { IOPMAssertionRelease(awayDisplayAssertion); awayDisplayAssertion = 0 }
    if awaySystemAssertion != 0 { IOPMAssertionRelease(awaySystemAssertion); awaySystemAssertion = 0 }
}

// MARK: Значок в строке меню

private final class AwayMenuTarget: NSObject {
    @objc func turnOff() { awayTurnOff() }
}
private let awayMenuTarget = AwayMenuTarget()

private func awayShowStatusItem() {
    guard awayStatusItem == nil else { return }
    // Строка меню у владельца переполнена: новый значок встаёт левее всех и прячется за вырезом.
    // Место справа (от правого края, точки) задаётся без пересборки:
    // defaults write com.nikita.layoutswitcher awayIconRightOffset 260
    let offset = UserDefaults.standard.object(forKey: "awayIconRightOffset") as? Double ?? 260
    UserDefaults.standard.set(offset, forKey: "NSStatusItem Preferred Position layoutswitcher-away")
    UserDefaults.standard.set(true, forKey: "NSStatusItem Visible layoutswitcher-away")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "layoutswitcher-away"
    if let button = item.button {
        if let img = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Режим «отошёл»") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "🌙"
        }
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    let info = NSMenuItem(title: "Режим «отошёл» включён", action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    let off = NSMenuItem(title: "Выключить (⌘⌥\\)", action: #selector(AwayMenuTarget.turnOff), keyEquivalent: "")
    off.target = awayMenuTarget
    off.isEnabled = true
    menu.addItem(off)
    item.menu = menu
    awayStatusItem = item
}

private func awayHideStatusItem() {
    if let item = awayStatusItem { NSStatusBar.system.removeStatusItem(item) }
    awayStatusItem = nil
}

// MARK: Таймер простоя

private func awayTick() {
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: CGEventType(rawValue: ~0)!)
    awayApply(awayMode.tick(idle: idle))
    // Запасной путь к didChangeScreenParameters: если встроенный выключен нами, а внешнего уже нет.
    if awayMode.dimmed, awayDisabledDisplay != nil, awayCheckBuiltinSafety() {
        awayBuildWindows()
        awayDimBrightness()
    }
}

private func awayStartTimer() {
    awayTimer?.invalidate()
    let t = Timer(timeInterval: 0.5, repeats: true) { _ in awayTick() }
    RunLoop.main.add(t, forMode: .common)  // .common: тикает и пока открыто меню значка
    awayTimer = t
}

private func awayStopTimer() {
    awayTimer?.invalidate()
    awayTimer = nil
}

// MARK: Включение и выключение (всё на главном потоке)

private func awayActivate() {
    awayHoldAssertions()
    FileManager.default.createFile(atPath: awayFlagPath, contents: Data())
    awayShowStatusItem()
    awayStartTimer()
    awayStartBatteryTimer()
    mtswipe_log("away: режим включён")
    showHUD("🌙  Режим «отошёл»: экран погаснет через \(Int(awayMode.delay)) с простоя")
    awayBatteryCheck()  // сразу, не ждать 30 с: на разряженной батарее режим не включится
}

private func awayDeactivate() {
    awayStopTimer()
    awayStopBatteryTimer()
    awayReleaseAssertions()
    try? FileManager.default.removeItem(atPath: awayFlagPath)
    awayHideStatusItem()
    mtswipe_log("away: режим выключен")
}

/// Горячая клавиша Cmd+Option+\ и пункт меню.
func awayToggle() {
    let wasEnabled = awayMode.enabled
    let action = awayMode.toggle()
    if !wasEnabled {
        awayActivate()
    } else {
        awayApply(action)  // .undim, если экран был погашен
        awayDeactivate()
        showHUD("🌙  Режим «отошёл» выключен")
    }
}

func awayTurnOff() {
    if awayMode.enabled { awayToggle() }
}

/// SIGTERM от launchd: вернуть экран, снять assertion и флаг, выйти.
private func awayShutdown() {
    if awayMode.enabled {
        awayApply(awayMode.toggle())
        awayDeactivate()
    }
    awayRestoreBuiltinDisplay()
    awayRestoreBrightness()
    awayRestoreAudio()
    try? FileManager.default.removeItem(atPath: awayFlagPath)
    exit(0)
}

/// Вызывается один раз при старте приложения, до app.run().
func awayStartup() {
    awayRestoreBuiltinDisplay()  // ключ остался: сначала вернуть экран, иначе яркость вернуть некому
    awayRestoreBrightnessLeftover()
    awayRestoreAudio()           // ключ остался: вернуть звук (устройство = выход по умолчанию)
    try? FileManager.default.removeItem(atPath: awayFlagPath)  // после перезапуска режим выключен

    awayScreenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        guard awayMode.dimmed else { return }
        _ = awayCheckBuiltinSafety()  // внешний отключили: встроенный вернуть сразу
        awayBuildWindows()
        awayDimBrightness()           // выключенному нами встроенному яркость не трогаем
    }

    signal(SIGTERM, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    src.setEventHandler { awayShutdown() }
    src.resume()
    awaySigtermSource = src
}
