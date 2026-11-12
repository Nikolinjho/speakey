import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// Текст активного окна: ScreenCaptureKit -> Vision OCR. Только в памяти, на диск не пишется.
/// Окна hardExcluded приложений не снимаются. Без разрешения молча ничего не делает.
final class ScreenContextProvider {
    static let shared = ScreenContextProvider()

    private let lock = NSLock()
    private var _latest: String?
    private var lastAttempt = Date.distantPast
    /// Чей текст лежит в кэше и когда снят: чужое или старое окно в промпт не попадает (ревью 12.11).
    private var _latestPID: pid_t = 0
    private var _latestAt = Date.distantPast
    private var requestedPID: pid_t = 0
    private var inFlight = false
    private var cache: (windowID: CGWindowID, date: Date, text: String)?

    var latestText: String? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    private func finish() { lock.lock(); inFlight = false; lock.unlock() }

    private func setLatest(_ t: String?) {
        lock.lock(); _latest = t; _latestPID = requestedPID; _latestAt = Date(); lock.unlock()
    }

    /// Текст окна процесса `pid`, если он снят именно с него и не старше 15 с.
    func text(for pid: pid_t) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard _latestPID == pid, Date().timeIntervalSince(_latestAt) < 15 else { return nil }
        return _latest
    }

    /// Асинхронно, не чаще раза в 3 с. Кэш распознанного текста окна живёт 10 с.
    func refreshIfNeeded(pid: pid_t) {
        guard Self.hasPermission else { return }
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           AutocompleteAppStore.hardExcluded.contains(bid) {
            setLatest(nil); return
        }
        lock.lock()
        // Смена процесса снимает троттлинг: старый текст к новому окну не относится.
        let samePID = pid == requestedPID
        if inFlight || (samePID && Date().timeIntervalSince(lastAttempt) < 3) { lock.unlock(); return }
        inFlight = true; lastAttempt = Date(); requestedPID = pid
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            await self?.capture(pid: pid)
            self?.finish()
        }
    }

    private func capture(pid: pid_t) async {
        guard #available(macOS 14.0, *) else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let win = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let win else { setLatest(nil); return }
            if let c = cache, c.windowID == win.windowID, Date().timeIntervalSince(c.date) < 10 {
                setLatest(c.text); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = 2.0
            cfg.width = Int(min(win.frame.width * scale, 3000))
            cfg.height = Int(min(win.frame.height * scale, 3000))
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let text = Self.recognize(image)
            cache = (win.windowID, Date(), text)
            setLatest(text.isEmpty ? nil : text)
            kbLog("screen context: ocr chars=\(text.count)")
        } catch {
            setLatest(nil)
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
