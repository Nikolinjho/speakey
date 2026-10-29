import Foundation
import CryptoKit

/// Скачивание моделей whisper (ggml-*.bin). Сеть — ТОЛЬКО по явному действию пользователя
/// (кнопка «Скачать»), с честной подписью (принцип №2). Фоном ничего не качается.
///
/// ЦЕЛОСТНОСТЬ (security-аудит M3, 01.07): раньше качали с мутабельного `resolve/main/…` без проверки —
/// подменённая на HF (или через MITM с доверенным CA) модель попадала бы в парсер CoreML/whisper в
/// непесочном процессе. Теперь: (1) URL пиннится на НЕИЗМЕНЯЕМЫЙ commit-revision (контент HF адресуется
/// коммитом → байты фиксированы); (2) после скачивания СВЕРЯЕМ SHA-256 файла с зашитым ожидаемым —
/// несовпадение = отказ, файл не устанавливается.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    /// Неизменяемый commit репозитория ggerganov/whisper.cpp, на который пиннятся все модели (01.07.2026).
    private static let pinnedRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    // size — в EN-единицах (MB/GB); локализуется на показе через L10n.size(). note — КЛЮЧ L10n,
    // резолвится через L10n.t() в SettingsWindow.unifiedModels (каталог статичен, язык — на показе).
    // sha256 — ожидаемый хеш файла модели на pinnedRevision (сверяется после скачивания).
    /// ⚠️ `help` ХРАНИТСЯ ЗДЕСЬ, А НЕ ВЫВОДИТСЯ ИЗ ИМЕНИ (08.09.2026). Раньше ключ собирал
    /// SettingsWindow: `model.\(id.hasPrefix("large") ? "large" : id).help`. Пока large-модель была
    /// одна, это работало. Вторая large-* молча получила бы подсказку первой — то есть чужие цифры
    /// диска и памяти ровно в том месте, где мы обещали назвать честную цену ДО нажатия «Скачать».
    /// А любая не-large с суффиксом (medium-q5_0) показала бы человеку сырой ключ строкой: L10n.t
    /// отдаёт отсутствующий ключ как есть. `note` с самого начала был устроен правильно, ключ в
    /// записи; `help` был единственным, который угадывался.
    struct Model {
        let name: String
        let size: String
        let note: String
        let help: String
        let sha256: String
    }
    static let catalog: [Model] = [
        Model(name: "base",           size: "142 MB", note: "model.base.note",   help: "model.base.help",
              sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        Model(name: "small",          size: "466 MB", note: "model.small.note",  help: "model.small.help",
              sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        Model(name: "medium",         size: "1.5 GB", note: "model.medium.note", help: "model.medium.help",
              sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        // Ключ подсказки исторически короткий, «model.large.help», а не «model.large-v3-turbo.help».
        // Оставлен как есть, чтобы не трогать оба перевода: ради таких случаев ключ и сделан явным.
        Model(name: "large-v3-turbo", size: "1.6 GB", note: "model.large.note",  help: "model.large.help",
              sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    ]

    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Bool) -> Void)?
    private var targetName = ""

    var downloadingName: String? { task != nil ? targetName : nil }

    private static func hfURL(_ name: String) -> URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(pinnedRevision)/ggml-\(name).bin")
    }

    func isInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: VoiceController.modelPath(name))
    }

    func download(_ name: String, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard task == nil,
              Self.catalog.contains(where: { $0.name == name }),
              let url = Self.hfURL(name) else { done(false); return }
        targetName = name
        onProgress = progress
        onDone = done
        kbLog("model \(name): загрузка с HuggingFace")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
    }

    private func finish(_ ok: Bool) {
        let completion = onDone
        task = nil
        onDone = nil
        onProgress = nil
        DispatchQueue.main.async { completion?(ok) }
    }

    func cancel() {
        let cancelled = task
        task = nil
        onDone = nil
        onProgress = nil
        cancelled?.cancel()
    }

    /// Удалить скачанную whisper-модель (освободить место). Файл — `ggml-<name>.bin` в models-папке.
    /// removeItem уводим в ФОН (единообразно с Parakeet: файл крупный, main-поток не морозим —
    /// см. deleteModel в ParakeetEngine, репорт 03.07.2026). completion — обратно на main.
    func delete(_ name: String, completion: @escaping (Bool) -> Void) {
        let path = VoiceController.modelPath(name)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if FileManager.default.fileExists(atPath: path) {
                do { try FileManager.default.removeItem(atPath: path); kbLog("model deleted: \(name)") }
                catch { ok = false; kbLog("model delete error \(name): \(error)") }
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask === task, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let progress = onProgress
        DispatchQueue.main.async { progress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer { s.finishTasksAndInvalidate() }
        guard downloadTask === task else { return }
        let name = targetName
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            kbLog("model \(name): сервер не отдал файл модели")
            finish(false)
            return
        }
        guard let expected = Self.catalog.first(where: { $0.name == name })?.sha256,
              let actual = Self.sha256(ofFileAt: location), actual == expected else {
            kbLog("model integrity FAIL \(name): файл отклонён")
            finish(false)
            return
        }
        guard downloadTask === task else { return }
        let dest = URL(fileURLWithPath: VoiceController.modelPath(name))
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        // Успех тоже логируем (раньше писались только ошибки) — чтобы в отчётах юзеров был полный
        // след «скачал→удалил» (диагностика репортов про модели, 16.07). Без контента — только имя.
        kbLog(ok ? "model downloaded+verified: \(name)" : "model install error \(name): move failed")
        finish(ok)
    }

    /// Потоковый SHA-256 файла по 1 МБ. Ошибка чтения означает отказ проверки.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        do {
            while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { s.finishTasksAndInvalidate() }
        guard task === self.task, let error else { return }
        kbLog("model \(targetName): не скачалось (\(error.localizedDescription))")
        finish(false)
    }
}
