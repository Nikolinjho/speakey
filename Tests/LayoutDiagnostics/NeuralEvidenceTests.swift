import Foundation

enum NeuralEvidenceTests: DiagnosticSuite {
    static let name = "neural-evidence"
    static func evidence(_ score: Double = 0.8) -> NeuralLayoutEvidence {
        NeuralLayoutEvidence(modelID: "test", modelSHA256: String(repeating: "a", count: 64), mode: .observe,
            ru: 0.01, en: 0.01, ruFromEn: score, enFromRu: 0.01, unsupported: 0.17,
            durationMs: 1, proposedCyrillic: true, block: nil, disagreesWithDetector: true)
    }
    static func request(_ revision: UInt64 = 0) -> NeuralLayoutRequest {
        NeuralLayoutRequest(epoch: UUID(), revision: revision, occurrenceID: UUID(), bundleID: "test", layoutCode: "en", word: "ghbdtn")
    }
    static func run(_ t: DiagnosticTests) {
        var raw = evidence()
        raw.classScores = Dictionary(uniqueKeysWithValues: NeuralLayoutEvidence.classNames.map { ($0, 0.1) })
        t.check("Полные исходные оценки проходят валидацию", (try? raw.validate()) != nil)
        raw.classScores?["he"] = .nan
        t.check("NaN в исходных оценках отклоняется", (try? raw.validate()) == nil)
        raw.classScores?["he"] = 1.1
        t.check("Оценка выше единицы отклоняется", (try? raw.validate()) == nil)
        raw.classScores?["he"] = -0.1
        t.check("Отрицательная исходная оценка отклоняется", (try? raw.validate()) == nil)
        raw.classScores?["he"] = nil
        raw.classScores?["future"] = 0.1
        t.check("Неизвестный ключ вместо класса отклоняется", (try? raw.validate()) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutJournalStore(directory: directory, now: { JournalStoreTests.date })
        func sync(_ operation: (@escaping LayoutJournalStore.Completion) -> Void) -> Bool {
            (try? JournalStoreTests.wait(operation).get()) != nil
        }
        func snapshot() -> LayoutJournalSnapshot { JournalStoreTests.wait { store.snapshot(completion: $0) } }
        var observation = JournalStoreTests.feedback().observation
        observation.alternative = "привет"
        observation.dictionaryMatch = .alternative
        t.check("Сохранено наблюдение keep", sync { store.recordObservation(observation, completion: $0) })
        let feedback = LayoutFeedback(observationID: observation.id, observation: observation, expected: "привет", kind: .missedConversion, source: .explicit, createdAt: JournalStoreTests.date)
        _ = sync { store.record(feedback, completion: $0) }
        let item = snapshot().cases[0]
        let receipt = LayoutRuleReceipt(sourceCaseID: item.id, typed: item.typed, expected: item.expected, before: [:], written: [:], createdAt: JournalStoreTests.date)
        _ = sync { store.prepareRule(receipt, completion: $0) }
        let before = snapshot()
        let old = LayoutJournalStore(directory: directory, now: { JournalStoreTests.date })
        let restored = JournalStoreTests.wait { old.snapshot(completion: $0) }
        t.check("Старый schemaVersion 1 сохраняет случаи и правила без neural", restored.loadError == nil && restored.cases == before.cases && restored.rules == before.rules && restored.observations == [observation] && restored.observations[0].neural == nil)
        let encoded = try! JSONEncoder().encode(observation)
        t.check("nil neural опущен в JSON", !(String(data: encoded, encoding: .utf8)!.contains("neural")))
        let generation = JournalStoreTests.wait { store.neuralWriteGeneration(completion: $0) }
        t.check("Нейросведения прикреплены", sync { store.attachNeural(observationID: observation.id, generation: generation, evidence: evidence(), completion: $0) })
        var expected = observation
        expected.neural = evidence()
        t.check("Обогащение меняет только neural", snapshot().observations == [expected] && snapshot().cases == before.cases && snapshot().rules == before.rules)
        var submitted = observation
        submitted.id = UUID(); submitted.action = .replace; submitted.proposed = "привет"; submitted.submission = .pending
        _ = sync { store.recordObservation(submitted, completion: $0) }
        _ = sync { store.updateSubmission(observationID: submitted.id, submitted: true, completion: $0) }
        _ = sync { store.attachNeural(observationID: submitted.id, generation: generation, evidence: evidence(), completion: $0) }
        t.check("Поздние сведения сохраняют submitted", snapshot().observations.last?.submission == .submitted && snapshot().observations.last?.neural == evidence())
        let file = directory.appendingPathComponent("layout-journal-v1.json")
        let bytes = try! Data(contentsOf: file)
        _ = sync { store.attachNeural(observationID: UUID(), generation: generation, evidence: evidence(), completion: $0) }
        t.check("Неизвестный id не меняет файл", (try? Data(contentsOf: file)) == bytes)
        t.check("Невалидные оценки отклонены", !sync { store.attachNeural(observationID: observation.id, generation: generation, evidence: evidence(.nan), completion: $0) } && (try? Data(contentsOf: file)) == bytes)
        _ = sync { store.clear(completion: $0) }
        _ = sync { store.recordObservation(observation, completion: $0) }
        _ = sync { store.attachNeural(observationID: observation.id, generation: generation, evidence: evidence(), completion: $0) }
        t.check("Очистка инвалидирует старый generation даже при повторном id", snapshot().observations == [observation])
        let invalidatedGeneration = JournalStoreTests.wait { store.neuralWriteGeneration(completion: $0) }
        _ = sync { store.invalidateNeuralWrites(completion: $0) }
        _ = sync { store.attachNeural(observationID: observation.id, generation: invalidatedGeneration, evidence: evidence(), completion: $0) }
        t.check("Инвалидация запрещает прежние записи и сохраняет историю", snapshot().observations == [observation])
        t.check("Оценки вне диапазона отклонены", !sync { store.attachNeural(observationID: observation.id, generation: JournalStoreTests.wait { store.neuralWriteGeneration(completion: $0) }, evidence: evidence(1.1), completion: $0) })
        let buffer = NeuralLayoutEvidenceBuffer(store: store, enabled: true)
        let unmatched = request()
        buffer.note(unmatched)
        let differentRevision = NeuralLayoutRequest(epoch: unmatched.epoch, revision: unmatched.revision + 1,
            occurrenceID: unmatched.occurrenceID, bundleID: unmatched.bundleID, layoutCode: unmatched.layoutCode, word: unmatched.word)
        buffer.accept(differentRevision, evidence: evidence()); buffer.bind(observation.id, to: unmatched)
        _ = snapshot(); _ = snapshot()
        t.check("Одинаковое слово другой ревизии не обогащает запись", snapshot().observations[0].neural == nil)
        buffer.reset()
        let first = request()
        buffer.note(first); buffer.accept(first, evidence: evidence()); buffer.bind(observation.id, to: first)
        _ = snapshot(); _ = snapshot()
        t.check("Результат до наблюдения привязан точно", snapshot().observations[0].neural == evidence())
        _ = sync { store.clear(completion: $0) }; buffer.reset()
        _ = sync { store.recordObservation(observation, completion: $0) }
        let second = request()
        buffer.note(second); buffer.bind(observation.id, to: second)
        _ = snapshot()
        buffer.accept(second, evidence: evidence())
        t.check("Наблюдение до результата обогащено", snapshot().observations[0].neural == evidence())
        _ = sync { store.clear(completion: $0) }; buffer.reset()
        _ = sync { store.recordObservation(observation, completion: $0) }
        let late = request()
        buffer.note(late); buffer.bind(observation.id, to: late)
        buffer.setEnabled(false); buffer.setEnabled(true)
        buffer.accept(late, evidence: evidence())
        _ = snapshot(); _ = snapshot()
        t.check("Выключение отменяет также ожидающий callback generation", snapshot().observations[0].neural == nil)
        buffer.setEnabled(false)
        let disabled = request(); buffer.note(disabled); buffer.bind(observation.id, to: disabled); buffer.accept(disabled, evidence: evidence())
        _ = snapshot()
        t.check("Выключенный сбор не принимает новые сведения", snapshot().observations[0].neural == nil)
        buffer.setEnabled(true)
        let evicted = request(); buffer.note(evicted)
        for revision in 1...64 { let r = request(UInt64(revision)); buffer.note(r); buffer.accept(r, evidence: evidence()) }
        let prefixBytes = try! Data(contentsOf: file)
        _ = snapshot()
        buffer.bind(observation.id, to: evicted); buffer.accept(evicted, evidence: evidence())
        t.check("Буфер ограничен 64 и не пишет префиксы", buffer.count == 64 && snapshot().observations[0].neural == nil && (try? Data(contentsOf: file)) == prefixBytes)
        let pendingClear = request(); buffer.note(pendingClear); buffer.bind(observation.id, to: pendingClear)
        buffer.reset(); _ = sync { store.clear(completion: $0) }
        buffer.accept(pendingClear, evidence: evidence()); _ = snapshot()
        t.check("Поздний результат после очистки не восстанавливает историю", snapshot().observations.isEmpty)
    }
}
