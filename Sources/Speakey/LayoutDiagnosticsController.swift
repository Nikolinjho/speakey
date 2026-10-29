import Foundation

final class LayoutDiagnosticsController {
    private let tracker: LayoutFeedbackTracker
    private let uptime: () -> TimeInterval
    private let sink: (LayoutFeedback) -> Void
    private(set) var enabled: Bool
    private(set) var contextID = UUID()
    private var frozen: [LayoutObservation] = []
    var frozenRecent: [LayoutObservation] {
        frozen.removeAll { uptime() - $0.uptime > 10 }
        return frozen
    }
    var onChange: (() -> Void)?
    var onObservation: ((LayoutObservation) -> Void)?
    var onSubmission: ((UUID, Bool) -> Void)?

    init(enabled: Bool, tracker: LayoutFeedbackTracker = LayoutFeedbackTracker(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping (LayoutFeedback) -> Void) {
        self.enabled = enabled
        self.tracker = tracker
        self.uptime = uptime
        self.sink = sink
    }

    var recent: [LayoutObservation] { tracker.snapshot(uptime: uptime()) }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        clearTemporaryState()
    }

    @discardableResult
    func record(occurrenceID: UUID, bundleID: String, typed: String, proposed: String?, alternative: String? = nil, dictionaryMatch: LayoutDictionaryMatch? = nil, path: LayoutPath,
                reason: LayoutReason, action: LayoutAction, complete: Bool) -> LayoutObservation? {
        guard enabled, Self.validToken(typed), (proposed.map(Self.validToken) ?? true), (alternative.map(Self.validToken) ?? true) else { return nil }
        // После живой замены буфер содержит результат, а полный физический оригинал неизвестен.
        if complete, recent.contains(where: {
            $0.occurrenceID == occurrenceID && $0.contextID == contextID && !$0.isCompleteWord && $0.action == .replace
        }) { return nil }
        let event = LayoutObservation(occurrenceID: occurrenceID, contextID: contextID, bundleID: bundleID,
            typed: typed, proposed: action == .replace ? proposed : nil, alternative: alternative, dictionaryMatch: dictionaryMatch, path: path, reason: reason, action: action,
            submission: action == .replace ? .pending : .notNeeded, isCompleteWord: complete, uptime: uptime())
        tracker.record(event)
        onObservation?(event)
        onChange?()
        return event
    }

    func submission(observationID: UUID, contextID: UUID, submitted: Bool) {
        onSubmission?(observationID, submitted)
        guard enabled, self.contextID == contextID else { return }
        guard recent.contains(where: { $0.id == observationID }) else { return }
        tracker.setSubmission(observationID: observationID, submitted: submitted)
        onChange?()
    }

    func manualConverted(occurrenceID: UUID, contextID: UUID, from: String, to: String, submitted: Bool) {
        guard enabled, self.contextID == contextID, submitted, Self.validToken(from), Self.validToken(to) else { return }
        if let feedback = tracker.manualConvert(occurrenceID: occurrenceID, contextID: contextID,
                                               from: from, to: to, uptime: uptime()) { sink(feedback) }
    }

    func observeRetyping(occurrenceID: UUID?, current: String) {
        guard enabled, let occurrenceID, current.count <= 128 else { return }
        if let feedback = tracker.observeRetyping(occurrenceID: occurrenceID, contextID: contextID,
                                                  current: current, uptime: uptime()) { sink(feedback) }
    }

    func mark(observation: LayoutObservation, expected: String, kind: LayoutErrorKind) {
        guard enabled, Self.validToken(observation.typed), observation.proposed.map(Self.validToken) ?? true,
              Self.validToken(expected) else { return }
        sink(LayoutFeedback(observationID: observation.id, observation: observation, expected: expected,
                            kind: kind, source: .explicit))
    }

    func addManualCase(typed: String, expected: String, bundleID: String, kind: LayoutErrorKind) {
        guard enabled, Self.validToken(typed), Self.validToken(expected) else { return }
        let event = LayoutObservation(occurrenceID: UUID(), contextID: contextID, bundleID: bundleID,
            typed: typed, proposed: nil, path: .manual, reason: .explicit, action: .keep,
            submission: .notNeeded, isCompleteWord: true, uptime: uptime())
        mark(observation: event, expected: expected, kind: kind)
    }

    static func bypassesJournal(editing: Bool, bundleID: String, ownBundleID: String) -> Bool {
        editing && bundleID == ownBundleID
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 128 && !token.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    func freezeRecent() { frozen = recent; if !frozen.isEmpty { onChange?() } }
    func resetContext() {
        let hadRecent = !recent.isEmpty
        tracker.reset(contextID: contextID)
        contextID = UUID()
        if hadRecent { onChange?() }
    }
    func clearTemporaryState() {
        let hadFrozen = !frozen.isEmpty
        frozen = []
        resetContext()
        if hadFrozen { onChange?() }
    }
}
