import Foundation

// MARK: - Режим «отошёл»: подсветка клавиатуры (его слово 21.11.2026: «подсветка клавиатуры надо тоже убирать»)
//
// Приватный KeyboardBrightnessClient из CoreBrightness. Нет класса или методов — тихо не трогаем.
// На гашении: запомнить яркость и автоподстройку, выключить автоподстройку (иначе она поднимет свет), яркость 0.
// На возврате: вернуть яркость и автоподстройку. Запомненное лежит в UserDefaults и переживает kill -9.

private let awayKbSavedKey = "awayKeyboardSaved"  // [яркость, авто 0/1]

private let awayKbClient: NSObject? = {
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
    guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
        mtswipe_log("away: подсветка клавиатуры: нет KeyboardBrightnessClient, не трогаем")
        return nil
    }
    let c = cls.init()
    for s in ["copyKeyboardBacklightIDs", "brightnessForKeyboard:", "setBrightness:forKeyboard:",
              "isAutoBrightnessEnabledForKeyboard:", "enableAutoBrightness:forKeyboard:"] {
        guard c.responds(to: NSSelectorFromString(s)) else {
            mtswipe_log("away: подсветка клавиатуры: нет метода \(s), не трогаем")
            return nil
        }
    }
    return c
}()

private func awayKbID() -> UInt64? {
    guard let c = awayKbClient,
          let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
          let first = ids.first else { return nil }
    return first.uint64Value
}

private func awayKbGet(_ c: NSObject, _ id: UInt64) -> Float {
    typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    let sel = NSSelectorFromString("brightnessForKeyboard:")
    return unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, id)
}

private func awayKbSet(_ c: NSObject, _ id: UInt64, _ value: Float) {
    typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    let sel = NSSelectorFromString("setBrightness:forKeyboard:")
    _ = unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, value, id)
}

private func awayKbAuto(_ c: NSObject, _ id: UInt64) -> Bool {
    typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    let sel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
    return unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, id)
}

private func awayKbSetAuto(_ c: NSObject, _ id: UInt64, _ on: Bool) {
    typealias Fn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    let sel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    _ = unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, on, id)
}

/// На гашении экрана.
func awayKeyboardOff() {
    guard let c = awayKbClient, let id = awayKbID() else { return }
    if UserDefaults.standard.object(forKey: awayKbSavedKey) == nil {
        let saved = [Double(awayKbGet(c, id)), awayKbAuto(c, id) ? 1 : 0]
        UserDefaults.standard.set(saved, forKey: awayKbSavedKey)  // до действия: переживёт падение
        UserDefaults.standard.synchronize()
    }
    awayKbSetAuto(c, id, false)
    awayKbSet(c, id, 0)
    mtswipe_log("away: подсветка клавиатуры выключена")
}

/// На возврате экрана, выключении, SIGTERM и при старте (если запомненное осталось).
func awayKeyboardRestore() {
    guard let saved = UserDefaults.standard.array(forKey: awayKbSavedKey) as? [Double], saved.count == 2 else { return }
    defer {
        UserDefaults.standard.removeObject(forKey: awayKbSavedKey)
        UserDefaults.standard.synchronize()
    }
    guard let c = awayKbClient, let id = awayKbID() else { return }
    awayKbSet(c, id, Float(saved[0]))
    if saved[1] != 0 { awayKbSetAuto(c, id, true) }
    mtswipe_log("away: подсветка клавиатуры возвращена (\(saved[0]), авто \(saved[1] != 0))")
}
