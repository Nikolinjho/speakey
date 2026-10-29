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
    struct ReviewedCase: Decodable {
        let name: String
        let typed: String
        let expected: String
        let action: String
        let before: String
        let applied: String
    }
    static func reviewed(_ t: DiagnosticTests, url: URL) throws {
        let cases = try JSONDecoder().decode([ReviewedCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        func decision(_ value: String) throws -> SwapDecision {
            switch value {
            case "keep": return .keep
            case "ru": return .convert(toCyrillic: true)
            case "en": return .convert(toCyrillic: false)
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
        for fixture in cases {
            let suite = "speakey-reviewed-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            for key in ["didSeedExcExamples", "didSeedExcVkLatin", "didUnseedExcSpotlight"] { defaults.set(true, forKey: key) }
            let exceptions = ExceptionStore(defaults: defaults)
            let backend = ExceptionLayoutRuleBackend(exceptions: exceptions)
            guard ["keep", "force"].contains(fixture.action) else { throw CocoaError(.fileReadCorruptFile) }
            let before = try decision(fixture.before)
            let applied = try decision(fixture.applied)
            t.check(fixture.name + " — до", LayoutDetector.decide(word: fixture.typed, exceptions: exceptions) == before)
            let receipt = try LayoutRuleService.prepare(case: item(fixture.typed, fixture.expected), action: fixture.action == "keep" ? .keep : .force, backend: backend)
            try LayoutRuleService.applyPrepared(receipt, backend: backend)
            t.check(fixture.name + " — после применения", LayoutDetector.decide(word: fixture.typed, exceptions: exceptions) == applied)
            let restarted = ExceptionStore(defaults: defaults)
            t.check(fixture.name + " — после пересоздания", LayoutDetector.decide(word: fixture.typed, exceptions: restarted) == applied)
            try LayoutRuleService.restore(receipt, backend: backend)
            t.check(fixture.name + " — после удаления", LayoutDetector.decide(word: fixture.typed, exceptions: exceptions) == before)
        }
    }
    static func run(_ t: DiagnosticTests) {
        let suite = "speakey-rule-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["didSeedExcExamples", "didSeedExcVkLatin", "didUnseedExcSpotlight"] { defaults.set(true, forKey: key) }
        let exceptions = ExceptionStore(defaults: defaults)
        let backend = ExceptionLayoutRuleBackend(exceptions: exceptions)
        func neuralBlocked(_ word: String) -> Bool { LayoutDetector.neuralRuleBlock(word: word, exceptions: exceptions) }
        t.check("Обычный keep не становится явным запретом нейромодели", LayoutDetector.decide(word: "дд", exceptions: exceptions) == .keep && !neuralBlocked("дд"))
        t.check("Каша без правила допускает проверку модели", !neuralBlocked("ghbdtn"))
        for word in ["hello", "привет", "coooool", "круууто", "hello.", "api", "xlsx", ":D"] {
            t.check("Защитный keep сохраняет валидный исходник: \(word)", neuralBlocked(word))
        }
        for (source, target) in [("ghbdtn", "привет"), ("руддщ", "hello"), ("[kt,", "хлеб")] {
            exceptions.addForceSwap(source)
            t.check("Force исходника блокирует модель: \(source)", neuralBlocked(source))
            exceptions.removeForceSwap(source)
            exceptions.addForceSwap(target)
            t.check("Force цели блокирует модель: \(source)", neuralBlocked(source))
            t.check("Настоящий детектор сохраняет force цели: \(source)", LayoutDetector.decide(word: source, exceptions: exceptions) == .convert(toCyrillic: !source.hasCyrillic))
            exceptions.removeForceSwap(target)
        }
        for suffix in ["ю", "б", "ж", "юбж"] {
            let raw = "руддщ" + suffix
            exceptions.addIgnored("руддщ")
            t.check("Ignored сохраняет ядро перед знаком другой раскладки: \(raw)", LayoutDetector.decide(word: raw, exceptions: exceptions) == .keep && neuralBlocked(raw))
            exceptions.removeIgnored("руддщ")
            exceptions.addLearned("руддщ")
            t.check("Learned сохраняет ядро перед знаком другой раскладки: \(raw)", LayoutDetector.decide(word: raw, exceptions: exceptions) == .keep && neuralBlocked(raw))
            exceptions.removeLearned("руддщ")
            exceptions.addForceSwap("руддщ")
            t.check("Force исходника сохраняется перед знаком другой раскладки: \(raw)", LayoutDetector.decide(word: raw, exceptions: exceptions) == .keep && neuralBlocked(raw))
            exceptions.removeForceSwap("руддщ")
            exceptions.addForceSwap("hello")
            t.check("Force цели сохраняется перед знаком другой раскладки: \(raw)", LayoutDetector.decide(word: raw, exceptions: exceptions) == .convert(toCyrillic: false) && neuralBlocked(raw))
            exceptions.removeForceSwap("hello")
        }
        for saved in ["ghbdtn", "1ghbdtn", "ghbdtn.", ":ghbdtn"] {
            exceptions.addIgnored(saved)
            t.check("Сохраняется полная пользовательская защита: \(saved)", neuralBlocked(saved.uppercased()))
            exceptions.removeIgnored(saved)
        }
        exceptions.addIgnored("1ghbdtn")
        t.check("Числовой префикс исключения сохраняется", neuralBlocked("1ghbd"))
        t.check("Пунктуация вокруг числового исключения сохраняется", neuralBlocked("(1GHBDTN)."))
        exceptions.removeIgnored("1ghbdtn")
        exceptions.addIgnored("ghbdtn")
        t.check("Keep защищает префикс", neuralBlocked("ghbd"))
        t.check("Keep ядра сохраняется при внешних цифрах", neuralBlocked("1ghbdtn2"))
        exceptions.removeIgnored("ghbdtn")
        exceptions.addLearned("ghbdtn")
        t.check("Выученная отмена защищает префикс", neuralBlocked("ghbd"))
        exceptions.removeLearned("ghbdtn")
        func decide(_ word: String) -> SwapDecision { LayoutDetector.decide(word: word, exceptions: exceptions) }
        for (source, counterpart) in [("дд", "ll"), ("ll", "дд")] {
            let facts = LayoutObservationFacts.evaluate(source, wordsRu: [], wordsEn: []) { Keymap.convert($0, toCyrillic: $1, table: nil) }
            t.check("Настоящая Keymap сохраняет пару \(source) и отсутствие обоих слов", facts.alternative == counterpart && facts.dictionaryMatch == .neither)
        }
        for (ru, en, expected) in [(Set(["дд"]), Set(["ll"]), LayoutDictionaryMatch.both), (Set(["дд"]), Set<String>(), .source), (Set<String>(), Set(["ll"]), .alternative)] {
            let facts = LayoutObservationFacts.evaluate("дд", wordsRu: ru, wordsEn: en) { Keymap.convert($0, toCyrillic: $1, table: nil) }
            t.check("Словарный факт не подменяет причину решения: \(expected)", facts.dictionaryMatch == expected)
        }
        for typed in ["дд1", "aд", "two words", "🙂"] {
            let facts = LayoutObservationFacts.evaluate(typed, wordsRu: [], wordsEn: []) { Keymap.convert($0, toCyrillic: $1, table: nil) }
            t.check("Контрфактическая пара требует двух буквенных алфавитов и roundtrip: \(typed)", facts.alternative == nil)
        }
        for (source, target) in [("[kt,", "хлеб"), ("хлеб", "[kt,"), ("yj;", "нож"), ("нож", "yj;")] {
            let facts = LayoutObservationFacts.evaluate(source, wordsRu: ["хлеб", "нож"], wordsEn: []) { Keymap.convert($0, toCyrillic: $1, table: nil) }
            t.check("Клавиши знаков входят в реальную пару раскладок: \(source)", facts.alternative == target && facts.dictionaryMatch == (source == "хлеб" || source == "нож" ? .source : .alternative))
        }
        t.check("Короткое дд сохраняет исходное решение детектора", decide("дд") == .keep)
        let unavailable = LayoutObservationFacts.evaluate("дд", wordsRu: nil, wordsEn: nil) { Keymap.convert($0, toCyrillic: $1, table: nil) }
        t.check("Без готового словаря факт недоступен, пара известна", unavailable.alternative == "ll" && unavailable.dictionaryMatch == .unavailable)
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
