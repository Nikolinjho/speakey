import Foundation

/// Режим записи набранного в личный корпус.
enum AutocompleteRecordMode: String { case off, accepted, all }

/// Настройки автодополнения. UserDefaults.standard, ключи с префиксом `ac.`.
enum AutocompletePrefs {
    private static let d = UserDefaults.standard

    private static func bool(_ k: String, _ def: Bool) -> Bool {
        d.object(forKey: k) == nil ? def : d.bool(forKey: k)
    }
    private static func int(_ k: String, _ def: Int) -> Int {
        d.object(forKey: k) == nil ? def : d.integer(forKey: k)
    }

    static var enabled: Bool { get { bool("ac.enabled", false) } set { d.set(newValue, forKey: "ac.enabled") } }
    static var modelID: String {
        get { d.string(forKey: "ac.modelID") ?? CompletionModels.defaultID }
        set { d.set(newValue, forKey: "ac.modelID") }
    }
    static var maxWords: Int { get { int("ac.maxWords", 6) } set { d.set(newValue, forKey: "ac.maxWords") } }
    static var pauseMs: Int { get { int("ac.pauseMs", 120) } set { d.set(newValue, forKey: "ac.pauseMs") } }
    static var recordMode: AutocompleteRecordMode {
        get { AutocompleteRecordMode(rawValue: d.string(forKey: "ac.recordMode") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "ac.recordMode") }
    }
    static var personalStrength: Int {
        get { min(3, max(0, int("ac.personalStrength", 2))) }
        set { d.set(min(3, max(0, newValue)), forKey: "ac.personalStrength") }
    }
    static var globalInstruction: String {
        get { d.string(forKey: "ac.globalInstruction") ?? "" }
        set { d.set(newValue, forKey: "ac.globalInstruction") }
    }
    static var useScreen: Bool { get { bool("ac.useScreen", false) } set { d.set(newValue, forKey: "ac.useScreen") } }
    static var useClipboard: Bool { get { bool("ac.useClipboard", false) } set { d.set(newValue, forKey: "ac.useClipboard") } }
    static var typoFix: Bool { get { bool("ac.typoFix", true) } set { d.set(newValue, forKey: "ac.typoFix") } }
    static var dictationContext: Bool { get { bool("ac.dictationContext", false) } set { d.set(newValue, forKey: "ac.dictationContext") } }
    /// На батарее — лёгкая модель и 3 слова.
    static var batteryLight: Bool { get { bool("ac.batteryLight", false) } set { d.set(newValue, forKey: "ac.batteryLight") } }
    static var idleUnloadMinutes: Int { get { int("ac.idleUnloadMinutes", 60) } set { d.set(newValue, forKey: "ac.idleUnloadMinutes") } }
    /// -1 — не назначено; 50 — клавиша над Tab.
    static var acceptAllKeyCode: Int { get { int("ac.acceptAllKeyCode", -1) } set { d.set(newValue, forKey: "ac.acceptAllKeyCode") } }
}

/// Настройки по приложению: UserDefaults "ac.apps", JSON {bid: {enabled, record, instruction}}.
final class AutocompleteAppStore {
    static let shared = AutocompleteAppStore()

    /// Жёсткое исключение: терминалы и менеджеры паролей.
    static let hardExcluded: Set<String> = [
        "com.apple.Terminal", "com.mitchellh.ghostty", "com.cmuxterm.app", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty",
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
    ]
    /// Выключены по умолчанию (можно включить вручную).
    static let offByDefault: Set<String> = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]

    private struct Entry: Codable {
        var enabled: Bool?
        var record: Bool?
        var instruction: String?
    }

    private let key = "ac.apps"
    private let lock = NSLock()
    private var cache: [String: Entry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "ac.apps"),
           let m = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = m
        } else {
            cache = [:]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func mutate(_ bid: String, _ f: (inout Entry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var e = cache[bid] ?? Entry()
        f(&e)
        cache[bid] = e
        save()
    }

    func isEnabled(_ bid: String) -> Bool {
        if Self.hardExcluded.contains(bid) { return false }
        lock.lock(); defer { lock.unlock() }
        if let v = cache[bid]?.enabled { return v }
        return !Self.offByDefault.contains(bid)
    }
    func setEnabled(_ bid: String, _ on: Bool) { mutate(bid) { $0.enabled = on } }

    func instruction(_ bid: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return cache[bid]?.instruction ?? ""
    }
    func setInstruction(_ bid: String, _ s: String) { mutate(bid) { $0.instruction = s } }

    /// Можно ли записывать набранное в этом приложении (по умолчанию да, если не hardExcluded).
    func recordAllowed(_ bid: String) -> Bool {
        if Self.hardExcluded.contains(bid) { return false }
        lock.lock(); defer { lock.unlock() }
        return cache[bid]?.record ?? true
    }
    func setRecordAllowed(_ bid: String, _ on: Bool) { mutate(bid) { $0.record = on } }

    var configuredApps: [String] {
        lock.lock(); defer { lock.unlock() }
        return cache.keys.sorted()
    }
}
