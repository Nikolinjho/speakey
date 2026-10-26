import Foundation

enum JournalStoreTests: DiagnosticSuite {
    static let name = "store"
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
        var value: T?
        operation { value = $0 }
        let deadline = Date().addingTimeInterval(5)
        while value == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        guard let value else { fatalError("Не дождались ответа журнала") }
        return value
    }

    static func feedback(_ word: String = "ghbdtn", expected: String = "привет", complete: Bool = true) -> LayoutFeedback {
        let observation = LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "test.app", typed: word, path: .boundary, reason: .detectorKeep, action: .keep, submission: .notNeeded, isCompleteWord: complete, uptime: 1, recordedAt: date)
        return LayoutFeedback(observationID: observation.id, observation: observation, expected: expected, kind: .missedConversion, source: .explicit, createdAt: date)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func run(_ t: DiagnosticTests) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutJournalStore(directory: directory, now: { date })
        func record(_ value: LayoutFeedback) -> Bool { (try? wait { store.record(value, completion: $0) }.get()) != nil }
        func snapshot() -> LayoutJournalSnapshot { wait { store.snapshot(completion: $0) } }
        let first = feedback()
        t.check("Запись явной обратной связи", record(first))
        t.check("Повтор наблюдения принят", record(first))
        t.check("Другое наблюдение принято", record(feedback("GHBDTN")))
        t.check("Повторы объединены без дубля", snapshot().cases.first?.count == 2 && snapshot().cases.count == 1)
        let restored = LayoutJournalStore(directory: directory, now: { date })
        let loaded: LayoutJournalSnapshot = wait { restored.snapshot(completion: $0) }
        t.check("Повторы сохранены после перезапуска", loaded.cases.first?.count == 2)
        let duplicate: Result<Void, Error> = wait { restored.record(first, completion: $0) }
        t.check("Дубль после перезапуска не увеличивает счётчик", (try? duplicate.get()) != nil && wait { restored.snapshot(completion: $0) }.cases.first?.count == 2)
        t.check("Конфликт ожиданий сохранён отдельно", record(feedback(expected: "другое")) && snapshot().cases.count == 2)
        let conflict = snapshot().cases.first { $0.expected == "другое" }!
        let review: Result<Void, Error> = wait { store.review(caseID: conflict.id, expected: "привет", status: .confirmed, completion: $0) }
        t.check("Правка ожидания не сливает случаи молча", (try? review.get()) == nil && snapshot().cases.count == 2)
        for _ in 0..<7 { _ = record(feedback()) }
        let afterEvidenceRestart = LayoutJournalStore(directory: directory, now: { date })
        let beforeReplay: LayoutJournalSnapshot = wait { afterEvidenceRestart.snapshot(completion: $0) }
        let replay: Result<Void, Error> = wait { afterEvidenceRestart.record(first, completion: $0) }
        let afterReplay: LayoutJournalSnapshot = wait { afterEvidenceRestart.snapshot(completion: $0) }
        t.check("Старое наблюдение не дублируется после вытеснения из свидетельств и перезапуска", (try? replay.get()) != nil && beforeReplay.cases == afterReplay.cases)
        let persisted = try! JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("layout-journal-v1.json"))) as! [String: Any]
        let persistedCases = persisted["cases"] as! [[String: Any]]
        let persistedEvidence = persistedCases[0]["evidence"] as! [[String: Any]]
        let persistedObservation = persistedEvidence[0]["observation"] as! [String: Any]
        let formatter = ISO8601DateFormatter()
        let dateFields = [persistedCases[0]["firstSeen"], persistedCases[0]["lastSeen"], persistedEvidence[0]["createdAt"], persistedObservation["recordedAt"]]
        t.check("Даты журнала записаны строками ISO8601", dateFields.allSatisfy { ($0 as? String).flatMap(formatter.date(from:)) != nil })
        t.check("Сохранены последние пять свидетельств", snapshot().cases.first { $0.expected == "привет" }?.evidence.count == 5)
        t.check("Слишком длинное слово отклонено", !record(feedback(String(repeating: "a", count: 129))))
        var longProduced = feedback()
        longProduced.observation.proposed = String(repeating: "x", count: 129)
        t.check("Длинный результат не попадает в свидетельства", !record(longProduced))
        let source = snapshot().cases.first!
        let receipt = LayoutRuleReceipt(sourceCaseID: source.id, typed: source.typed, expected: source.expected, before: [:], written: [:])
        let prepared: Result<Void, Error> = wait { store.prepareRule(receipt, completion: $0) }
        t.check("Квитанция подготовлена", (try? prepared.get()) != nil && snapshot().rules.first?.status == .pending && snapshot().cases.first { $0.id == source.id }?.receiptIDs == [receipt.id])
        let activated: Result<Void, Error> = wait { store.activateRule(id: receipt.id, completion: $0) }
        t.check("Квитанция активирована", (try? activated.get()) != nil && snapshot().rules.first?.status == .active)
        var callbacksMain = true
        store.record(feedback("old")) { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        store.clear { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        store.record(feedback("new")) { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        let afterClear = snapshot()
        t.check("Очистка упорядочена с соседними записями", afterClear.cases.map(\.typed) == ["new"])
        t.check("Очистка сохраняет активные квитанции", afterClear.rules.first?.status == .active)
        t.check("Ответы приходят в главный поток", callbacksMain)
        let removed: Result<Void, Error> = wait { store.removeRule(id: receipt.id, completion: $0) }
        t.check("Удаление квитанции сохранено", (try? removed.get()) != nil && snapshot().rules.first?.status == .removed)
        let permissions = try? FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let filePermissions = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("layout-journal-v1.json").path)[.posixPermissions] as? NSNumber
        t.check("Доступ к каталогу только владельцу", permissions?.intValue == 0o700)
        t.check("Доступ к файлу только владельцу", filePermissions?.intValue == 0o600)
        let limitedDirectory = directory.appendingPathComponent("limited")
        let limited = LayoutJournalStore(directory: limitedDirectory, now: { date }, maxCases: 2)
        for word in ["a", "b", "c"] { let _: Result<Void, Error> = wait { limited.record(feedback(word), completion: $0) } }
        let limitedSnapshot: LayoutJournalSnapshot = wait { limited.snapshot(completion: $0) }
        t.check("Лимит удаляет старые случаи", limitedSnapshot.cases.count == 2 && limitedSnapshot.prunedCount == 1)
        let aged = LayoutJournalStore(directory: limitedDirectory, now: { date.addingTimeInterval(31 * 86400) })
        let agedSnapshot: LayoutJournalSnapshot = wait { aged.snapshot(completion: $0) }
        t.check("Случаи старше тридцати дней удалены", agedSnapshot.cases.isEmpty && agedSnapshot.prunedCount == 3)
        let invalid = LayoutJournalStore(directory: directory.appendingPathComponent("layout-journal-v1.json"), now: { date })
        let invalidResult: Result<Void, Error> = wait { invalid.record(feedback(), completion: $0) }
        t.check("Неверный каталог возвращает ошибку", (try? invalidResult.get()) == nil)
        for bytes in [Data("{\"schemaVersion\":1,".utf8), Data("{\"schemaVersion\":99}".utf8)] {
            let corruptDirectory = directory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
            try! bytes.write(to: corruptDirectory.appendingPathComponent("layout-journal-v1.json"))
            let corrupt = LayoutJournalStore(directory: corruptDirectory, now: { date })
            let state: LayoutJournalSnapshot = wait { corrupt.snapshot(completion: $0) }
            let backups = (try? FileManager.default.contentsOfDirectory(at: corruptDirectory, includingPropertiesForKeys: nil)) ?? []
            t.check("Повреждённый журнал виден и сохранён без изменений", state.loadError != nil && backups.contains { (try? Data(contentsOf: $0)) == bytes && $0.lastPathComponent.contains(".corrupt") })
            let result: Result<Void, Error> = wait { corrupt.record(feedback(), completion: $0) }
            t.check("После повреждения возможна новая запись", (try? result.get()) != nil)
        }
        let exportDirectory = directory.appendingPathComponent("exports")
        let exports = LayoutJournalStore(directory: exportDirectory, now: { date })
        for item in [feedback("complete"), feedback("incomplete", complete: false), feedback("rejected")] {
            let _: Result<Void, Error> = wait { exports.record(item, completion: $0) }
        }
        let exportCases: LayoutJournalSnapshot = wait { exports.snapshot(completion: $0) }
        for item in exportCases.cases {
            let _: Result<Void, Error> = wait { exports.review(caseID: item.id, expected: item.expected, status: item.typed == "rejected" ? .rejected : .confirmed, completion: $0) }
        }
        let resolved = exportCases.cases.first { $0.typed == "complete" }!
        let _: Result<Void, Error> = wait { exports.review(caseID: resolved.id, expected: resolved.expected, status: .resolved, completion: $0) }
        for confirmed in [false, true] {
            let url = directory.appendingPathComponent("export-\(confirmed).json")
            let result: Result<Void, Error> = wait { exports.export(to: url, confirmedOnly: confirmed, completion: $0) }
            let content = try? decoder().decode(LayoutJournalSnapshot.Export.self, from: Data(contentsOf: url))
            let exported = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let exportedCases = exported["cases"] as! [[String: Any]]
            t.check("Даты экспорта записаны строками ISO8601", exportedCases.allSatisfy { ($0["firstSeen"] as? String).flatMap(formatter.date(from:)) != nil })
            t.check("Экспорт учитывает подтверждение и полноту слова", (try? result.get()) != nil && content?.cases.count == (confirmed ? 1 : 3))
        }
        var clock = date
        let running = LayoutJournalStore(directory: directory.appendingPathComponent("running"), now: { clock })
        let _: Result<Void, Error> = wait { running.record(feedback(), completion: $0) }
        clock = date.addingTimeInterval(31 * 86400)
        let runningSnapshot: LayoutJournalSnapshot = wait { running.snapshot(completion: $0) }
        t.check("Долгоживущий журнал очищает истёкшие случаи при чтении", runningSnapshot.cases.isEmpty && runningSnapshot.prunedCount == 1)
        let reduced = LayoutJournalStore(directory: exportDirectory, now: { date }, maxBytes: 250)
        let reducedSnapshot: LayoutJournalSnapshot = wait { reduced.snapshot(completion: $0) }
        let reducedData = try? Data(contentsOf: exportDirectory.appendingPathComponent("layout-journal-v1.json"))
        t.check("Лимит размера применяется при загрузке", reducedSnapshot.cases.isEmpty && (reducedData?.count ?? 999) <= 250)
        let priorityDirectory = directory.appendingPathComponent("priority")
        let priority = LayoutJournalStore(directory: priorityDirectory, now: { date }, maxCases: 2)
        for word in ["first", "second"] {
            let _: Result<Void, Error> = wait { priority.record(feedback(word), completion: $0) }
        }
        let priorityCases: LayoutJournalSnapshot = wait { priority.snapshot(completion: $0) }
        let rejected = priorityCases.cases.first { $0.typed == "second" }!
        let _: Result<Void, Error> = wait { priority.review(caseID: rejected.id, expected: rejected.expected, status: .rejected, completion: $0) }
        let _: Result<Void, Error> = wait { priority.record(feedback("third"), completion: $0) }
        let priorityAfter: LayoutJournalSnapshot = wait { priority.snapshot(completion: $0) }
        t.check("Отклонённый случай удаляется раньше кандидата", Set(priorityAfter.cases.map(\.typed)) == Set(["first", "third"]))
        let receiptDirectory = directory.appendingPathComponent("receipts")
        let receiptStore = LayoutJournalStore(directory: receiptDirectory, now: { date })
        let _: Result<Void, Error> = wait { receiptStore.record(feedback(), completion: $0) }
        let receiptCases: LayoutJournalSnapshot = wait { receiptStore.snapshot(completion: $0) }
        let receiptCase = receiptCases.cases[0]
        let pending = LayoutRuleReceipt(sourceCaseID: receiptCase.id, typed: receiptCase.typed, expected: receiptCase.expected, before: [:], written: [:])
        let _: Result<Void, Error> = wait { receiptStore.prepareRule(pending, completion: $0) }
        let restartedReceipts = LayoutJournalStore(directory: receiptDirectory, now: { date })
        let restoredReceipts: LayoutJournalSnapshot = wait { restartedReceipts.snapshot(completion: $0) }
        t.check("Подготовленная квитанция переживает перезапуск вместе со случаем", restoredReceipts.rules.first?.status == .pending && restoredReceipts.cases.count == 1)
        let _: Result<Void, Error> = wait { receiptStore.activateRule(id: pending.id, completion: $0) }
        let tiny = LayoutJournalStore(directory: receiptDirectory, now: { date }, maxBytes: 1)
        let sizeFailure: Result<Void, Error> = wait { tiny.clear(completion: $0) }
        let afterFailure: LayoutJournalSnapshot = wait { tiny.snapshot(completion: $0) }
        t.check("Нехватка места не удаляет активное правило и не меняет память", (try? sizeFailure.get()) == nil && afterFailure.rules.first?.status == .active && afterFailure.cases.count == 1)
        let reloadedFailure = LayoutJournalStore(directory: receiptDirectory, now: { date })
        let persistedAfterFailure: LayoutJournalSnapshot = wait { reloadedFailure.snapshot(completion: $0) }
        t.check("Нехватка места не меняет файл", persistedAfterFailure.cases.count == 1 && persistedAfterFailure.rules.first?.status == .active)
        let _: Result<Void, Error> = wait { restartedReceipts.clear(completion: $0) }
        let pendingCleared: LayoutJournalSnapshot = wait { restartedReceipts.snapshot(completion: $0) }
        t.check("Очистка сохраняет подготовленные квитанции", pendingCleared.cases.isEmpty && pendingCleared.rules.first?.status == .pending)
        let cappedDirectory = directory.appendingPathComponent("loaded-evidence")
        let capped = LayoutJournalStore(directory: cappedDirectory, now: { date })
        let _: Result<Void, Error> = wait { capped.record(feedback(), completion: $0) }
        let cappedURL = cappedDirectory.appendingPathComponent("layout-journal-v1.json")
        var fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: cappedURL)) as! [String: Any]
        var fixtureCases = fixture["cases"] as! [[String: Any]]
        let evidence = (fixtureCases[0]["evidence"] as! [[String: Any]])[0]
        fixtureCases[0]["evidence"] = Array(repeating: evidence, count: 9)
        fixture["cases"] = fixtureCases
        try! JSONSerialization.data(withJSONObject: fixture).write(to: cappedURL)
        let cappedReloaded = LayoutJournalStore(directory: cappedDirectory, now: { date })
        let cappedSnapshot: LayoutJournalSnapshot = wait { cappedReloaded.snapshot(completion: $0) }
        t.check("Загруженные свидетельства ограничены пятью", cappedSnapshot.cases.first?.evidence.count == 5)
        fixtureCases[0]["typed"] = String(repeating: "x", count: 129)
        fixture["cases"] = fixtureCases
        try! JSONSerialization.data(withJSONObject: fixture).write(to: cappedURL)
        let overlongReloaded = LayoutJournalStore(directory: cappedDirectory, now: { date })
        let overlongSnapshot: LayoutJournalSnapshot = wait { overlongReloaded.snapshot(completion: $0) }
        t.check("Загруженное длинное слово удаляется без усечения", overlongSnapshot.cases.isEmpty && overlongSnapshot.prunedCount == 1)
        let exportURL = directory.appendingPathComponent("export.json")
        let export: Result<Void, Error> = wait { store.export(to: exportURL, confirmedOnly: true, completion: $0) }
        t.check("Экспорт подтверждённых исключает кандидатов", (try? export.get()) != nil && (try? decoder().decode(LayoutJournalSnapshot.Export.self, from: Data(contentsOf: exportURL)))?.cases.isEmpty == true)
    }
}
