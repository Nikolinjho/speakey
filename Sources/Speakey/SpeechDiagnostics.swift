import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Отдельная диагностическая запись: вход движка без потерь и приватные стадии обработки.
/// Включается только переменной окружения SPEAKEY_SPEECH_DIAGNOSTICS=1 перед запуском.
final class SpeechDiagnosticTrace: @unchecked Sendable {
    struct Event: Codable, Sendable {
        let stage: String
        let milliseconds: Double
        let text: String?
        let metadata: [String: String]
    }
    struct Snapshot: Codable, Sendable {
        let schema: Int
        let id: UUID
        let sampleRate: Int
        let channels: Int
        let pcmFormat: String
        let pcmFloat32LE: Data
        let configuration: [String: String]
        let events: [Event]
        let outcome: String
    }
    let id = UUID()
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let pcm: Data
    private let configuration: [String: String]
    private var events: [Event] = []
    private var finalized = false

    init(samples: [Float], configuration: [String: String]) {
        self.configuration = configuration
        #if _endian(little)
        pcm = samples.withUnsafeBytes { Data($0) }
        #else
        var bits = samples.map { $0.bitPattern.littleEndian }
        pcm = bits.withUnsafeBytes { Data($0) }
        #endif
    }

    func record(_ stage: String, text: String? = nil, metadata: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard !finalized else { return }
        events.append(Event(stage: stage,
                            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                            text: text, metadata: metadata))
    }

    func snapshot(outcome: String) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return makeSnapshot(outcome: outcome)
    }

    func finalize(outcome: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !finalized else { return nil }
        finalized = true
        return makeSnapshot(outcome: outcome)
    }

    private func makeSnapshot(outcome: String) -> Snapshot {
        Snapshot(schema: 1, id: id, sampleRate: 16000, channels: 1,
                        pcmFormat: "IEEE754-float32-little-endian", pcmFloat32LE: pcm,
                        configuration: configuration, events: events, outcome: outcome)
    }
}

struct SpeechDiagnosticsStore {
    enum Failure: Error { case invalidKey, missingCiphertext, keychain(OSStatus), keyVerification, missingExistingKey }
    let directory: URL
    let enabled: Bool
    let keyProvider: () throws -> Data

    func save(_ snapshot: SpeechDiagnosticTrace.Snapshot) throws -> URL? {
        guard enabled else { return nil }
        let key = try validatedKey()
        let plaintext = try JSONEncoder().encode(snapshot)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: key).combined else {
            throw Failure.missingCiphertext
        }
        // Каталог закрыт до появления первого файла, включая временный файл atomic write.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(snapshot.id.uuidString + ".enc")
        let staged = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try ciphertext.write(to: staged, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        // Hard link публикует целый файл атомарно и отказывает, если UUID уже занят.
        try FileManager.default.linkItem(at: staged, to: url)
        return url
    }

    func read(_ url: URL) throws -> SpeechDiagnosticTrace.Snapshot {
        let key = try validatedKey()
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(SpeechDiagnosticTrace.Snapshot.self, from: plaintext)
    }

    private func validatedKey() throws -> SymmetricKey {
        let data = try keyProvider()
        guard data.count == 32 else { throw Failure.invalidKey }
        return SymmetricKey(data: data)
    }
}

enum SpeechDiagnostics {
    private static let queue = DispatchQueue(label: "dev.speakey.speech-diagnostics", qos: .utility)
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speakey/speech-diagnostics", isDirectory: true)
    }
    static var enabled: Bool { ProcessInfo.processInfo.environment["SPEAKEY_SPEECH_DIAGNOSTICS"] == "1" }

    static func begin(samples: [Float], configuration: [String: String]) -> SpeechDiagnosticTrace? {
        guard enabled else { return nil }
        return SpeechDiagnosticTrace(samples: samples, configuration: configuration)
    }

    static func finish(_ trace: SpeechDiagnosticTrace?, outcome: String) {
        guard let snapshot = trace?.finalize(outcome: outcome) else { return }
        queue.async {
            let store = SpeechDiagnosticsStore(directory: directory, enabled: enabled, keyProvider: key)
            // Ошибки не содержат приватного текста. Диктовка не зависит от записи диагностики.
            do { _ = try store.save(snapshot) }
            catch { NSLog("Speakey speech diagnostics: persistence failed (%@)", snapshot.id.uuidString) }
        }
    }

    /// Ключ диагностики не связан с историей. Ошибка доступа никогда не перевыпускает ключ.
    /// Запрос запрещает диалог и не меняет глобальные настройки Security.framework.
    private static func keyQuery() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "dev.speakey.app") + ".speechdiagnostics",
            kSecAttrAccount as String: "diagnostics-aes256",
            kSecUseAuthenticationContext as String: context
        ]
    }

    private static func readExistingKey() throws -> Data? {
        var request = keyQuery()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpeechDiagnosticsStore.Failure.keychain(status) }
        guard let data = item as? Data, data.count == 32 else { throw SpeechDiagnosticsStore.Failure.invalidKey }
        return data
    }

    static func existingKeyForExport() throws -> Data {
        try SpeechDiagnosticsKey.requireExisting(read: readExistingKey)
    }

    private static func key() throws -> Data {
        let query = keyQuery()
        return try SpeechDiagnosticsKey.resolve(read: readExistingKey, create: { generated in
            var add = query
            add[kSecValueData as String] = generated
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw SpeechDiagnosticsStore.Failure.keychain(status)
            }
            return status == errSecSuccess
        }, hasRecords: {
            guard FileManager.default.fileExists(atPath: directory.path) else { return false }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .contains { $0.pathExtension == "enc" || $0.lastPathComponent.hasPrefix(".pending-") }
        })
    }
}

/// Жизненный цикл ключа отделён от Keychain API для проверок без доступа к связке.
enum SpeechDiagnosticsKey {
    static func requireExisting(read: () throws -> Data?) throws -> Data {
        guard let data = try read() else { throw SpeechDiagnosticsStore.Failure.missingExistingKey }
        guard data.count == 32 else { throw SpeechDiagnosticsStore.Failure.invalidKey }
        return data
    }

    static func resolve(read: () throws -> Data?, create: (Data) throws -> Bool,
                        hasRecords: () throws -> Bool) throws -> Data {
        if let existing = try read() {
            guard existing.count == 32 else { throw SpeechDiagnosticsStore.Failure.invalidKey }
            return existing
        }
        guard try !hasRecords() else { throw SpeechDiagnosticsStore.Failure.missingExistingKey }
        let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let created = try create(generated)
        guard let verified = try read(), verified.count == 32, !created || verified == generated else {
            throw SpeechDiagnosticsStore.Failure.keyVerification
        }
        return verified
    }
}
