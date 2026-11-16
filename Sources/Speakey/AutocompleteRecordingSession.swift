import Foundation

/// Текст и принятие принадлежат конкретному полю, а не всему приложению.
struct AutocompleteRecordingSession<Field: Equatable> {
    struct Completed {
        let bundleID: String
        let text: String
        let accepted: Bool
    }

    private(set) var field: Field?
    private(set) var bundleID = ""
    private var text = ""
    private(set) var accepted = false

    /// Неизвестное поле завершает прежнюю сессию, но само не записывается.
    mutating func note(field: Field?, bundleID: String, text: String?) -> Completed? {
        var completed: Completed?
        if self.field != field || self.bundleID != bundleID { completed = finish() }
        guard let field else { return completed }
        self.field = field
        self.bundleID = bundleID
        self.text = text ?? ""
        return completed
    }

    /// Принятие подтверждается только фактическим результатом записи в исходное поле.
    @discardableResult
    mutating func confirmInsertion(field: Field, text: String?) -> Bool {
        guard self.field == field, let text, !text.isEmpty else { return false }
        self.text = text
        accepted = true
        return true
    }

    mutating func finish(finalText: String? = nil) -> Completed? {
        if let finalText { text = finalText }
        defer { field = nil; bundleID = ""; text = ""; accepted = false }
        guard field != nil, !bundleID.isEmpty, !text.isEmpty else { return nil }
        return Completed(bundleID: bundleID, text: text, accepted: accepted)
    }
}

/// Ограниченная очередь намерений на время подтверждения вставки.
struct AutocompleteAcceptanceQueue {
    enum Intent { case nextWord, all }
    private var words = 0
    private var all = false
    mutating func append(_ intent: Intent) {
        switch intent {
        case .nextWord: if !all { words = min(8, words + 1) }
        case .all: all = true
        }
    }
    mutating func take() -> Intent? {
        if words > 0 { words -= 1; return .nextWord }
        if all { all = false; return .all }
        return nil
    }
    mutating func clear() { words = 0; all = false }
}
