import Foundation

enum CompletionAction: String, Codable, CaseIterable {
    case nextWord, acceptAll, manual, toggleApp, toggleGlobal, alternatives, synonyms
}

enum CompletionEscapeMode: String, CaseIterable {
    case brief, untilAppSwitch, passThrough
}

/// Физическая клавиша и четыре модификатора. Caps Lock и служебные биты не участвуют.
struct CompletionShortcut: Codable, Equatable {
    enum Decision { case pass, consume, perform }
    static let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
    let keyCode: Int64
    let modifiers: UInt64

    init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    func matches(keyCode: Int64, modifiers: UInt64) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers & Self.modifierMask
    }

    func decision(action: CompletionAction, keyCode: Int64, modifiers: UInt64,
                  isRepeat: Bool, tabEnabled: Bool) -> Decision {
        guard matches(keyCode: keyCode, modifiers: modifiers) else { return .pass }
        if action == .nextWord || action == .acceptAll {
            return keyCode == 48 && !tabEnabled ? .pass : .perform
        }
        return isRepeat ? .consume : .perform
    }

    func isValid(for action: CompletionAction) -> Bool {
        guard (0...127).contains(keyCode), !(keyCode == 53 && modifiers == 0),
              !(keyCode == 48 && modifiers == 1 << 19),
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else { return false }
        // Команды без видимой подсказки не отбирают обычные буквы и ввод текста.
        if [.manual, .toggleApp, .toggleGlobal, .alternatives, .synonyms].contains(action) {
            return modifiers & ((1 << 18) | (1 << 19) | (1 << 20)) != 0
        }
        return modifiers != 0 || [48, 10, 50, 124].contains(keyCode)
    }

    static func conflict(_ shortcut: Self, for action: CompletionAction,
                         bindings: [CompletionAction: Self]) -> CompletionAction? {
        CompletionAction.allCases.first { $0 != action && bindings[$0] == shortcut }
    }
}

/// Паузы живут только в памяти. Время монотонное, в тестах задаётся явно.
struct CompletionSuppression {
    private var briefApp: String?
    private var briefUntil: TimeInterval = 0
    private var untilSwitchApp: String?
    private var appPauses: [String: TimeInterval] = [:]

    func isSuppressed(app: String, now: TimeInterval) -> Bool {
        untilSwitchApp == app || (briefApp == app && now < briefUntil) || now < (appPauses[app] ?? 0)
    }

    mutating func dismiss(mode: CompletionEscapeMode, app: String, now: TimeInterval) {
        switch mode {
        case .brief: briefApp = app; briefUntil = now + 3
        case .untilAppSwitch: untilSwitchApp = app
        case .passThrough: break
        }
    }

    mutating func toggle(app: String, now: TimeInterval) {
        if isSuppressed(app: app, now: now) { resume(app: app) }
        else {
            appPauses = appPauses.filter { $0.value > now }
            appPauses[app] = now + 300
        }
    }

    mutating func resume(app: String) {
        if briefApp == app { briefApp = nil }
        if untilSwitchApp == app { untilSwitchApp = nil }
        appPauses.removeValue(forKey: app)
    }

    mutating func contextReset(appChanged: Bool) {
        if appChanged { untilSwitchApp = nil; briefApp = nil }
    }
}
