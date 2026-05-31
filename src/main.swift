import Cocoa
import Carbon.HIToolbox

// MARK: - Input Source Switching

func getKeyboardInputSources() -> [TISInputSource] {
    guard let rawList = TISCreateInputSourceList(nil, false) else { return [] }
    let list = rawList.takeRetainedValue() as! [TISInputSource]
    return list.filter { source in
        func boolProp(_ key: CFString) -> Bool {
            guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
            return CFBooleanGetValue(unsafeBitCast(ptr, to: CFBoolean.self))
        }
        func strProp(_ key: CFString) -> String {
            guard let ptr = TISGetInputSourceProperty(source, key) else { return "" }
            return unsafeBitCast(ptr, to: CFString.self) as String
        }
        return strProp(kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String)
            && boolProp(kTISPropertyInputSourceIsEnabled)
            && boolProp(kTISPropertyInputSourceIsSelectCapable)
    }
}

func sourceID(_ s: TISInputSource) -> String {
    guard let ptr = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
    return unsafeBitCast(ptr, to: CFString.self) as String
}

func switchToNextInputSource() {
    let sources = getKeyboardInputSources()
    guard sources.count > 1 else { return }
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
    let currentID = sourceID(current)
    if let idx = sources.firstIndex(where: { sourceID($0) == currentID }) {
        TISSelectInputSource(sources[(idx + 1) % sources.count])
    } else {
        TISSelectInputSource(sources[0])
    }
}

// MARK: - HUD окошко (как в Lightshot, не зависит от системных уведомлений)

var hudWindow: NSWindow?

func showHUD(_ text: String) {
    DispatchQueue.main.async {
        hudWindow?.close()

        let padding: CGFloat = 20
        let accentWidth: CGFloat = 5
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let textColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 1.0, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let w = min(textSize.width + padding * 2 + accentWidth, 580)
        let h: CGFloat = 48

        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - w / 2
        let y = screen.frame.minY + 90

        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.hasShadow = true

        // Тёмная непрозрачная плашка — высокий контраст, хорошо читается
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.18, alpha: 0.97).cgColor
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.0, alpha: 0.5).cgColor

        // Левая акцентная полоска (бирюзово-синяя)
        let accent = NSView(frame: NSRect(x: 0, y: 0, width: accentWidth, height: h))
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.55, alpha: 1.0).cgColor
        bg.addSubview(accent)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = textColor
        label.alignment = .left
        label.frame = NSRect(x: accentWidth + padding, y: (h - textSize.height) / 2,
                             width: w - accentWidth - padding * 2, height: textSize.height)
        bg.addSubview(label)

        win.contentView = bg
        win.alphaValue = 0
        win.orderFront(nil)
        hudWindow = win

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            win.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                win.animator().alphaValue = 0
            }, completionHandler: { win.close() })
        }
    }
}

func takeScreenshot() {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Screenshots")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let stamp = fmt.string(from: Date())
    let tmpPath = (dir as NSString).appendingPathComponent("_tmp_\(stamp).png")
    let jpgPath = (dir as NSString).appendingPathComponent("ss_\(stamp).jpg")

    // 0.5s — чтобы клавиши отпустились до старта screencapture
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", tmpPath]   // интерактивный выбор области → временный PNG
        try? task.run()
        task.waitUntilExit()

        guard FileManager.default.fileExists(atPath: tmpPath) else { return }

        DispatchQueue.main.async {
            var finalPath = tmpPath
            var sizeKB = 0

            // Сжатие PNG → JPEG (quality 0.6) для меньшего размера
            if let img = NSImage(contentsOfFile: tmpPath),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                try? jpg.write(to: URL(fileURLWithPath: jpgPath))
                try? FileManager.default.removeItem(atPath: tmpPath)  // удаляем PNG
                finalPath = jpgPath
                sizeKB = jpg.count / 1024
            }

            // 1. В буфер обмена
            if let finalImg = NSImage(contentsOfFile: finalPath) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([finalImg])
            }
            // 2. Звук
            NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)?.play()
            // 3. HUD-окошко с именем файла и размером
            let name = (finalPath as NSString).lastPathComponent
            showHUD("📸  \(name)  ·  \(sizeKB) КБ  ·  скопирован в буфер")
        }
    }
}

