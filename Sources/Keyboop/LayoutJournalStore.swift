import Foundation

struct LayoutJournalSnapshot {
    let cases: [LayoutCase]
    let rules: [LayoutRuleReceipt]
    let prunedCount: Int
    let loadError: Error?
    var observations: [LayoutObservation] = []
    var markedObservationIDs: Set<UUID> = []

    struct Export: Codable {
        let schemaVersion: Int
        let cases: [LayoutCase]
        let rules: [LayoutRuleReceipt]
        let prunedCount: Int
        var observations: [LayoutObservation] = []
    }
}

enum LayoutJournalError: Error {
    case unsupportedSchema, invalidWord, missingCase, conflictingCase, missingReceipt, duplicateReceipt, sizeLimit, invalidExportDestination, invalidNeuralEvidence
}

final class LayoutJournalStore {
    typealias Completion = (Result<Void, Error>) -> Void

    private struct Envelope: Codable, Equatable {
        var schemaVersion = 1
        var cases: [LayoutCase] = []
        var rules: [LayoutRuleReceipt] = []
        var prunedCount = 0
        var observations: [LayoutObservation] = []
        var observationIDs: [String: [UUID]] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, cases, rules, prunedCount, observationIDs, observations
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            cases = try values.decode([LayoutCase].self, forKey: .cases)
            rules = try values.decode([LayoutRuleReceipt].self, forKey: .rules)
            prunedCount = try values.decode(Int.self, forKey: .prunedCount)
            observationIDs = try values.decode([String: [UUID]].self, forKey: .observationIDs)
            observations = try values.decodeIfPresent([LayoutObservation].self, forKey: .observations) ?? []
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let queue = DispatchQueue(label: "keyboop.layout-journal", qos: .utility)
    private let directory: URL
    private let file: URL
    private let now: () -> Date
    private let maxCases: Int
    private let maxObservations: Int
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let maxWordLength: Int
    private var state = Envelope()
    private var neuralGeneration: UInt64 = 0
    private var loadError: Error?
    private var storageError: Error?

    init(directory: URL, now: @escaping () -> Date = Date.init, maxCases: Int = 2000, maxObservations: Int = 2000,
         maxAge: TimeInterval = 30 * 86400, maxBytes: Int = 20 * 1024 * 1024, maxWordLength: Int = 128) {
        self.directory = directory
        file = directory.appendingPathComponent("layout-journal-v1.json")
        self.now = now
        self.maxCases = max(0, maxCases)
        self.maxObservations = max(0, maxObservations)
        self.maxAge = max(0, maxAge)
        self.maxBytes = max(0, maxBytes)
        self.maxWordLength = max(0, maxWordLength)
        queue.async { self.load() }
    }

    func recordObservation(_ observation: LayoutObservation, completion: @escaping Completion = { _ in }) {
        mutate(completion, preservingObservationID: observation.id) { next in
            if let evidence = observation.neural { try evidence.validate() }
            try self.validate(observation.typed, observation.typed)
            if let proposed = observation.proposed { try self.validate(proposed, proposed) }
            if let alternative = observation.alternative { try self.validate(alternative, alternative) }
            if let index = next.observations.firstIndex(where: { $0.id == observation.id }) {
                let previous = next.observations[index]
                guard previous.submission != .submitted && previous.submission != .rejected else { return }
                next.observations[index] = observation
            } else {
                next.observations.append(observation)
            }
        }
    }

    func neuralWriteGeneration(completion: @escaping (UInt64) -> Void) {
        queue.async {
            let generation = self.neuralGeneration
            DispatchQueue.main.async { completion(generation) }
        }
    }

