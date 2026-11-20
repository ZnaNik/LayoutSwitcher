import Cocoa
import IOKit.pwr_mgt

// MARK: - Режим «отошёл» (AppKit-обвязка; логика гашения в away.swift)
//
// Владелец уходит от Мака, но сессии на нём должны работать, а внешний монитор и Parsec
// не должны отваливаться. Системное гашение/сон дисплея для этого не годится (у владельца
// блокировка через 300 с после гашения, а при сне дисплея Parsec и монитор теряются).
// Поэтому гасим сами: чёрные окна поверх всего + яркость встроенного экрана в 0.
// Дисплей системно не спит, Мак не спит, блокировки нет.
// Любое движение мыши или клавиша возвращает экран; режим остаётся включён до повторного
// Cmd+Option+\ .

/// Флаг «режим включён» для внешних скриптов (~/bin/sleep-policy.sh): файл есть = режим включён.
let awayFlagPath = "/tmp/.layoutswitcher-away"
/// Ключ UserDefaults с яркостью до гашения: переживает падение и kill -9, возвращается при старте.
let awaySavedBrightnessKey = "awaySavedBrightness"
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

private func awayRestoreBrightness() {
    if let saved = awaySavedBrightness, let ds = displayServices {
        if ds.set(awayBrightnessDisplay, saved) != 0 { mtswipe_log("away: не удалось вернуть яркость") }
    }
    awaySavedBrightness = nil
    UserDefaults.standard.removeObject(forKey: awaySavedBrightnessKey)
    UserDefaults.standard.synchronize()
}

/// При старте: если прошлый процесс погиб погашенным, яркость лежит в UserDefaults.
private func awayRestoreBrightnessLeftover() {
    guard let saved = UserDefaults.standard.object(forKey: awaySavedBrightnessKey) as? Double else { return }
    if let ds = displayServices, let display = awayBuiltinDisplay() {
        let rc = ds.set(display, Float(saved))
        mtswipe_log("away: вернул яркость после прошлого запуска (\(saved)), код \(rc)")
    }
    UserDefaults.standard.removeObject(forKey: awaySavedBrightnessKey)
    UserDefaults.standard.synchronize()
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
    awayDimBrightness()
    mtswipe_log("away: экран погашен, окон \(awayWindows.count)")
}

private func awayUndim() {
    awayRemoveWindows()
    awayRestoreBrightness()
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
    mtswipe_log("away: режим включён")
    showHUD("🌙  Режим «отошёл»: экран погаснет через \(Int(awayMode.delay)) с простоя")
}

private func awayDeactivate() {
    awayStopTimer()
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
    awayRestoreBrightness()
    try? FileManager.default.removeItem(atPath: awayFlagPath)
    exit(0)
}

/// Вызывается один раз при старте приложения, до app.run().
func awayStartup() {
    awayRestoreBrightnessLeftover()
    try? FileManager.default.removeItem(atPath: awayFlagPath)  // после перезапуска режим выключен

    awayScreenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        guard awayMode.dimmed else { return }
        awayBuildWindows()
        awayDimBrightness()
    }

    signal(SIGTERM, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    src.setEventHandler { awayShutdown() }
    src.resume()
    awaySigtermSource = src
}
