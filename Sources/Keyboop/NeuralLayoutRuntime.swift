import Foundation

struct NeuralLayoutLoadedBackend {
    let backend: NeuralLayoutBackend
    let modelID: String
    let sha256: String
    var profile: NeuralLayoutProfile? = nil
}

// Backend принадлежит одной worker-очереди, включая создание и освобождение.
private final class NeuralLayoutBackendSlot: NeuralLayoutBackend {
    var backend: NeuralLayoutBackend?
    func predict(_ word: String) throws -> NeuralLayoutScores {
        guard let backend else { throw NeuralLayoutError.unavailable }
        return try backend.predict(word)
    }
}

final class NeuralLayoutRuntime {
    enum Status { case off, loading, ready, unavailable }
    typealias Schedule = NeuralLayoutCoordinator.Schedule
    private(set) var status: Status = .off
    private(set) var lastError: Error?
    private(set) var mode: NeuralLayoutMode = .off
    private(set) var session = NeuralLayoutSession()
    private let presentation: NeuralLayoutPresentationStore?
    private let factory: () throws -> NeuralLayoutLoadedBackend
    private let work: Schedule
    private let deliver: Schedule
    private let note: (NeuralLayoutRequest) -> Void
    private let result: (NeuralLayoutResult) -> Void
    private let evidence: (NeuralLayoutRequest, NeuralLayoutEvidence) -> Void
    private let slot = NeuralLayoutBackendSlot()
    private var coordinator: NeuralLayoutCoordinator?
    private var pending: NeuralLayoutRequest?
    private var generation: UInt64 = 0
    private var modelID = ""
    private(set) var modelSHA256 = ""
    private(set) var profile: NeuralLayoutProfile?
    private struct Entry {
        let mode: NeuralLayoutMode
        var result: NeuralLayoutResult?
        var detector: Bool??
        var policy: NeuralLayoutPolicyResult?
    }
    private var entries: [NeuralLayoutRequest: Entry] = [:]
    private var order: [NeuralLayoutRequest] = []

    init(mode: NeuralLayoutMode, presentation: NeuralLayoutPresentationStore? = nil, factory: @escaping () throws -> NeuralLayoutLoadedBackend,
         work: Schedule? = nil,
         deliver: @escaping Schedule = { DispatchQueue.main.async(execute: $0) },
         note: @escaping (NeuralLayoutRequest) -> Void = { _ in },
         evidence: @escaping (NeuralLayoutRequest, NeuralLayoutEvidence) -> Void = { _, _ in },
         result: @escaping (NeuralLayoutResult) -> Void = { _ in }) {
        self.presentation = presentation
        self.factory = factory
        let queue = DispatchQueue(label: "com.keyboop.neural-layout.runtime", qos: .utility)
        self.work = work ?? { queue.async(execute: DispatchWorkItem(block: $0)) }
        self.deliver = deliver
        self.note = note
        self.evidence = evidence
        self.result = result
        setMode(mode)
    }

    deinit {
        let slot = slot
        work { slot.backend = nil }
    }

    func setMode(_ mode: NeuralLayoutMode) {
        precondition(Thread.isMainThread)
        guard self.mode != mode else { return }
        if self.mode != .off || status != .off { stop() }
        self.mode = mode
        guard mode != .off else { return }
        status = .loading
        lastError = nil
        publish()
        let generation = self.generation
        let factory = factory
        let slot = slot
        let deliver = deliver
        work { [weak self] in
            let loaded = Result { try factory() }
            let metadata = loaded.map { value -> (String, String, NeuralLayoutProfile?) in
                slot.backend = value.backend
                return (value.modelID, value.sha256, value.profile)
            }
            deliver { [weak self] in
                guard let self, self.generation == generation else { return }
                switch metadata {
                case .failure(let error):
                    self.status = .unavailable
                    self.lastError = error
                    self.pending = nil
                case .success(let metadata):
                    self.modelID = metadata.0
                    self.modelSHA256 = metadata.1
                    self.profile = metadata.2?.modelSHA256 == metadata.1 ? metadata.2 : nil
                    self.status = .ready
                    self.coordinator = NeuralLayoutCoordinator(backend: slot, work: self.work, deliver: self.deliver) { [weak self] result in
                        self?.receive(result)
                    }
                    if let pending = self.pending {
                        self.pending = nil
                        self.coordinator?.submit(pending)
                    }
                }
                self.publish()
            }
        }
    }

