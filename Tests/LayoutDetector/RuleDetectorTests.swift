import Foundation

enum RuleDetectorTests {
    static func item(_ typed: String, _ expected: String) -> LayoutCase {
        let observation = LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "test.app", typed: typed, path: .boundary, reason: .detectorKeep, action: .keep, submission: .notNeeded, isCompleteWord: true, uptime: 1)
        let evidence = LayoutFeedback(observationID: observation.id, observation: observation, expected: expected, kind: .missedConversion, source: .explicit)
        return LayoutCase(typed: typed, expected: expected, kind: .missedConversion, bundleID: "test.app", isCompleteWord: true, status: .confirmed, evidence: [evidence])
    }
    static func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
        var value: T?
        operation { value = $0 }
        let deadline = Date().addingTimeInterval(5)
        while value == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        guard let value else { fatalError("Не дождались записи правила") }
        return value
    }
    static func run(_ t: DiagnosticTests) {
        let suite = "keyboop-rule-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["didSeedExcExamples", "didSeedExcVkLatin", "didUnseedExcSpotlight"] { defaults.set(true, forKey: key) }
        let exceptions = ExceptionStore(defaults: defaults)
        let backend = ExceptionLayoutRuleBackend(exceptions: exceptions)
        func decide(_ word: String) -> SwapDecision { LayoutDetector.decide(word: word, exceptions: exceptions) }
        t.check("Базовое ghbdtn конвертируется", decide("ghbdtn") == .convert(toCyrillic: true))
        t.check("Базовое hello сохраняется", decide("hello") == .keep)
        let keep = try! LayoutRuleService.prepare(case: item("ghbdtn", "ghbdtn"), action: .keep, backend: backend)
        try! LayoutRuleService.applyPrepared(keep, backend: backend)
        t.check("Защита меняет настоящий детектор", decide("ghbdtn") == .keep)
        t.check("Защита действует на live-префикс", LayoutDetector.isExceptionOrPrefix("ghbd", cyrillic: false, exceptions: exceptions) && LayoutDetector.liveDecide(word: "ghbd", exceptions: exceptions) == .keep)
        try! LayoutRuleService.restore(keep, backend: backend)
        t.check("Удаление защиты возвращает конверсию", decide("ghbdtn") == .convert(toCyrillic: true))
        exceptions.addForceSwap("hello")
        t.check("Force на исходной стороне означает keep", decide("hello") == .keep)
        exceptions.addLearned("hello")
        let force = try! LayoutRuleService.prepare(case: item("hello", "руддщ"), action: .force, backend: backend)
        try! LayoutRuleService.applyPrepared(force, backend: backend)
        t.check("Force на цели меняет hello на русский", decide("hello") == .convert(toCyrillic: true))
        t.check("Конфликтующее выученное снято", !exceptions.learned.contains("hello") && !exceptions.forceSwap.contains("hello"))
        let persisted = ExceptionStore(defaults: defaults)
        t.check("Настоящие настройки переживают пересоздание", persisted.forceSwap.contains("руддщ") && !persisted.learned.contains("hello"))
        try! LayoutRuleService.restore(force, backend: backend)
        t.check("Удаление восстанавливает исходные наборы", exceptions.forceSwap.contains("hello") && exceptions.learned.contains("hello") && !exceptions.forceSwap.contains("руддщ") && decide("hello") == .keep)
        t.check("Keymap проверяет ghbdtn и hello", backend.opposite(of: "ghbdtn") == "привет" && backend.opposite(of: "hello") == "руддщ")
        for pair in [("ghbdtn.", "приветю"), ("ghbdtn", "привет."), ("hello1", "руддщ1"), ("heлlo", "руддщ"), ("ghbdtn", "мир"), ("ок", "jr")] {
            t.check("Неподдерживаемая пара \(pair.0) / \(pair.1) отклонена", (try? LayoutRuleService.prepare(case: item(pair.0, pair.1), action: .force, backend: backend)) == nil)
        }
        for source in ["xd", "XD", "xD", "Xd"] {
            let target = Keymap.convert(source, toCyrillic: true)
            exceptions.addForceSwap(target)
            t.check("Ранний guard смайлика \(source) сильнее force", decide(source) == .keep)
            exceptions.removeForceSwap(target)
            let rejected = try? LayoutRuleService.prepare(case: item(source, target), action: .force, backend: backend)
            t.check("Force для смайлика \(source) отклоняется без мёртвой настройки", rejected == nil && !exceptions.forceSwap.contains(target.lowercased()))
        }
        t.check("Keymap сохраняет регистр пары", backend.opposite(of: "HELLO") == "РУДДЩ")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = LayoutJournalStore(directory: directory)
        let feedback = item("ghbdtn", "ghbdtn").evidence[0]
        let _: Result<Void, Error> = wait { seed.record(feedback, completion: $0) }
        let stored = wait { seed.snapshot(completion: $0) }.cases[0]
        let _: Result<Void, Error> = wait { seed.review(caseID: stored.id, expected: stored.expected, status: .confirmed, completion: $0) }
        let failed = LayoutJournalStore(directory: directory, maxBytes: 1)
        let service = LayoutRuleService(store: failed, backend: backend)
        let result: Result<LayoutRuleReceipt, Error> = wait { service.apply(caseID: stored.id, action: .keep, completion: $0) }
        t.check("Ошибка записи квитанции не меняет настоящий детектор", (try? result.get()) == nil && decide("ghbdtn") == .convert(toCyrillic: true) && !exceptions.ignored.contains("ghbdtn"))
        exceptions.setWordMembership("hello", ignored: true, learned: true, forceSwap: true)
        let original = backend.membership(of: "hello")
        let contradiction = try! LayoutRuleService.prepare(case: item("hello", "руддщ"), action: .force, backend: backend)
        try! LayoutRuleService.applyPrepared(contradiction, backend: backend)
        try! LayoutRuleService.restore(contradiction, backend: backend)
        t.check("Даже исходный конфликт наборов восстанавливается точно", backend.membership(of: "hello") == original)
    }
}
