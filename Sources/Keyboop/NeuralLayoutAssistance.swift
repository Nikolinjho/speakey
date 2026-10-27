import Foundation

// Доступ только с main runloop, общей для доставки результата и event tap.
struct NeuralLayoutMailbox {
    private let now: () -> TimeInterval
    private var lastToken: UInt32
    private var pending: (token: UInt32, result: NeuralLayoutResult, expires: TimeInterval)?

    init(lastToken: UInt32 = 0, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lastToken = lastToken
        self.now = now
    }
    mutating func offer(result: NeuralLayoutResult) -> UInt32? {
        guard lastToken < UInt32.max else { return nil }
        lastToken += 1
        pending = (lastToken, result, now() + 0.5)
        return lastToken
    }
    mutating func take(token: UInt32) -> NeuralLayoutResult? {
        guard let value = pending, value.token == token else { return nil }
        pending = nil
        return now() <= value.expires ? value.result : nil
    }
    mutating func cancel(token: UInt32) {
        if pending?.token == token { pending = nil }
    }
    mutating func invalidate() { pending = nil }
}

enum NeuralLayoutAssistance {
    static func policy(result: NeuralLayoutResult, mode: NeuralLayoutMode, modelSHA256: String,
                       profile: NeuralLayoutProfile?, fresh: Bool, block: NeuralLayoutBlock?,
                       word: String, ruleBlocked: Bool) -> NeuralLayoutPolicyResult {
        let block = block ?? (!NeuralLayoutToken.assistanceSupported(word) ? .unsupported : (ruleBlocked ? .rule : nil))
        return NeuralLayoutPolicy.evaluate(scores: result.scores, admission: NeuralLayoutAdmission(
            mode: mode, modelSHA256: modelSHA256, profile: profile, fresh: fresh, block: block,
            wordLength: word.count, sourceCyrillic: word.unicodeScalars.contains { (0x0400...0x04ff).contains($0.value) }))
    }

    @discardableResult
    static func submit(_ write: () -> Bool, submission: (Bool) -> Void, committed: () -> Void) -> Bool {
        let submitted = write()
        submission(submitted)
        guard submitted else { return false }
        committed()
        return true
    }
}

struct NeuralLayoutLiveGuards {
    var running = true, ready = true, focusAvailable = true
    var autoEnabled = true, inlineEnabled = true, inlineHealthy = true, liveEnabled = true, warm = true
    var occurrenceAllowed = true
    var paused = false, secureInput = false, modifiers = false, muted = false, markerInFlight = false
    var edited = false, contextPending = false, journalEditing = false, developer = false
    var appBlocked = false, sameAsLast = false, undo = false

    var block: NeuralLayoutBlock? {
        if !running || !ready || !focusAvailable { return .unavailable }
        if !autoEnabled || paused || !inlineEnabled || !inlineHealthy || !liveEnabled { return .disabled }
        if secureInput { return .secureInput }
        if modifiers { return .modifiers }
        if !warm { return .unavailable }
        if muted || markerInFlight { return .syntheticFlight }
        if edited || contextPending || journalEditing { return .editing }
        if developer { return .developer }
        if appBlocked { return .app }
        if !occurrenceAllowed || sameAsLast { return .stale }
        if undo { return .undo }
        return nil
    }
}
