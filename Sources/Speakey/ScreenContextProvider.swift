import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// OCR только доказанного сфокусированного окна. Изображение и текст остаются в памяти.
final class ScreenContextProvider {
    static let shared = ScreenContextProvider()

    private struct Focus: Equatable {
        let pid: pid_t
        let frame: CGRect
        let windowID: CGWindowID?
        let element: AXUIElement?

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.pid == rhs.pid, lhs.frame == rhs.frame, lhs.windowID == rhs.windowID else { return false }
            switch (lhs.element, rhs.element) {
            case (nil, nil): return true
            case let (a?, b?): return CFEqual(a, b)
            default: return false
            }
        }
    }
    private typealias Request = ScreenContextState<Focus>.Request
    private let lock = NSLock()
    private var state = ScreenContextState<Focus>()
    private var resolving = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Проверяется само окно, а не только PID: смена окна сразу закрывает доступ к старому тексту.
    /// Внешний AX читается только на фоновой очереди, вне event tap.
    func text(for pid: pid_t) -> String? {
        let focus = Self.focusedWindow(pid: pid)
        lock.lock(); defer { lock.unlock() }
        return state.text(focus: focus, now: Self.now)
    }

    /// Разрешение фокуса вынесено с main. Троттлинг действует внутри одного окна.
    func refreshIfNeeded(pid: pid_t) {
        lock.lock()
        guard !resolving else { lock.unlock(); return }
        resolving = true
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let request = self.prepare(pid: pid)
            guard let request else { return }
            await self.capture(request)
            self.finish(request)
        }
    }

    private func prepare(pid: pid_t) -> Request? {
        let focus = Self.focusedWindow(pid: pid)
        lock.lock(); defer { resolving = false; lock.unlock() }
        guard let focus else { state.observe(nil); return nil }
        return state.begin(focus: focus, now: Self.now)
    }

    private func finish(_ request: Request) {
        lock.lock(); defer { lock.unlock() }
        state.finish(request)
    }

    private func cached(_ request: Request, windowID: CGWindowID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state.cached(request, windowID: windowID, now: Self.now)
    }

    private func publish(_ text: String, request: Request, windowID: CGWindowID, reusingCache: Bool = false) {
        guard Self.focusedWindow(pid: request.focus.pid) == request.focus else { return }
        lock.lock(); defer { lock.unlock() }
        state.complete(request, windowID: windowID, text: text, now: Self.now, reusingCache: reusingCache)
    }

    private static func focusedWindow(pid: pid_t) -> Focus? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              ScreenWindowPolicy.allowed(pid: pid, frontmostPID: app.processIdentifier, permission: hasPermission,
                                         excluded: AutocompleteAppStore.hardExcluded.contains(bundleID)) else { return nil }
        if pid == getpid() {
            // Собственный AX может ждать main. AppKit даёт точный windowNumber без AX-запросов.
            let own: () -> Focus? = {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let window = NSApp.keyWindow, window.isVisible, !window.isMiniaturized,
                      window.windowNumber > 0 else { return nil }
                return Focus(pid: pid, frame: window.frame,
                             windowID: CGWindowID(window.windowNumber), element: nil)
            }
            return Thread.isMainThread ? own() : DispatchQueue.main.sync(execute: own)
        }
        // Публичный синхронный API не блокирует main ожиданием другого приложения.
        guard !Thread.isMainThread, AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let raw = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.05)
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid,
              let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position as AnyObject, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size as AnyObject, to: AXValue.self), .cgSize, &dimensions),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = attribute(application, kAXFocusedWindowAttribute), CFEqual(current, window) else { return nil }
        // AXPosition и SCWindow.frame используют глобальные координаты с началом сверху слева.
        return Focus(pid: pid, frame: CGRect(origin: point, size: dimensions), windowID: nil, element: window)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func capture(_ request: Request) async {
        guard #available(macOS 14.0, *) else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let focus = request.focus
            guard Self.focusedWindow(pid: focus.pid) == focus else { return }
            let candidates = content.windows.map {
                ScreenWindowCandidate(pid: $0.owningApplication?.processID ?? 0, id: $0.windowID,
                                      layer: $0.windowLayer, frame: $0.frame)
            }
            guard let windowID = ScreenWindowPolicy.select(pid: focus.pid, frame: focus.frame,
                                                           windowID: focus.windowID, from: candidates),
                  let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
            if let text = cached(request, windowID: windowID) {
                publish(text, request: request, windowID: windowID, reusingCache: true)
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(min(window.frame.width * 2, 3000))
            configuration.height = Int(min(window.frame.height * 2, 3000))
            configuration.showsCursor = false
            guard Self.focusedWindow(pid: focus.pid) == focus else { return }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let text = Self.recognize(image)
            publish(text, request: request, windowID: windowID)
        } catch {
            // Нет доказанного снимка — новый текст не публикуется.
        }
    }

    private static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.recognitionLanguages = ["ru-RU", "en-US"]
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return "" }
        let lines = obs.compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(2000))
    }
}
