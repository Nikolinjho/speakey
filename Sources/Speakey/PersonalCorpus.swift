import Foundation
import CryptoKit
import Security

/// Личный корпус набранного текста: зашифрованный AES-GCM файл `corpus.bin`, ключ в Keychain
/// (отдельный item, как у VoiceHistory). Никогда не покидает Mac. В лог — только счётчики.
final class PersonalCorpus {
    static let shared = PersonalCorpus(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speakey", isDirectory: true),
        keyProvider: { PersonalCorpus.keychainKey() }, usesKeychain: true)

    private struct Entry: Codable {
        var text: String
        var bundleID: String
        var date: TimeInterval
    }

    static let minLength = 20
    static let maxEntries = 5000

    private let fileURL: URL
    private let keyProvider: () -> SymmetricKey
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var loaded = false
    private let usesKeychain: Bool

    init(directory: URL, keyProvider: @escaping () -> SymmetricKey, usesKeychain: Bool = false) {
        self.usesKeychain = usesKeychain
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("corpus.bin")
        self.keyProvider = keyProvider
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries.count
    }

    func add(_ text: String, bundleID: String) {
        let clean = CompletionText.redactSecrets(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard clean.count >= Self.minLength else { return }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        // Та же сессия поля приходит повторно и дописанной: заменяем запись, а не плодим перекрытия —
        // иначе любое слово набирало бы частоту и лезло в частые термины (ревью 12.11).
        let now = Date().timeIntervalSince1970
        if let i = entries.indices.suffix(30).last(where: {
            entries[$0].bundleID == bundleID && (clean.hasPrefix(entries[$0].text) || entries[$0].text.hasPrefix(clean)
                || clean.hasSuffix(entries[$0].text) || entries[$0].text.hasSuffix(clean))
        }) {
            if clean.count >= entries[i].text.count { entries[i].text = clean }
            entries[i].date = now
            save()
            return
        }
        entries.append(Entry(text: clean, bundleID: bundleID, date: now))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
    }

    /// Фрагменты с наибольшим пересечением слов с `before` (хвост ~200 символов); свежесть — тай-брейк.
    func similar(to before: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let query = Set(Self.words(String(before.suffix(200))).filter { $0.count >= 3 })
        guard !query.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var scored: [(score: Int, date: TimeInterval, text: String)] = []
        for e in entries {
            let overlap = Set(Self.words(e.text)).intersection(query).count
            if overlap > 0 { scored.append((overlap, e.date, e.text)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
        return scored.prefix(limit).map { $0.text }
    }

    /// Частые слова (≥4 символов, встречаются ≥2 раз), по убыванию частоты.
    func topTerms(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var freq: [String: Int] = [:]
        for e in entries { for w in Self.words(e.text) where w.count >= 4 { freq[w, default: 0] += 1 } }
        return freq.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { $0.key }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = []; loaded = true
        try? FileManager.default.removeItem(at: fileURL)
        kbLog("corpus: cleared")
    }

    func remove(bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let before = entries.count
        entries.removeAll { $0.bundleID == bundleID }
        if entries.count != before { save() }
        kbLog("corpus: removed \(before - entries.count) for app")
    }

    // MARK: - Хранилище

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let blob = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let data = try? AES.GCM.open(box, using: keyProvider()),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        guard !Self.writeBlocked || !usesKeychain else { return }
        guard let data = try? JSONEncoder().encode(entries),
              let sealed = try? AES.GCM.seal(data, using: keyProvider()),
              let combined = sealed.combined else { return }
        try? combined.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Ключ (Keychain, свой item)

    private static let keychainService = "dev.speakey.corpus"
    private static let keychainAccount = "corpus-key"
    private static var cachedKey: SymmetricKey?
    private static let keyLock = NSLock()

    private static var keychainBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    static func keychainKey() -> SymmetricKey {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = cachedKey { return k }
        let k = resolveKey()
        cachedKey = k
        return k
    }

    private static func resolveKey() -> SymmetricKey {
        let (stored, status) = keychainRead()
        if let d = stored, d.count == 32 { return SymmetricKey(data: d) }
        // Связка заблокирована или не ответила — НЕ перевыпускаем ключ: иначе старый corpus.bin
        // стал бы нечитаемым, а следующая запись его затёрла бы. Ключ на сессию, запись запрещена.
        guard status == errSecItemNotFound else {
            kbLog("corpus key: Keychain не ответил (\(status)) — корпус в этой сессии только читается")
            writeBlocked = true
            return SymmetricKey(size: .bits256)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data(Array($0)) }
        if !keychainWrite(data) { kbLog("corpus key: Keychain недоступен, ключ только в памяти") }
        return key
    }

    /// Чтение без диалога: если связка не узнала нас, ключ молча перевыпускается (корпус обнулится).
    static var writeBlocked = false

    private static func keychainRead() -> (Data?, OSStatus) {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data else { return (nil, st) }
        return (d, st)
    }

    @discardableResult
    private static func keychainWrite(_ data: Data) -> Bool {
        SecItemDelete(keychainBase as CFDictionary)
        var add = keychainBase
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
