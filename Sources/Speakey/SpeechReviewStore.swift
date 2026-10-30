import Foundation
import CryptoKit
import Darwin

struct SpeechReviewItem {
    let id: UUID
    let modified: Date
}

struct SpeechReviewCorrection: Codable {
    let id: UUID
    let reference: String
    let editedText: String
    let sessionID: String
    let split: String
    let silence: Bool
}

struct SpeechReviewDocument {
    let snapshot: SpeechDiagnosticTrace.Snapshot
    let correction: SpeechReviewCorrection?
}

/// Эталоны подтверждаются человеком и хранятся отдельно от диагностики и истории.
struct SpeechReviewStore {
    enum Failure: Error, LocalizedError {
        case unsafePath, invalidFile, invalidTrace, invalidCorrection, conflictingSplit, missingTrace, emptyExport, outputInsideProject
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "Симлинки и небезопасные пути запрещены."
            case .invalidFile: return "Диагностический файл повреждён или превышает допустимый размер."
            case .invalidTrace: return "Неподдерживаемая схема или формат аудио диагностики."
            case .invalidCorrection: return "Укажите эталон, сессию и выборку. Пустой эталон допустим только для тишины."
            case .conflictingSplit: return "Все записи одной сессии должны принадлежать одной выборке."
            case .missingTrace: return "Исходная диагностика подтверждённой записи удалена."
            case .emptyExport: return "Нет подтверждённых записей для экспорта."
            case .outputInsideProject: return "Выберите новый каталог за пределами репозитория."
            }
        }
    }
    let diagnosticsDirectory: URL
    let correctionsDirectory: URL
    let keyProvider: () throws -> Data
    private static var lock: NSRecursiveLock { SpeechDiagnostics.reviewLock }
    private static let maximumCiphertextBytes = 256 * 1024 * 1024

    func list() throws -> [SpeechReviewItem] {
        try records(in: diagnosticsDirectory).sorted {
            $0.modified == $1.modified ? $0.id.uuidString < $1.id.uuidString : $0.modified > $1.modified
        }
    }

    func load(id: UUID) throws -> SpeechReviewDocument {
        let snapshot = try readTrace(id: id).snapshot
        return SpeechReviewDocument(snapshot: snapshot, correction: try readCorrection(id: id))
    }

    func audio(id: UUID) throws -> Data {
        try SpeechFloatWAV.encode(pcm: readTrace(id: id).snapshot.pcmFloat32LE)
    }

    func save(_ correction: SpeechReviewCorrection) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard correctionsDirectory.standardizedFileURL != diagnosticsDirectory.standardizedFileURL else { throw Failure.unsafePath }
        try validate(correction)
        _ = try readTrace(id: correction.id)
        for item in try records(in: correctionsDirectory) where item.id != correction.id {
            guard let existing = try readCorrection(id: item.id) else { throw Failure.invalidCorrection }
            if existing.sessionID == correction.sessionID, existing.split != correction.split { throw Failure.conflictingSplit }
        }
        let plaintext = try JSONEncoder().encode(correction)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: key()).combined else { throw Failure.invalidFile }
        try prepareCorrectionsDirectory()
        let target = file(correction.id, in: correctionsDirectory)
        if exists(target) { try regularFile(target) }
        let staged = correctionsDirectory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try SpeechDiagnosticsExport.writeNew(ciphertext, to: staged)
        guard Darwin.rename(staged.path, target.path) == 0 else { throw Failure.invalidFile }
    }

    func removeCorrection(id: UUID) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try checkDirectory(correctionsDirectory, allowMissing: true)
        let target = file(id, in: correctionsDirectory)
        guard exists(target) else { return }
        try regularFile(target)
        try FileManager.default.removeItem(at: target)
    }

    /// Явная очистка эталонов, чьи исходные записи уже удалены по сроку хранения.
    func removeOrphanCorrections() throws -> Int {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try checkDirectory(diagnosticsDirectory, allowMissing: true)
        let items = try records(in: correctionsDirectory)
        var orphans: [URL] = []
        for item in items {
            let source = file(item.id, in: diagnosticsDirectory)
            var info = stat()
            if lstat(source.path, &info) == 0 {
                try regularFile(source)
            } else {
                guard errno == ENOENT else { throw Failure.unsafePath }
                orphans.append(file(item.id, in: correctionsDirectory))
            }
        }
        for orphan in orphans {
            try regularFile(orphan)
            try FileManager.default.removeItem(at: orphan)
        }
        return orphans.count
    }

    /// Открытые данные появляются только в явно выбранном новом каталоге экспорта.
    func exportConfirmed(to output: URL) throws -> Int {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try validateExportPath(output)
        let items = try records(in: correctionsDirectory)
        guard !items.isEmpty else { throw Failure.emptyExport }
        guard Darwin.mkdir(output.path, mode_t(0o700)) == 0 else { throw SpeechDiagnosticsExport.Failure.outputExists }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        var manifest = Data()
        var sessions: [String: String] = [:]
        for item in items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let correction = try readCorrection(id: item.id) else { throw Failure.invalidCorrection }
            if let split = sessions[correction.sessionID], split != correction.split { throw Failure.conflictingSplit }
            sessions[correction.sessionID] = correction.split
            guard exists(file(item.id, in: diagnosticsDirectory)) else { throw Failure.missingTrace }
            let source = try readTrace(id: item.id)
            let audioName = item.id.uuidString + ".wav"
            let wav = try SpeechFloatWAV.encode(pcm: source.snapshot.pcmFloat32LE)
            try SpeechDiagnosticsExport.writeNew(wav, to: output.appendingPathComponent(audioName))
            let row: [String: Any] = [
                "id": item.id.uuidString, "audio": audioName, "reference": correction.reference,
                "reference_confirmed": true, "edited_text": correction.editedText,
                "session_id": correction.sessionID, "split": correction.split, "silence": correction.silence,
                "language": source.snapshot.configuration["language"] ?? "auto",
                "kind": correction.silence ? "silence" : "speech",
                "duration_seconds": Double(source.snapshot.pcmFloat32LE.count / 4) / 16000,
                "input_wav_sha256": digest(wav), "reference_source": "explicit_user_confirmation",
                "source_trace_sha256": digest(source.ciphertext), "pcm_sha256": digest(source.snapshot.pcmFloat32LE),
                "source_schema": source.snapshot.schema
            ]
            manifest.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            manifest.append(0x0a)
        }
        try SpeechDiagnosticsExport.writeNew(manifest, to: output.appendingPathComponent("manifest.jsonl"))
        complete = true
        return items.count
    }

    private func readTrace(id: UUID) throws -> (snapshot: SpeechDiagnosticTrace.Snapshot, ciphertext: Data) {
        try checkDirectory(diagnosticsDirectory)
        let ciphertext = try read(file(id, in: diagnosticsDirectory))
        let snapshot = try JSONDecoder().decode(SpeechDiagnosticTrace.Snapshot.self, from: decrypt(ciphertext))
        guard snapshot.id == id, snapshot.schema == 1, snapshot.sampleRate == 16000, snapshot.channels == 1,
              snapshot.pcmFormat == "IEEE754-float32-little-endian" else { throw Failure.invalidTrace }
        _ = try SpeechFloatWAV.encode(pcm: snapshot.pcmFloat32LE)
        return (snapshot, ciphertext)
    }

    private func readCorrection(id: UUID) throws -> SpeechReviewCorrection? {
        try checkDirectory(correctionsDirectory, allowMissing: true)
        let target = file(id, in: correctionsDirectory)
        guard exists(target) else { return nil }
        let correction = try JSONDecoder().decode(SpeechReviewCorrection.self, from: decrypt(read(target)))
        guard correction.id == id else { throw Failure.invalidCorrection }
        try validate(correction)
        return correction
    }

    private func validate(_ correction: SpeechReviewCorrection) throws {
        let session = correction.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = correction.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, session == correction.sessionID, ["train", "dev", "test"].contains(correction.split),
              correction.silence ? correction.reference.isEmpty : !reference.isEmpty else { throw Failure.invalidCorrection }
    }

    private func key() throws -> SymmetricKey {
        let data = try keyProvider()
        guard data.count == 32 else { throw SpeechDiagnosticsStore.Failure.invalidKey }
        return SymmetricKey(data: data)
    }

    private func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
    }

    private func file(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".enc")
    }

    private func records(in directory: URL) throws -> [SpeechReviewItem] {
        try checkDirectory(directory, allowMissing: true)
        guard exists(directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "enc", let id = UUID(uuidString: name), id.uuidString == name else { return nil }
            try regularFile(url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let date = attributes[.modificationDate] as? Date else { throw Failure.invalidFile }
            return SpeechReviewItem(id: id, modified: date)
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func regularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw Failure.unsafePath }
    }

    /// Проверяем каждый компонент пути, чтобы симлинк предка не обходил проверку файла.
    private func checkDirectory(_ directory: URL, allowMissing: Bool = false) throws {
        guard directory.isFileURL else { throw Failure.unsafePath }
        let path = directory.path
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if allowMissing && errno == ENOENT { return }
                throw Failure.unsafePath
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
        }
    }

    private func read(_ url: URL) throws -> Data {
        try regularFile(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 28, info.st_size <= Self.maximumCiphertextBytes else { throw Failure.invalidFile }
        let data = try handle.read(upToCount: Self.maximumCiphertextBytes + 1) ?? Data()
        guard data.count == info.st_size, data.count <= Self.maximumCiphertextBytes else { throw Failure.invalidFile }
        return data
    }

    private func prepareCorrectionsDirectory() throws {
        try checkDirectory(correctionsDirectory, allowMissing: true)
        try FileManager.default.createDirectory(at: correctionsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectory(correctionsDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: correctionsDirectory.path)
    }

    private func validateExportPath(_ output: URL) throws {
        try checkDirectory(output.deletingLastPathComponent())
        var ancestor = output.deletingLastPathComponent()
        while ancestor.path != "/" {
            if exists(ancestor.appendingPathComponent(".git")) { throw Failure.outputInsideProject }
            ancestor.deleteLastPathComponent()
        }
        let path = output.standardizedFileURL.path
        var project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while project.path != "/", !exists(project.appendingPathComponent(".git")) { project.deleteLastPathComponent() }
        var excluded = [diagnosticsDirectory.standardizedFileURL.path, correctionsDirectory.standardizedFileURL.path]
        if project.path != "/" { excluded.append(project.path) }
        guard !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw Failure.outputInsideProject }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
