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

    static var enabled: Bool {
        get { bool("ac.enabled", false) }
        set {
            let changed = enabled != newValue
            d.set(newValue, forKey: "ac.enabled")
            if changed { invalidateRecording() }
        }
    }
    static var modelID: String {
        get { d.string(forKey: "ac.modelID") ?? CompletionModels.defaultID }
        set { d.set(newValue, forKey: "ac.modelID") }
    }
    static var maxWords: Int { get { int("ac.maxWords", 6) } set { d.set(newValue, forKey: "ac.maxWords") } }
    static var pauseMs: Int { get { int("ac.pauseMs", 120) } set { d.set(newValue, forKey: "ac.pauseMs") } }
    static var recordMode: AutocompleteRecordMode {
        get { AutocompleteRecordMode(rawValue: d.string(forKey: "ac.recordMode") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "ac.recordMode"); invalidateRecording() }
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
    static let controlsChanged = Notification.Name("SpeakeyAutocompleteControlsChanged")
    static var onlyCurrentWord: Bool { get { bool("ac.onlyCurrentWord", false) } set { d.set(newValue, forKey: "ac.onlyCurrentWord"); notifyControls() } }
    static var inlineCompletion: Bool { get { bool("ac.inlineCompletion", false) } set { d.set(newValue, forKey: "ac.inlineCompletion"); notifyControls() } }
    static var autoAlternatives: Bool { get { bool("ac.autoAlternatives", false) } set { d.set(newValue, forKey: "ac.autoAlternatives"); notifyControls() } }
    static var autoSynonyms: Bool { get { bool("ac.autoSynonyms", false) } set { d.set(newValue, forKey: "ac.autoSynonyms"); notifyControls() } }
    static var variantsDelayMs: Int {
        get { min(2000, max(300, int("ac.variantsDelayMs", 600))) }
        set { d.set(min(2000, max(300, newValue)), forKey: "ac.variantsDelayMs"); notifyControls() }
    }
    static let recordingChanged = Notification.Name("SpeakeyCorpusRecordingChanged")
    private static let recordingLock = NSLock()
    private static var recordingGeneration: UInt64 = 0
    static var recordingRevision: UInt64 {
        recordingLock.lock(); defer { recordingLock.unlock() }
        return recordingGeneration
    }
    static func invalidateRecording() {
        recordingLock.lock(); recordingGeneration &+= 1; recordingLock.unlock()
        NotificationCenter.default.post(name: recordingChanged, object: nil)
    }
    static var trailingSpace: Bool { get { bool("ac.trailingSpace", false) } set { d.set(newValue, forKey: "ac.trailingSpace"); notifyControls() } }
    static var trailingPunctuation: Bool { get { bool("ac.trailingPunctuation", true) } set { d.set(newValue, forKey: "ac.trailingPunctuation"); notifyControls() } }
    static var tabEnabled: Bool { get { bool("ac.tabEnabled", true) } set { d.set(newValue, forKey: "ac.tabEnabled"); notifyControls() } }
    static var escapeMode: CompletionEscapeMode {
        get { CompletionEscapeMode(rawValue: d.string(forKey: "ac.escapeMode") ?? "") ?? .brief }
        set { d.set(newValue.rawValue, forKey: "ac.escapeMode"); notifyControls() }
    }
    static func notifyControls() { NotificationCenter.default.post(name: controlsChanged, object: nil) }

    static func shortcut(_ action: CompletionAction) -> CompletionShortcut? {
        let key = "ac.shortcut.\(action.rawValue)"
        if let data = d.data(forKey: key) { return try? JSONDecoder().decode(CompletionShortcut.self, from: data) }
        if action == .nextWord { return CompletionShortcut(keyCode: 48, modifiers: 0) }
        if action == .acceptAll, acceptAllKeyCode >= 0 { return CompletionShortcut(keyCode: Int64(acceptAllKeyCode), modifiers: 0) }
        return nil
    }

    static var shortcuts: [CompletionAction: CompletionShortcut] {
        Dictionary(uniqueKeysWithValues: CompletionAction.allCases.compactMap { action in shortcut(action).map { (action, $0) } })
    }

    static func setShortcut(_ shortcut: CompletionShortcut?, for action: CompletionAction) {
        guard shortcut == nil || shortcut!.isValid(for: action),
              shortcut == nil || CompletionShortcut.conflict(shortcut!, for: action, bindings: shortcuts) == nil,
              let data = try? JSONEncoder().encode(shortcut) else { return }
        d.set(data, forKey: "ac.shortcut.\(action.rawValue)")
        notifyControls()
    }
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
        var tabEnabled: Bool?
    }

    private let key = "ac.apps"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var cache: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "ac.apps"),
           let m = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = m
        } else {
            cache = [:]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: key) }
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
    func enabledOverride(_ bid: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[bid]?.enabled
    }
    func register(_ bid: String) { mutate(bid) { _ in } }
    func setEnabled(_ bid: String, _ on: Bool?) {
        mutate(bid) { $0.enabled = on }
        AutocompletePrefs.invalidateRecording()
        AutocompletePrefs.notifyControls()
    }

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
    func recordOverride(_ bid: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[bid]?.record
    }
    func setRecordAllowed(_ bid: String, _ on: Bool?) {
        mutate(bid) { $0.record = on }
        AutocompletePrefs.invalidateRecording()
    }
    func shouldRecord(_ bid: String, mode: AutocompleteRecordMode, accepted: Bool, autocompleteEnabled: Bool = true) -> Bool {
        guard autocompleteEnabled, isEnabled(bid), recordAllowed(bid) else { return false }
        switch mode {
        case .off: return false
        case .accepted: return accepted
        case .all: return true
        }
    }

    func tabOverride(_ bid: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[bid]?.tabEnabled
    }
    func tabEnabled(_ bid: String, global: Bool) -> Bool { tabOverride(bid) ?? global }
    func setTabEnabled(_ bid: String, _ on: Bool?) {
        mutate(bid) { $0.tabEnabled = on }
        AutocompletePrefs.notifyControls()
    }

    var configuredApps: [String] {
        lock.lock(); defer { lock.unlock() }
        return cache.keys.sorted()
    }
}
