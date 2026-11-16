import Foundation
import CryptoKit
import Security
import Darwin

/// Личный корпус набранного текста: зашифрованный AES-GCM файл `corpus.bin`, ключ в Keychain
/// (отдельный item, как у VoiceHistory). Никогда не покидает Mac. В лог — только счётчики.
final class PersonalCorpus {
    static let changed = Notification.Name("SpeakeyPersonalCorpusChanged")
    private static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Speakey", isDirectory: true)
    static let shared = PersonalCorpus(
        directory: defaultDirectory,
        keyProvider: { PersonalCorpus.keychainKey() })

    /// Идентификатор добавлен с сохранением чтения старого зашифрованного формата.
    struct Record: Codable {
        let id: UUID
        var text: String
        var bundleID: String
        var date: TimeInterval

        init(text: String, bundleID: String, date: TimeInterval) {
            id = UUID(); self.text = text; self.bundleID = bundleID; self.date = date
        }
        private enum CodingKeys: String, CodingKey { case id, text, bundleID, date }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            text = try c.decode(String.self, forKey: .text)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            date = try c.decode(TimeInterval.self, forKey: .date)
        }
    }

    struct Snapshot {
        let records: [Record]
        let sourceCounts: [String: Int]
        let available: Bool
    }

    /// Запись сессий и удаления из интерфейса идут в одной очереди.
    static let workQueue = DispatchQueue(label: "dev.speakey.corpus.storage", qos: .utility)

    static let minLength = 20
    static let maxEntries = 5000

    private let fileURL: URL
    private let keyProvider: () -> SymmetricKey?
    private let lock = NSLock()
    private var entries: [Record] = []
    private var writingIndex: PersonalWritingIndex?
    private var previousIndex: PersonalWritingIndex?
    private var indexRevision: UInt64 = 0
    private let indexQueue: DispatchQueue
    private let indexBuilder: ([Record], PersonalWritingIndex?) -> PersonalWritingIndex
    private var loaded = false
    private var available = true
    private let writer: (Data, URL) throws -> Void

    init(directory: URL, keyProvider: @escaping () -> SymmetricKey?,
         writer: @escaping (Data, URL) throws -> Void = PersonalCorpus.atomicWrite,
         indexQueue: DispatchQueue = DispatchQueue(label: "dev.speakey.corpus.index", qos: .utility),
         indexBuilder: @escaping ([Record], PersonalWritingIndex?) -> PersonalWritingIndex = { PersonalWritingIndex(records: $0, previous: $1) }) {
        self.writer = writer
        self.indexQueue = indexQueue
        self.indexBuilder = indexBuilder
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("corpus.bin")
        self.keyProvider = keyProvider
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries.count
    }

    @discardableResult
    func add(_ text: String, bundleID: String) -> Bool {
        let clean = CompletionText.redactSecrets(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard clean.count >= Self.minLength else { return false }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard available else { return false }
        var next = entries
        // Та же сессия поля приходит повторно и дописанной: заменяем запись, а не плодим перекрытия —
        // иначе любое слово набирало бы частоту и лезло в частые термины (ревью 12.11).
        let now = Date().timeIntervalSince1970
        if let i = entries.indices.suffix(30).last(where: {
            entries[$0].bundleID == bundleID && (clean.hasPrefix(entries[$0].text) || entries[$0].text.hasPrefix(clean)
                || clean.hasSuffix(entries[$0].text) || entries[$0].text.hasSuffix(clean))
        }) {
            if clean.count >= next[i].text.count { next[i].text = clean }
            next[i].date = now
            return persist(next)
        }
        next.append(Record(text: clean, bundleID: bundleID, date: now))
        if next.count > Self.maxEntries { next.removeFirst(next.count - Self.maxEntries) }
        return persist(next)
    }

    /// Совпадение слов с учётом редкости и свежести, без повторной токенизации корпуса.
    func similar(to before: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return withIndex { $0.examples(before: before, limit: limit) }
    }

    /// Повторяющиеся слова сохраняют исходное написание автора.
    func topTerms(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return withIndex { $0.terms(limit: limit) }
    }

    func personalization(before: String, bundleID: String, strength: Int) -> PersonalWritingIndex.Profile {
        guard strength > 0 else { return PersonalWritingIndex.Profile() }
        return withIndex { $0.profile(before: before, bundleID: bundleID, strength: strength) }
    }

    /// Тяжёлая сборка и запрос не держат блокировку хранилища. Смена версии требует свежего результата.
    private func withIndex<Result>(_ query: (PersonalWritingIndex) -> Result) -> Result {
        while true {
            lock.lock()
            loadIfNeeded()
            let revision = indexRevision, cached = writingIndex, previous = previousIndex
            let records = available ? entries : []
            lock.unlock()
            let index = cached ?? indexBuilder(records, previous)
            lock.lock()
            guard revision == indexRevision else { lock.unlock(); continue }
            if writingIndex == nil { writingIndex = index; previousIndex = nil }
            lock.unlock()
            let result = query(index)
            lock.lock()
            let current = revision == indexRevision
            lock.unlock()
            if current { return result }
        }
    }

    /// Старый профиль сразу недоступен. Отложенная сборка публикуется только для своей версии.
    private func rebuildIndex() {
        let previous = writingIndex ?? previousIndex
        previousIndex = previous
        writingIndex = nil
        indexRevision &+= 1
        let revision = indexRevision, records = entries
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let needed = self.indexRevision == revision && self.writingIndex == nil
            self.lock.unlock()
            guard needed else { return }
            let built = self.indexBuilder(records, previous)
            self.lock.lock(); defer { self.lock.unlock() }
            if self.indexRevision == revision && self.writingIndex == nil {
                self.writingIndex = built
                self.previousIndex = nil
            }
        }
    }

    func snapshot(bundleID: String? = nil) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let counts = entries.reduce(into: [String: Int]()) { $0[$1.bundleID, default: 0] += 1 }
        let records = entries.filter { bundleID == nil || $0.bundleID == bundleID }
            .sorted { $0.date > $1.date }
        return Snapshot(records: records, sourceCounts: counts, available: available)
    }

    @discardableResult
    func removeAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard available else { return false }
        return persist([])
    }

    @discardableResult
    func remove(bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard available else { return false }
        return persist(entries.filter { $0.bundleID != bundleID })
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard available, entries.contains(where: { $0.id == id }) else { return false }
        return persist(entries.filter { $0.id != id })
    }

    // MARK: - Хранилище

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let key = keyProvider() else { available = false; return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let blob = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let data = try? AES.GCM.open(box, using: key),
              let list = try? JSONDecoder().decode([Record].self, from: data) else {
            available = false
            return
        }
        entries = list
        rebuildIndex()
    }

    /// Память меняется только после успешной атомарной записи.
    private func persist(_ next: [Record]) -> Bool {
        guard available, let key = keyProvider(),
              let data = try? JSONEncoder().encode(next),
              let sealed = try? AES.GCM.seal(data, using: key),
              let combined = sealed.combined else { return false }
        do {
            try writer(combined, fileURL)
            entries = next
            rebuildIndex()
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
            return true
        } catch {
            kbLog("corpus: запись не выполнена")
            return false
        }
    }

    /// Права задаются до атомарной замены. После rename ошибок сохранения уже нет.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".corpus-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staging.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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

    static func keychainKey() -> SymmetricKey? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = cachedKey { return k }
        let k = resolveKey()
        cachedKey = k
        return k
    }

    private static func resolveKey() -> SymmetricKey? {
        let (stored, status) = keychainRead()
        if let d = stored, d.count == 32 { return SymmetricKey(data: d) }
        // Связка заблокирована или не ответила — НЕ перевыпускаем ключ: иначе старый corpus.bin
        // стал бы нечитаемым, а следующая запись его затёрла бы. Ключ на сессию, запись запрещена.
        guard status == errSecItemNotFound else {
            kbLog("corpus key: Keychain не ответил (\(status)) — корпус в этой сессии только читается")
            return nil
        }
        guard !FileManager.default.fileExists(atPath: defaultDirectory.appendingPathComponent("corpus.bin").path) else {
            kbLog("corpus key: ключ отсутствует для существующего корпуса, запись запрещена")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data(Array($0)) }
        guard keychainWrite(data) else { kbLog("corpus key: Keychain недоступен, запись запрещена"); return nil }
        return key
    }

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
        var add = keychainBase
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