    private func publish() {
        presentation?.publish(NeuralLayoutPresentation(mode: mode, status: status, error: lastError.map { String(describing: $0) },
            assistanceAvailable: status == .ready && profile?.enabled == true && profile?.modelSHA256 == modelSHA256))
    }

    func stop() {
        precondition(Thread.isMainThread)
        profile = nil
        generation &+= 1
        invalidateContext()
        coordinator = nil
        mode = .off
        status = .off
        lastError = nil
        publish()
        let slot = slot
        work { slot.backend = nil }
    }

    func changed() {
        precondition(Thread.isMainThread)
        session.changed()
    }

    func invalidateContext() {
        precondition(Thread.isMainThread)
        session.invalidate()
        coordinator?.invalidate()
        pending = nil
        entries.removeAll()
        order.removeAll()
    }

    func request(occurrenceID: UUID, word: String, bundleID: String, layoutCode: String) -> NeuralLayoutRequest {
        NeuralLayoutRequest(epoch: session.epoch, revision: session.revision, occurrenceID: occurrenceID,
                            bundleID: bundleID, layoutCode: layoutCode, word: word)
    }

    func isCurrent(_ request: NeuralLayoutRequest) -> Bool {
        mode != .off && request.epoch == session.epoch && request.revision == session.revision
    }

    func observe(occurrenceID: UUID, word: String, bundleID: String, layoutCode: String, collecting: Bool) {
        precondition(Thread.isMainThread)
        guard mode != .off, status == .loading || status == .ready, (2...20).contains(word.count) else { return }
        let request = request(occurrenceID: occurrenceID, word: word, bundleID: bundleID, layoutCode: layoutCode)
        if collecting { remember(request) }
        if status == .loading { pending = request }
        else if status == .ready { coordinator?.submit(request) }
    }

    func bind(_ request: NeuralLayoutRequest, detectorCyrillic: Bool?) {
        precondition(Thread.isMainThread)
        guard entries[request] != nil else { return }
        entries[request]?.detector = .some(detectorCyrillic)
        emit(request)
    }

    func recordPolicy(_ policy: NeuralLayoutPolicyResult, for request: NeuralLayoutRequest) {
        precondition(Thread.isMainThread)
        entries[request]?.policy = policy
    }

    private func remember(_ request: NeuralLayoutRequest) {
        if entries[request] == nil {
            entries[request] = Entry(mode: mode)
            order.append(request)
            if order.count > 64 { entries.removeValue(forKey: order.removeFirst()) }
        }
        note(request)
    }

    private func receive(_ result: Result<NeuralLayoutResult, Error>) {
        switch result {
        case .failure(let error): lastError = error; publish()
        case .success(let result):
            self.result(result)
            guard entries[result.request] != nil else { return }
            entries[result.request]?.result = result
            emit(result.request)
        }
    }

    private func emit(_ request: NeuralLayoutRequest) {
        guard let entry = entries[request], let result = entry.result, let detector = entry.detector else { return }
        let scores = result.scores
        let winner = NeuralLayoutClass.allCases.max { scores[$0] < scores[$1] }!
        let direction: Bool? = winner == .ruFromEn ? true : (winner == .enFromRu ? false : nil)
        let unsupported = [.he, .heFromEn, .enFromHe, .heFromRu, .ruFromHe].map { scores[$0] }.reduce(0, +)
        let policyBlock: NeuralLayoutBlock?
        if case .blocked(let block) = entry.policy { policyBlock = block } else { policyBlock = nil }
        var saved = NeuralLayoutEvidence(modelID: modelID, modelSHA256: modelSHA256, mode: entry.mode,
            ru: scores[.ru], en: scores[.en], ruFromEn: scores[.ruFromEn], enFromRu: scores[.enFromRu],
            unsupported: unsupported, durationMs: result.durationMs, proposedCyrillic: direction,
            block: policyBlock ?? (!isCurrent(request) ? .stale : ([NeuralLayoutClass.he, .heFromEn, .enFromHe, .heFromRu, .ruFromHe].contains(winner) ? .unsupported : nil)),
            disagreesWithDetector: direction != detector)
        saved.classScores = Dictionary(uniqueKeysWithValues: zip(NeuralLayoutEvidence.classNames, scores.values))
        evidence(request, saved)
        entries.removeValue(forKey: request)
        order.removeAll { $0 == request }
    }
}
