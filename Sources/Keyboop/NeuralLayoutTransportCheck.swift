import AppKit
import ApplicationServices

/// Маршрутизация только собственной синтетики в скрытое поле, без активации приложения.
private final class NeuralTransportApplication: NSApplication {
    var fixture: NSTextView?
    var received = 0
    override func sendEvent(_ event: NSEvent) {
        if let cg = event.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker,
           cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
           event.type == .keyDown || event.type == .keyUp {
            received += 1
            if event.type == .keyDown, let fixture, let window = fixture.window,
               let bound = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: event.characters ?? "",
                                            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                            isARepeat: event.isARepeat, keyCode: event.keyCode) {
                // Без номера собственного окна AppKit не направляет команды Backspace в поле.
                fixture.keyDown(with: bound)
            }
            return
        }
        super.sendEvent(event)
    }
}

/// Проверка транспорта запускается до AppDelegate, Engine и настроек приложения.
enum NeuralLayoutTransportCheck {
    private final class State {
        let pid = Int64(getpid())
        let token = UInt32.random(in: 1...UInt32.max)
        lazy var marker = neuralLayoutMarkerCodec.encode(token: token)
        let handler = EventTap()
        var globalReceived = false
        var globalConsumed = false
        var processReceived = false
        var submitted = false
        var posted = 0
        var syntheticMarkersValid = true
        var deliveredEvents: [CGEvent] = []
    }

    private static let globalCallback: CGEventTapCallBack = { proxy, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard NeuralTransportEventGate.accepts(type: type, event: event, marker: state.marker, pid: state.pid) else {
            return Unmanaged.passUnretained(event)
        }
        state.globalReceived = neuralLayoutMarkerCodec.token(from: event.getIntegerValueField(.eventSourceUserData)) == state.token
        state.globalConsumed = state.handler.handle(type: type, event: event, proxy: proxy) == nil
        return nil
    }

    private static let processCallback: CGEventTapCallBack = { proxy, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard NeuralTransportEventGate.accepts(type: type, event: event, marker: state.marker, pid: state.pid) else {
            return Unmanaged.passUnretained(event)
        }
        state.processReceived = true
        state.submitted = TextReplacer.replaceInline(deleteCount: 6, with: "привет") { generated in
            state.posted += 1
            state.syntheticMarkersValid = state.syntheticMarkersValid &&
                generated.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker
            generated.tapPostEvent(proxy)
        }
        return nil
    }