// MARK: - Видеозапись через нативную панель macOS (Screenshot.app)
// Это панель Cmd+Shift+5: выбор области, запись видео, звук, старт/стоп — всё родное и надёжное.

func openNativeRecorder() {
    // Эмулируем Cmd+Shift+5 → нативная панель с выбором области для видео
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
    let key: CGKeyCode = 23  // клавиша «5»
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    down?.flags = [.maskCommand, .maskShift]
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    up?.flags = [.maskCommand, .maskShift]
    up?.post(tap: .cghidEventTap)
}

// MARK: - Event Tap

private var lastRelevant: CGEventFlags = []
private var comboDirty = false

let targetCombo: CGEventFlags = [.maskCommand, .maskShift]
let watchedMods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

// Keycode читается из defaults: defaults write com.nikita.layoutswitcher screenshotKeycode 42
// 42 = backslash \  |  50 = backtick `  |  14 = e/у
let screenshotKeycode: Int64 = {
    let v = UserDefaults.standard.integer(forKey: "screenshotKeycode")
    return v > 0 ? Int64(v) : 42
}()

func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {

    case .keyDown:
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = CGEventFlags(rawValue: event.flags.rawValue & watchedMods.rawValue)

        comboDirty = true  // любой keyDown отменяет ожидание чистого Cmd+Shift (раскладки)

        // Cmd + \ (keycode 42)  →  скриншот
        if keycode == screenshotKeycode && flags == .maskCommand {
            DispatchQueue.global().async { takeScreenshot() }
            return nil
        }

        // Cmd+Shift+\ (keycode 42)  ИЛИ  F12 (keycode 111)  →  панель записи macOS
        if (keycode == screenshotKeycode && flags == targetCombo) ||
           (keycode == 111 && flags.isEmpty) {
            DispatchQueue.main.async { openNativeRecorder() }
            return nil
        }

    case .flagsChanged:
        let flags    = event.flags
        let relevant = CGEventFlags(rawValue: flags.rawValue & watchedMods.rawValue)

        if relevant == targetCombo {
            if lastRelevant != targetCombo { comboDirty = false }
        } else if lastRelevant == targetCombo && !comboDirty {
            DispatchQueue.main.async { switchToNextInputSource() }
        }

        lastRelevant = relevant

    default:
        break
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Accessibility

func requestAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) {
        startTap()
    } else {
        print("[LayoutSwitcher] Ожидание разрешения Accessibility...")
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if AXIsProcessTrusted() { t.invalidate(); startTap() }
        }
    }
}

func startTap() {
    let mask: CGEventMask =
        (1 << CGEventType.flagsChanged.rawValue) |
        (1 << CGEventType.keyDown.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { proxy, type, event, _ -> Unmanaged<CGEvent>? in
            handleEvent(proxy: proxy, type: type, event: event)
        },
        userInfo: nil
    ) else {
        print("[LayoutSwitcher] Не удалось создать event tap. Выдайте разрешение Accessibility.")
        return
    }

    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[LayoutSwitcher] Запущен.")
    print("  Cmd+Shift  → переключить раскладку")
    print("  Cmd+Ё      → скриншот → ~/Screenshots/")
}

// MARK: - Main

// Перехват необработанных исключений — чтобы случайный сбой не ронял всё приложение
NSSetUncaughtExceptionHandler { ex in
    NSLog("[LayoutSwitcher] Поймано исключение: \(ex.name) \(ex.reason ?? "")")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
requestAccessibility()
app.run()
