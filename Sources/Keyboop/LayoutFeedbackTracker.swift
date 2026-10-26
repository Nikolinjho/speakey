import Foundation

final class LayoutFeedbackTracker {
    private enum Retyping {
        case deleting(String)
        case entering(String)
    }

    private struct Entry {
        var observation: LayoutObservation
        var consumed = false
        var retyping: Retyping?
    }

    private let window: TimeInterval
    private let capacity: Int
    private let retention: TimeInterval
    private var entries: [Entry] = []

    init(window: TimeInterval = 4, capacity: Int = 32, retention: TimeInterval = 10) {
        self.window = max(0, window)
        self.capacity = max(1, capacity)
        self.retention = max(0, retention)
    }

    func record(_ observation: LayoutObservation) {
        expire(uptime: observation.uptime)
        guard !entries.contains(where: { $0.observation.id == observation.id }) else { return }
        let consumed = entries.contains {
            $0.consumed && $0.observation.occurrenceID == observation.occurrenceID
                && $0.observation.contextID == observation.contextID
        }
        entries.append(Entry(observation: observation, consumed: consumed))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func setSubmission(observationID: UUID, submitted: Bool) {
        guard let index = entries.firstIndex(where: { $0.observation.id == observationID }) else { return }
        let submission = entries[index].observation.submission
        guard submission == .pending || submission == .unknown else { return }
        entries[index].observation.submission = submitted ? .submitted : .rejected
    }

    func manualConvert(occurrenceID: UUID, contextID: UUID, from: String, to: String,
                       uptime: TimeInterval) -> LayoutFeedback? {
        guard let index = candidate(occurrenceID: occurrenceID, contextID: contextID, uptime: uptime),
              !from.isEmpty, !to.isEmpty, from.lowercased() != to.lowercased() else { return nil }
        let event = entries[index].observation
        let kind: LayoutErrorKind
        if event.action == .keep, from.lowercased() == event.typed.lowercased() {
            kind = .missedConversion
        } else if event.action == .replace, event.submission == .submitted,
                  from.lowercased() == event.proposed?.lowercased(), to.lowercased() == event.typed.lowercased() {
            kind = .unwantedConversion
        } else {
            entries[index].consumed = true
            return nil
        }
        return feedback(index: index, expected: to, kind: kind, source: .manualFlip)
    }

    func observeRetyping(occurrenceID: UUID, contextID: UUID, current: String,
                         uptime: TimeInterval) -> LayoutFeedback? {
        guard let index = candidate(occurrenceID: occurrenceID, contextID: contextID, uptime: uptime) else { return nil }
        let event = entries[index].observation
        if event.action == .keep {
            if current.lowercased() != event.typed.lowercased() { entries[index].consumed = true }
            return nil
        }
        guard event.action == .replace, event.submission == .submitted,
              let produced = event.proposed, !produced.isEmpty else { return nil }
        let value = current.lowercased()
        let original = event.typed.lowercased()
        switch entries[index].retyping ?? .deleting(produced.lowercased()) {
        case .deleting(let previous):
            if value.isEmpty {
                entries[index].retyping = .entering("")
            } else if previous.hasPrefix(value) {
                entries[index].retyping = .deleting(value)
            } else {
                entries[index].consumed = true
            }
        case .entering(let previous):
            if value == original, !value.isEmpty {
                return feedback(index: index, expected: current, kind: .unwantedConversion, source: .retype)
            } else if original.hasPrefix(value), value.hasPrefix(previous) {
                entries[index].retyping = .entering(value)
            } else {
                entries[index].consumed = true
            }
        }
        return nil
    }

    func reset(contextID: UUID) {
        entries.removeAll { $0.observation.contextID == contextID }
    }

    func snapshot(uptime: TimeInterval) -> [LayoutObservation] {
        expire(uptime: uptime)
        return entries.map(\.observation)
    }

    private func candidate(occurrenceID: UUID, contextID: UUID, uptime: TimeInterval) -> Int? {
        expire(uptime: uptime)
        for index in entries.indices {
            let event = entries[index].observation
            if event.contextID != contextID || event.occurrenceID != occurrenceID {
                entries[index].consumed = true
            }
        }
        guard let index = entries.lastIndex(where: {
            let event = $0.observation
            return event.occurrenceID == occurrenceID && event.contextID == contextID
        }) else { return nil }
        let elapsed = uptime - entries[index].observation.uptime
        guard !entries[index].consumed, elapsed >= 0, elapsed <= window else { return nil }
        return index
    }

    private func feedback(index: Int, expected: String, kind: LayoutErrorKind,
                          source: LayoutFeedbackSource) -> LayoutFeedback {
        entries[index].consumed = true
        let event = entries[index].observation
        return LayoutFeedback(observationID: event.id, observation: event, expected: expected, kind: kind, source: source)
    }

    private func expire(uptime: TimeInterval) {
        entries.removeAll { uptime - $0.observation.uptime > retention }
    }
}