    // Нижний перехватчик подтверждает доставку ОС. Только собственная синтетика направляется
    // в скрытое поле после выхода из callback, чтобы не зависеть от фокуса фонового окна.
    private static let receiptCallback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard (type == .keyDown || type == .keyUp),
              event.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker,
              event.getIntegerValueField(.eventSourceUnixProcessID) == state.pid else {
            return Unmanaged.passUnretained(event)
        }
        if let copy = event.copy() { state.deliveredEvents.append(copy) }
        return nil
    }

    private static func routeReceipts(_ state: State, app: NeuralTransportApplication, from index: Int) throws {
        for event in state.deliveredEvents.dropFirst(index) {
            guard let native = NSEvent(cgEvent: event) else {
                throw Failure(description: "OS receipt could not be converted to NSEvent")
            }
            app.sendEvent(native)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    /// Отдельный источник сохраняет полные 64 бита и PID при доставке через WindowServer.
    private static func markerEvent(_ state: State) throws -> CGEvent {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 255, keyDown: true) else {
            throw Failure(description: "marker allocation failed")
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: state.marker)
        return event
    }

    private static func withTap(_ port: CFMachPort?, body: () throws -> Void) throws {
        guard let port else { throw Failure(description: "CGEvent tap creation denied (nil); no permission request was made") }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw Failure(description: "tap run loop source allocation failed")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        defer {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
        }
        try body()
    }

    private static func wait(app: NeuralTransportApplication, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done() && Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                         inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
    }

    static func run() -> Int32 {
        // Страховка от зависания AppKit. При выходе процесс освобождает принадлежащие ему Mach-порты.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: whole fixture exceeded 10 seconds\n", stderr)
            exit(1)
        }
        setbuf(stdout, nil)
        let app = NeuralTransportApplication.shared as! NeuralTransportApplication
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: window.contentView!.bounds)
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        window.contentView = field
        window.makeFirstResponder(field)
        app.fixture = field
        defer { app.fixture = nil; window.close() }
        let state = State()
        let context = Unmanaged.passUnretained(state).toOpaque()
        state.deliveredEvents.reserveCapacity(16)
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        TextReplacer.warmUpInline()
        _ = state.marker
        kbLog("изолированная проверка транспорта: прогрев")
        print("PRECHECK: AX=\(AXIsProcessTrusted()) InputMonitoring=\(CGPreflightListenEventAccess()) (nonprompting)")
        do {
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                       options: .defaultTap, eventsOfInterest: mask,
                                       callback: globalCallback, userInfo: context)
            try withTap(tap) {
                try markerEvent(state).post(tap: .cghidEventTap)
                wait(app: app) { state.globalReceived }
                try require(state.globalReceived && state.globalConsumed, "global HID → session → EventTap.handle marker delivery unproved")
            }
            print("PASS: OS HID → session → genuine EventTap.handle; own PID, keyDown/255, full 64-bit marker/token; consumed")
        } catch {
            fputs("FAIL global: \(error)\n", stderr)
            // Независимая адресная проба всё равно выполняется.
        }
        var editingPassed = false
        do {
            let tap = CGEvent.tapCreateForPid(pid: getpid(), place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: processCallback, userInfo: context)
            try withTap(tap) {
              let receipt = CGEvent.tapCreateForPid(pid: getpid(), place: .tailAppendEventTap,
                                                  options: .defaultTap,
                                                  eventsOfInterest: mask | (CGEventMask(1) << CGEventType.keyUp.rawValue),
                                                  callback: receiptCallback, userInfo: context)
              try withTap(receipt) {
                field.string = "ghbdtn"
                field.setSelectedRange(NSRange(location: 6, length: 0))
                try markerEvent(state).postToPid(getpid())
                wait(app: app) { state.deliveredEvents.count >= 14 }
                try require(state.deliveredEvents.count == 14, "downstream own-PID OS tap received \(state.deliveredEvents.count)/14 events")
                print("PASS: downstream own-PID OS tap received 14/14 replacement events")
                try routeReceipts(state, app: app, from: 0)
                try require(state.processReceived, "postToPid marker not received by process tap")
                try require(state.submitted && state.posted == 14 && state.syntheticMarkersValid,
                            "replaceInline did not post exactly 14 correctly marked events")
                try require(app.received == 14, "AppKit received \(app.received)/14 synthetic events")
                try require(field.string == "привет" && field.selectedRange() == NSRange(location: 6, length: 0),
                            "AppKit replacement text/caret mismatch: \(String(reflecting: field.string)), \(field.selectedRange())")
                print("PASS: OS postToPid → process tap → genuine TextReplacer.replaceInline → tapPostEvent → downstream own-PID OS tap: 14/14; explicit AppKit routing: привет, caret 6")
                // Продолжение и Backspace также адресуются только этому процессу.
                let source = CGEventSource(stateID: .privateState)
                source?.userData = kbSyntheticMarker
                let continuation = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)!
                let units = Array("!".utf16)
                units.withUnsafeBufferPointer { continuation.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                continuation.flags = []
                continuation.postToPid(getpid())
                wait(app: app) { state.deliveredEvents.count >= 15 }
                try routeReceipts(state, app: app, from: 14)
                try require(field.string == "привет!" && field.selectedRange().location == 7, "continuation text/caret mismatch")
                let backspace = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)!
                backspace.flags = []
                backspace.postToPid(getpid())
                wait(app: app) { state.deliveredEvents.count >= 16 }
                try routeReceipts(state, app: app, from: 15)
                try require(field.string == "привет" && field.selectedRange() == NSRange(location: 6, length: 0), "Backspace text/caret mismatch")
                editingPassed = true
                print("PASS: own-PID continuation and Backspace; exact text and caret")
              }
            }
        } catch { fputs("FAIL editing: \(error)\n", stderr) }
        print("SCOPE: synthetic OS transport; explicit NSApplication.sendEvent → NSTextView.keyDown routing in hidden fixture; no activation, physical input, natural focus routing, Engine policy or mailbox proof")
        return state.globalReceived && state.globalConsumed && editingPassed ? 0 : 1
    }
}
