import Foundation
import CryptoKit

/// Модель автодополнения в каталоге.
struct CompletionModel {
    let id, title, fileName, url, sha256: String
    let bytes: Int64
    let note: String
}

/// КАТАЛОГ МОДЕЛЕЙ АВТОДОПОЛНЕНИЯ. Как у Cotypist: лёгкая и стандартная, обе base (pretrained) —
/// base-модели дописывают чужой текст лучше instruct: им не нужно объяснять задачу, они просто
/// продолжают документ. Замер шага 0 (12.11.2026, M5 Pro, промпт ~275 токенов, набор по 1–3 символа):
/// 1.7B — p50 34 мс, p95 67 мс, ~1,4 ГБ RSS; 4B — p50 89 мс, p95 137 мс, ~2,8 ГБ. Обе в цели 200 мс,
/// по умолчанию лёгкая: на M1/M2 запас нужнее. Gemma 3 pt на HF закрыта логином — не берём.
///
/// Сеть — только здесь и только по кнопке «Скачать». Файл сверяется по SHA-256 до того, как
/// попадёт на место; несовпадение — файл удаляется.
enum CompletionModels {
    static let all: [CompletionModel] = [
        CompletionModel(id: "qwen3-1.7b-base", title: "Qwen3 1.7B (лёгкая)",
                        fileName: "Qwen3-1.7B-Base.Q4_K_M.gguf",
                        url: "https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF/resolve/main/Qwen3-1.7B-Base.Q4_K_M.gguf",
                        sha256: "8b5d946a169e62dd49444be8858c8a7f06067573de990b2bc19380d3a260b5fa",
                        bytes: 1_107_409_024, note: "быстрая, ~1,1 ГБ"),
        CompletionModel(id: "qwen3-4b-base", title: "Qwen3 4B (стандартная)",
                        fileName: "Qwen3-4B-Base.Q4_K_M.gguf",
                        url: "https://huggingface.co/mradermacher/Qwen3-4B-Base-GGUF/resolve/main/Qwen3-4B-Base.Q4_K_M.gguf",
                        sha256: "a7eb1d92eaf34e116f8b522aeeaf4072e66d69b5b10676e0cb7cd9e11889bed6",
                        bytes: 2_497_280_736, note: "точнее, ~2,5 ГБ")
    ]

    static var defaultID: String { all[0].id }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Speakey/Models", isDirectory: true)
    }

    static func localURL(_ m: CompletionModel) -> URL { directory.appendingPathComponent(m.fileName) }

    /// Файл есть и размер совпал. SHA-256 считаем только при загрузке: на каждый запрос это секунды.
    static func isInstalled(_ m: CompletionModel) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL(m).path)
        return (attrs?[.size] as? NSNumber)?.int64Value == m.bytes
    }

    private static var active: Downloader?

    /// Колбэки — на main.
    static func download(_ m: CompletionModel, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard active == nil, let url = URL(string: m.url) else { done(false); return }
        let d = Downloader(model: m, progress: progress) { ok in
            active = nil
            done(ok)
        }
        active = d
        d.start(url)
    }

    static func delete(_ m: CompletionModel) {
        try? FileManager.default.removeItem(at: localURL(m))
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate {
        let model: CompletionModel
        let progress: (Double) -> Void
        let done: (Bool) -> Void
        private var session: URLSession?

        init(model: CompletionModel, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
            self.model = model; self.progress = progress; self.done = done
        }

        func start(_ url: URL) {
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session = s
            s.downloadTask(with: url).resume()
            kbLog("complete: загрузка модели \(model.id) начата")
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
            let expected = total > 0 ? total : model.bytes
            let p = Double(written) / Double(max(1, expected))
            DispatchQueue.main.async { self.progress(min(1, p)) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let fm = FileManager.default
            let ok: Bool
            if CompletionModels.sha256(of: location) == model.sha256 {
                try? fm.createDirectory(at: CompletionModels.directory, withIntermediateDirectories: true)
                let dest = CompletionModels.localURL(model)
                try? fm.removeItem(at: dest)
                ok = (try? fm.moveItem(at: location, to: dest)) != nil
            } else {
                ok = false
                kbLog("complete: SHA-256 модели \(model.id) не совпал — файл отброшен")
            }
            finish(ok)
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil { kbLog("complete: загрузка модели \(model.id) прервана"); finish(false) }
        }

        private var finished = false
        private func finish(_ ok: Bool) {
            DispatchQueue.main.async {
                guard !self.finished else { return }
                self.finished = true
                self.session?.finishTasksAndInvalidate()
                if ok { kbLog("complete: модель \(self.model.id) загружена и проверена") }
                self.done(ok)
            }
        }
    }
}
