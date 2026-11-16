import AppKit
import ApplicationServices

/// Изолированная проверка OCR. Запускается отдельным режимом до AppDelegate, настройки не меняет.
enum ScreenContextCheck {
    @MainActor static func run() async -> Int32 {
        setbuf(stdout, nil)
        if ProcessInfo.processInfo.environment["SPEAKEY_SCREEN_CONTEXT_PEER"] == "1" {
            let peer = window(title: "Speakey · внешний синтетический процесс", marker: "AMBER EXTERNAL WINDOW 8642",
                              rect: NSRect(x: 240, y: 260, width: 600, height: 240))
            peer.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 0
        }
        var count = 0
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        guard ScreenContextProvider.hasPermission else {
            check("Без разрешения нет текста OCR", ScreenContextProvider.shared.text(for: getpid()) == nil)
            print("SKIP: OCR не выполнен: нет разрешения записи экрана. Разрешение не запрашивалось.")
            return failures == 0 ? 77 : 1
        }
        let prior = NSWorkspace.shared.frontmostApplication
        let small = window(title: "Speakey · малое сфокусированное окно", marker: "SAPPHIRE FOCUSED SMALL 7392",
                           rect: NSRect(x: 180, y: 220, width: 580, height: 220))
        let large = window(title: "Speakey · большое фоновое окно", marker: "TOPAZ BACKGROUND LARGE 5186",
                           rect: NSRect(x: 100, y: 120, width: 1000, height: 620))
        let provider = ScreenContextProvider()
        let peer = Process()
        defer {
            if peer.isRunning { peer.terminate() }
            small.orderOut(nil)
            large.orderOut(nil)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                prior?.activate(options: [])
            }
        }
        large.makeKeyAndOrderFront(nil)
        small.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        func recognized(pid: pid_t, marker: String, foreign: Bool = false) async -> String {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                provider.refreshIfNeeded(pid: pid)
                let value: String?
                if foreign {
                    value = await Task.detached { provider.text(for: pid) }.value
                } else {
                    value = provider.text(for: pid)
                }
                if let value, value.contains(marker) { return value }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return ""
        }
        let first = await recognized(pid: getpid(), marker: "SAPPHIRE")
        check("OCR выбирает малое сфокусированное окно", first.contains("SAPPHIRE") && !first.contains("TOPAZ"))
        large.makeKeyAndOrderFront(nil)
        check("Смена окна того же процесса сразу закрывает старый кэш", provider.text(for: getpid()) == nil)
        let second = await recognized(pid: getpid(), marker: "TOPAZ")
        check("После смены окна распознан новый текст", second.contains("TOPAZ") && !second.contains("SAPPHIRE"))
        small.makeKeyAndOrderFront(nil)
        check("Возврат в малое окно не выдаёт текст большого", provider.text(for: getpid()) == nil)
        let returned = await recognized(pid: getpid(), marker: "SAPPHIRE")
        check("После возврата распознано малое окно", returned.contains("SAPPHIRE") && !returned.contains("TOPAZ"))
        check("Текст не выдаётся постороннему PID", provider.text(for: -1) == nil)

        peer.executableURL = Bundle.main.executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["SPEAKEY_SCREEN_CONTEXT_CHECK"] = "1"
        environment["SPEAKEY_SCREEN_CONTEXT_PEER"] = "1"
        peer.environment = environment
        do {
            try peer.run()
            let deadline = Date().addingTimeInterval(5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != peer.processIdentifier && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let switched = NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processIdentifier
            check("Фокус перешёл в отдельный синтетический процесс", switched)
            check("Смена процесса сразу закрывает старый кэш", switched && provider.text(for: getpid()) == nil)
            check("Внешний AX на main не вызывается", provider.text(for: peer.processIdentifier) == nil)
            if switched && AXIsProcessTrusted() {
                let external = await recognized(pid: peer.processIdentifier, marker: "AMBER", foreign: true)
                check("Публичный AX сопоставляет внешнее сфокусированное окно", external.contains("AMBER"))
            } else if !AXIsProcessTrusted() {
                print("SKIP: внешнее AX-окно: нет разрешения универсального доступа. Разрешение не запрашивалось.")
            }
            NSApp.activate(ignoringOtherApps: true)
            small.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            check("После возврата внешний кэш не выдаётся своему процессу", provider.text(for: getpid()) == nil)
        } catch {
            check("Синтетический внешний процесс запущен", false)
        }
        print("screen context native: \(count) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }

    @MainActor private static func window(title: String, marker: String, rect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let text = NSTextView(frame: NSRect(x: 16, y: 16, width: rect.width - 32, height: rect.height - 32))
        text.font = .systemFont(ofSize: 25)
        text.isRichText = false
        text.string = marker
        window.contentView?.addSubview(text)
        return window
    }
}