    func invalidateNeuralWrites(completion: @escaping Completion = { _ in }) {
        queue.async {
            self.neuralGeneration &+= 1
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func attachNeural(observationID: UUID, generation: UInt64, evidence: NeuralLayoutEvidence,
                      completion: @escaping Completion = { _ in }) {
        mutate(completion, preservingObservationID: observationID, skipUnchanged: true) { next in
            guard generation == self.neuralGeneration,
                  let index = next.observations.firstIndex(where: { $0.id == observationID }) else { return }
            try evidence.validate()
            next.observations[index].neural = evidence
        }
    }

    func updateSubmission(observationID: UUID, submitted: Bool, completion: @escaping Completion = { _ in }) {
        mutate(completion) { next in
            guard let index = next.observations.firstIndex(where: { $0.id == observationID }),
                  [.pending, .unknown].contains(next.observations[index].submission) else { return }
            next.observations[index].submission = submitted ? .submitted : .rejected
        }
    }

    func record(_ feedback: LayoutFeedback, completion: @escaping Completion = { _ in }) {
        mutate(completion) { next in
            if let evidence = feedback.observation.neural { try evidence.validate() }
            try self.validate(feedback.observation.typed, feedback.expected)
            if let proposed = feedback.observation.proposed { try self.validate(proposed, feedback.expected) }
            if let alternative = feedback.observation.alternative { try self.validate(alternative, feedback.expected) }
            if next.observationIDs.values.contains(where: { $0.contains(feedback.observationID) }) { return }
            let observation = feedback.observation
            let key = self.key(typed: observation.typed, expected: feedback.expected, kind: feedback.kind,
                               bundleID: observation.bundleID, complete: observation.isCompleteWord)
            let index: Int
            if let existing = next.cases.firstIndex(where: { self.key($0) == key }) {
                index = existing
                next.cases[index].count += 1
                next.cases[index].firstSeen = min(next.cases[index].firstSeen, feedback.createdAt)
                next.cases[index].lastSeen = max(next.cases[index].lastSeen, feedback.createdAt)
            } else {
                next.cases.append(LayoutCase(typed: observation.typed, produced: observation.proposed,
                    expected: feedback.expected, kind: feedback.kind, bundleID: observation.bundleID,
                    isCompleteWord: observation.isCompleteWord, firstSeen: feedback.createdAt, lastSeen: feedback.createdAt))
                index = next.cases.count - 1
            }
            next.cases[index].evidence.append(feedback)
            next.cases[index].evidence = Array(next.cases[index].evidence.suffix(5))
            next.observationIDs[next.cases[index].id.uuidString, default: []].append(feedback.observationID)
        }
    }

    func snapshot(completion: @escaping (LayoutJournalSnapshot) -> Void) {
        queue.async {
            self.refreshRetention()
            let snapshot = LayoutJournalSnapshot(cases: self.state.cases, rules: self.state.rules,
                                                 prunedCount: self.state.prunedCount, loadError: self.loadError,
                                                 observations: self.state.observations,
                                                 markedObservationIDs: Set(self.state.observationIDs.values.flatMap { $0 }))
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func review(caseID: UUID, expected: String, status: LayoutReviewStatus, completion: @escaping Completion = { _ in }) {
        mutate(completion) { next in
            guard let index = next.cases.firstIndex(where: { $0.id == caseID }) else { throw LayoutJournalError.missingCase }
            try self.validate(next.cases[index].typed, expected)
            var updated = next.cases[index]
            updated.expected = expected
            updated.status = status
            guard !next.cases.contains(where: { $0.id != caseID && self.key($0) == self.key(updated) }) else {
                throw LayoutJournalError.conflictingCase
            }
            next.cases[index] = updated
        }
    }

    func prepareRule(_ receipt: LayoutRuleReceipt, completion: @escaping Completion = { _ in }) {
        mutate(completion) { next in
            try self.validate(receipt.typed, receipt.expected)
            guard !next.rules.contains(where: { $0.id == receipt.id }) else { throw LayoutJournalError.duplicateReceipt }
            guard !next.rules.contains(where: { existing in
                existing.status != .removed && (existing.sourceCaseID == receipt.sourceCaseID ||
                    !Set(existing.written.keys).isDisjoint(with: receipt.written.keys))
            }) else { throw LayoutJournalError.conflictingCase }
            guard let index = next.cases.firstIndex(where: { $0.id == receipt.sourceCaseID }) else { throw LayoutJournalError.missingCase }
            var pending = receipt
            pending.status = .pending
            next.rules.append(pending)
            next.cases[index].receiptIDs.append(receipt.id)
        }
    }

    func activateRule(id: UUID, completion: @escaping Completion = { _ in }) {
        updateRule(id: id, status: .active, completion: completion)
    }

    func removeRule(id: UUID, completion: @escaping Completion = { _ in }) {
        updateRule(id: id, status: .removed, completion: completion)
    }

    func markRuleConflict(id: UUID, completion: @escaping Completion = { _ in }) {
        updateRule(id: id, status: .conflict, completion: completion)
    }

    private func updateRule(id: UUID, status: LayoutRuleReceiptStatus, completion: @escaping Completion) {
        mutate(completion) { next in
            guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw LayoutJournalError.missingReceipt }
            next.rules[index].status = status
        }
    }

    // Запись выполняется сразу в той же очереди, поэтому старый отложенный снимок не восстановит случаи после очистки.
    func clear(completion: @escaping Completion = { _ in }) {
        mutate(completion) { next in
            self.neuralGeneration &+= 1
            next.cases.removeAll()
            next.observations.removeAll()
            next.observationIDs.removeAll()
        }
    }

    func flush(completion: @escaping Completion = { _ in }) {
        mutate(completion) { _ in }
    }

    func export(to url: URL, confirmedOnly: Bool, completion: @escaping Completion = { _ in }) {
        queue.async {
            let result = Result<Void, Error> {
                let destination = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
                let journal = self.file.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
                guard destination != journal else { throw LayoutJournalError.invalidExportDestination }
                self.refreshRetention()
                if let error = self.storageError { throw error }
                let cases = self.state.cases.filter { !confirmedOnly || (($0.status == .confirmed || $0.status == .resolved) && $0.isCompleteWord) }
                let ids = Set(cases.flatMap(\.receiptIDs))
                let rules = self.state.rules.filter { !confirmedOnly || ids.contains($0.id) }
                let export = LayoutJournalSnapshot.Export(schemaVersion: 1, cases: cases, rules: rules, prunedCount: self.state.prunedCount,
                                                          observations: confirmedOnly ? [] : self.state.observations)
                try self.write(self.encoder.encode(export), to: url)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func mutate(_ completion: @escaping Completion, preservingObservationID: UUID? = nil, skipUnchanged: Bool = false, change: @escaping (inout Envelope) throws -> Void) {
        queue.async {
            let result = Result<Void, Error> {
                if let error = self.storageError { throw error }
                var next = self.state
                try change(&next)
                if skipUnchanged && next == self.state { return }
                let data = try self.retainedData(&next, preservingObservationID: preservingObservationID)
                try self.write(data, to: self.file)
                self.state = next
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            storageError = error
            loadError = error
            return
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let data = try Data(contentsOf: file)
            let header = try decoder.decode(Header.self, from: data)
            guard header.schemaVersion == 1 else { throw LayoutJournalError.unsupportedSchema }
            state = try decoder.decode(Envelope.self, from: data)
        } catch {
            loadError = error
            let backup = directory.appendingPathComponent("layout-journal-v1.json.corrupt.\(UUID().uuidString)")
            do { try FileManager.default.moveItem(at: file, to: backup) }
            catch { storageError = error }
            return
        }
        refreshRetention()
    }

    private func refreshRetention() {
        guard storageError == nil else { return }
        var next = state
        do {
            let data = try retainedData(&next)
            if next != state {
                try write(data, to: file)
                state = next
            }
        } catch { loadError = error }
    }

    private func retainedData(_ next: inout Envelope, preservingObservationID: UUID? = nil) throws -> Data {
        prune(&next)
        var data = try encoder.encode(next)
        while data.count > maxBytes {
            guard removeOldestForSize(&next, preservingObservationID: preservingObservationID) else {
                throw LayoutJournalError.sizeLimit
            }
            data = try encoder.encode(next)
        }
        guard data.count <= maxBytes else { throw LayoutJournalError.sizeLimit }
        return data
    }

    private struct Header: Decodable { let schemaVersion: Int }

    private func validate(_ typed: String, _ expected: String) throws {
        guard !typed.isEmpty, !expected.isEmpty, typed.count <= maxWordLength, expected.count <= maxWordLength else {
            throw LayoutJournalError.invalidWord
        }
    }

    private func key(_ item: LayoutCase) -> [String] {
        key(typed: item.typed, expected: item.expected, kind: item.kind, bundleID: item.bundleID, complete: item.isCompleteWord)
    }

    private func key(typed: String, expected: String, kind: LayoutErrorKind, bundleID: String, complete: Bool) -> [String] {
        [typed.precomposedStringWithCanonicalMapping.lowercased(), expected.precomposedStringWithCanonicalMapping.lowercased(),
         kind.rawValue, bundleID, String(complete)]
    }

    private func prune(_ next: inout Envelope) {
        for item in next.cases {
            let words = [item.typed, item.expected] + [item.produced].compactMap { $0 }
                + item.evidence.flatMap { [$0.observation.typed, $0.expected] + [$0.observation.proposed, $0.observation.alternative].compactMap { $0 } }
            if words.contains(where: { $0.isEmpty || $0.count > maxWordLength }) {
                remove(item.id, from: &next)
            }
        }
        for index in next.cases.indices {
            next.cases[index].evidence = Array(next.cases[index].evidence.suffix(5))
        }
        let cutoff = now().addingTimeInterval(-maxAge)
        let count = next.observations.count
        next.observations.removeAll { observation in
            let words = [observation.typed] + [observation.proposed, observation.alternative].compactMap { $0 }
            return observation.recordedAt < cutoff || words.contains { $0.isEmpty || $0.count > maxWordLength }
        }
        next.prunedCount += count - next.observations.count
        for item in next.cases.filter({ $0.lastSeen < cutoff }) { remove(item.id, from: &next) }
        while next.cases.count > maxCases { removeOldest(&next) }
        while next.observations.count > maxObservations { removeOldestObservation(&next) }
    }

    private func removeOldestForSize(_ next: inout Envelope, preservingObservationID: UUID?) -> Bool {
        let observation = next.observations.filter { $0.id != preservingObservationID }.min { $0.recordedAt < $1.recordedAt }
        let item = next.cases.min {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen < $1.lastSeen }
            return $0.firstSeen < $1.firstSeen
        }
        if let item, item.lastSeen <= (observation?.recordedAt ?? .distantFuture) {
            remove(item.id, from: &next)
            return true
        }
        if let observation {
            next.observations.removeAll { $0.id == observation.id }
            next.prunedCount += 1
            return true
        }
        return false
    }

    private func removeOldestObservation(_ next: inout Envelope) {
        guard let index = next.observations.indices.min(by: {
            next.observations[$0].recordedAt < next.observations[$1].recordedAt
        }) else { return }
        next.observations.remove(at: index)
        next.prunedCount += 1
    }

    private func removeOldest(_ next: inout Envelope) {
        let oldest = next.cases.min { left, right in
            let leftResolved = left.status == .resolved || left.status == .rejected
            let rightResolved = right.status == .resolved || right.status == .rejected
            if leftResolved != rightResolved { return leftResolved }
            if left.lastSeen != right.lastSeen { return left.lastSeen < right.lastSeen }
            return left.firstSeen < right.firstSeen
        }
        if let oldest { remove(oldest.id, from: &next) }
    }

    private func remove(_ id: UUID, from next: inout Envelope) {
        next.cases.removeAll { $0.id == id }
        next.observationIDs.removeValue(forKey: id.uuidString)
        next.prunedCount += 1
    }

    private func write(_ data: Data, to url: URL) throws {
        // Временный файл закрыт для других пользователей ещё до атомарной замены.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".journal-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
