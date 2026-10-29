import Foundation

// Корреляция принадлежит главному потоку, файловое поколение проверяет очередь store.
final class NeuralLayoutEvidenceBuffer {
    private struct Entry {
        let token = UUID()
        var generation: UInt64?
        var observationID: UUID?
        var evidence: NeuralLayoutEvidence?
    }
    private let store: LayoutJournalStore
    private let completion: LayoutJournalStore.Completion
    private var enabled: Bool
    private var entries: [NeuralLayoutRequest: Entry] = [:]
    private var order: [NeuralLayoutRequest] = []
    var count: Int { entries.count }

    init(store: LayoutJournalStore, enabled: Bool, completion: @escaping LayoutJournalStore.Completion = { _ in }) {
        self.store = store
        self.enabled = enabled
        self.completion = completion
    }

    func note(_ request: NeuralLayoutRequest) {
        guard enabled, entries[request] == nil else { return }
        let entry = Entry()
        entries[request] = entry
        order.append(request)
        if order.count > 64 { entries.removeValue(forKey: order.removeFirst()) }
        store.neuralWriteGeneration { [weak self] generation in
            guard let self, self.enabled, self.entries[request]?.token == entry.token else { return }
            self.entries[request]?.generation = generation
            self.attach(request)
        }
    }

    func bind(_ observationID: UUID, to request: NeuralLayoutRequest) {
        guard enabled, entries[request] != nil else { return }
        entries[request]?.observationID = observationID
        attach(request)
    }

    func accept(_ request: NeuralLayoutRequest, evidence: NeuralLayoutEvidence) {
        guard enabled, entries[request] != nil else { return }
        entries[request]?.evidence = evidence
        attach(request)
    }

    func reset() { entries.removeAll(); order.removeAll() }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            reset()
            store.invalidateNeuralWrites(completion: completion)
        }
    }

    private func attach(_ request: NeuralLayoutRequest) {
        guard let entry = entries[request], let generation = entry.generation,
              let id = entry.observationID, let evidence = entry.evidence else { return }
        store.attachNeural(observationID: id, generation: generation, evidence: evidence, completion: completion)
        entries.removeValue(forKey: request)
        order.removeAll { $0 == request }
    }
}
