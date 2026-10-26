import Foundation

enum RuleServiceTests: DiagnosticSuite {
    static let name = "rules"
    final class Backend: LayoutRuleBackend {
        var words: [String: LayoutRuleMembership] = [:]
        var writes = 0
        var onWrite: (() -> Void)?
        func membership(of word: String) -> LayoutRuleMembership { words[word] ?? LayoutRuleMembership() }
        func setMembership(_ value: LayoutRuleMembership, of word: String) { onWrite?(); words[word] = value; writes += 1 }
        func opposite(of word: String) -> String? { ["hello": "руддщ", "ghbdtn": "привет"][word] }
    }
    static func example(_ typed: String = "hello", expected: String = "руддщ") -> LayoutCase {
        let observation = LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "test.app", typed: typed, path: .boundary, reason: .detectorKeep, action: .keep, submission: .notNeeded, isCompleteWord: true, uptime: 1)
        let evidence = LayoutFeedback(observationID: observation.id, observation: observation, expected: expected, kind: .missedConversion, source: .explicit)
        return LayoutCase(typed: typed, expected: expected, kind: .missedConversion, bundleID: "test.app", isCompleteWord: true, status: .confirmed, evidence: [evidence])
    }
    static func run(_ t: DiagnosticTests) {
        let backend = Backend()
        let item = example()
        let receipt = try! LayoutRuleService.prepare(case: item, action: .force, backend: backend)
        t.check("Подготовка не меняет словарь", backend.writes == 0)
        t.check("Сила хранится на целевой стороне", receipt.written["руддщ"]?.forceSwap == true && receipt.written["hello"]?.forceSwap == false)
        try! LayoutRuleService.applyPrepared(receipt, backend: backend)
        t.check("Применение записывает обе стороны", backend.membership(of: "руддщ").forceSwap)
        t.check("Внешнее изменение запрещает восстановление всех сторон", {
            backend.words["hello"] = LayoutRuleMembership(learned: true)
            return (try? LayoutRuleService.restore(receipt, backend: backend)) == nil && backend.membership(of: "руддщ").forceSwap
        }())
        var candidate = item; candidate.status = .candidate
        t.check("Неподтверждённый случай запрещён", (try? LayoutRuleService.prepare(case: candidate, action: .force, backend: backend)) == nil)
        candidate = item; candidate.isCompleteWord = false
        t.check("Неполное слово запрещено", (try? LayoutRuleService.prepare(case: candidate, action: .force, backend: backend)) == nil)
        candidate = item; candidate.evidence[0].observation.reason = .developerMode
        t.check("Блокировка не становится правилом", (try? LayoutRuleService.prepare(case: candidate, action: .force, backend: backend)) == nil)
        for reason in [LayoutReason.notReady, .unsupportedScript, .appDisabled, .autoDisabled, .antiResonance, .writeNotSubmitted] {
            candidate = item; candidate.evidence[0].observation.reason = reason
            t.check("Причина \(reason.rawValue) не создаёт правило", (try? LayoutRuleService.prepare(case: candidate, action: .force, backend: backend)) == nil)
        }
        t.check("Произвольная замена запрещена", (try? LayoutRuleService.prepare(case: example(expected: "мир"), action: .force, backend: backend)) == nil)
        backend.words["hello"] = LayoutRuleMembership(learned: true, forceSwap: true)
        var unwanted = example(expected: "hello"); unwanted.kind = .unwantedConversion; unwanted.produced = "руддщ"
        let keep = try! LayoutRuleService.prepare(case: unwanted, action: .keep, backend: backend)
        t.check("Неожиданную конверсию можно защитить с сохранением выученного", keep.written["hello"] == LayoutRuleMembership(ignored: true, learned: true))
        lifecycle(t)
    }
    static func lifecycle(_ t: DiagnosticTests) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutJournalStore(directory: directory)
        let backend = Backend()
        let service = LayoutRuleService(store: store, backend: backend)
        let feedback = example().evidence[0]
        let _: Result<Void, Error> = JournalStoreTests.wait { store.record(feedback, completion: $0) }
        let item = JournalStoreTests.wait { store.snapshot(completion: $0) }.cases[0]
        let _: Result<Void, Error> = JournalStoreTests.wait { store.review(caseID: item.id, expected: item.expected, status: .confirmed, completion: $0) }
        var persistedBeforeWrite = true
        backend.onWrite = {
            let bytes = try! Data(contentsOf: directory.appendingPathComponent("layout-journal-v1.json"))
            let object = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            persistedBeforeWrite = persistedBeforeWrite && (object["rules"] as! [[String: Any]]).contains { $0["status"] as? String == "pending" }
        }
        let applied: Result<LayoutRuleReceipt, Error> = JournalStoreTests.wait { service.apply(caseID: item.id, action: .force, completion: $0) }
        let receipt = try! applied.get()
        backend.onWrite = nil
        t.check("Каждая запись настроек началась после durable pending", persistedBeforeWrite)
        t.check("Оркестратор активирует сохранённую квитанцию", JournalStoreTests.wait { store.snapshot(completion: $0) }.rules[0].status == .active)
        let forgottenActive: Result<Void, Error> = JournalStoreTests.wait { service.forgetConflict(id: receipt.id, completion: $0) }
        t.check("Активную квитанцию нельзя забыть без отката", (try? forgottenActive.get()) == nil)
        let duplicate: Result<LayoutRuleReceipt, Error> = JournalStoreTests.wait { service.apply(caseID: item.id, action: .force, completion: $0) }
        t.check("Повтор не теряет исходный снимок", (try? duplicate.get()) == nil && JournalStoreTests.wait { store.snapshot(completion: $0) }.rules[0].before == receipt.before)
        let _: Result<Void, Error> = JournalStoreTests.wait { store.clear(completion: $0) }
        let removed: Result<Void, Error> = JournalStoreTests.wait { service.remove(id: receipt.id, completion: $0) }
        t.check("Удаление после очистки восстанавливает исходное состояние", (try? removed.get()) != nil && backend.membership(of: "руддщ") == LayoutRuleMembership())
        for mode in 0...2 {
            let source = example(); let feedback = source.evidence[0]
            let _: Result<Void, Error> = JournalStoreTests.wait { store.record(feedback, completion: $0) }
            var item = JournalStoreTests.wait { store.snapshot(completion: $0) }.cases[0]; item.status = .confirmed
            let pending = try! LayoutRuleService.prepare(case: item, action: .force, backend: backend)
            let _: Result<Void, Error> = JournalStoreTests.wait { store.prepareRule(pending, completion: $0) }
            if mode == 1 { try! LayoutRuleService.applyPrepared(pending, backend: backend) }
            if mode == 2 { backend.words["hello"] = LayoutRuleMembership(learned: true) }
            let _: Result<Void, Error> = JournalStoreTests.wait { service.reconcilePending(completion: $0) }
            let status = JournalStoreTests.wait { store.snapshot(completion: $0) }.rules.last!.status
            t.check("Восстановление pending: сценарий \(mode)", status == [.removed, .active, .conflict][mode])
            if mode == 1 { let _: Result<Void, Error> = JournalStoreTests.wait { service.remove(id: pending.id, completion: $0) } }
        }
        let conflict = JournalStoreTests.wait { store.snapshot(completion: $0) }.rules.last!
        let external = backend.words
        let forgotten: Result<Void, Error> = JournalStoreTests.wait { service.forgetConflict(id: conflict.id, completion: $0) }
        t.check("Явное забывание конфликта сохраняет внешние настройки", (try? forgotten.get()) != nil && backend.words == external && JournalStoreTests.wait { store.snapshot(completion: $0) }.rules.last?.status == .removed)
        let failureDirectory = directory.appendingPathComponent("failure")
        let seeded = LayoutJournalStore(directory: failureDirectory)
        let _: Result<Void, Error> = JournalStoreTests.wait { seeded.record(example().evidence[0], completion: $0) }
        let pendingItem = JournalStoreTests.wait { seeded.snapshot(completion: $0) }.cases[0]
        let _: Result<Void, Error> = JournalStoreTests.wait { seeded.review(caseID: pendingItem.id, expected: pendingItem.expected, status: .confirmed, completion: $0) }
        let failed = LayoutJournalStore(directory: failureDirectory, maxBytes: 1)
        let blocked = LayoutRuleService(store: failed, backend: backend)
        let writes = backend.writes
        let result: Result<LayoutRuleReceipt, Error> = JournalStoreTests.wait { blocked.apply(caseID: pendingItem.id, action: .force, completion: $0) }
        t.check("Ошибка хранения не меняет настройки", (try? result.get()) == nil && backend.writes == writes)
    }
}
