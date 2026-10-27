import Foundation

enum ObservationStoreTests: DiagnosticSuite {
    static let name = "observations"

    static func run(_ t: DiagnosticTests) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let observation = JournalStoreTests.feedback().observation
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try! JSONSerialization.jsonObject(with: encoder.encode(observation))
        let fixture: [String: Any] = ["schemaVersion": 1, "cases": [], "rules": [], "prunedCount": 0,
                                    "observationIDs": [:], "observations": [encoded]]
        let file = directory.appendingPathComponent("layout-journal-v1.json")
        try! JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let store = LayoutJournalStore(directory: directory, now: { JournalStoreTests.date })
        let export = directory.appendingPathComponent("export.json")
        let result: Result<Void, Error> = JournalStoreTests.wait { store.export(to: export, confirmedOnly: false, completion: $0) }
        let content = try! JSONSerialization.jsonObject(with: Data(contentsOf: export)) as! [String: Any]
        t.check("Полный экспорт сохраняет наблюдения без обратной связи", (try? result.get()) != nil && (content["observations"] as? [[String: Any]])?.count == 1)
        let loaded: LayoutJournalSnapshot = JournalStoreTests.wait { store.snapshot(completion: $0) }
        t.check("Наблюдение не создаёт случай и ожидание", loaded.cases.isEmpty && loaded.observations == [observation])
        let confirmed = directory.appendingPathComponent("confirmed.json")
        let _: Result<Void, Error> = JournalStoreTests.wait { store.export(to: confirmed, confirmedOnly: true, completion: $0) }
        let confirmedExport = try! JournalStoreTests.decoder().decode(LayoutJournalSnapshot.Export.self, from: Data(contentsOf: confirmed))
        t.check("Подтверждённый экспорт не раскрывает сырые наблюдения", confirmedExport.observations.isEmpty)

        var current = observation
        current.alternative = "привет"
        current.dictionaryMatch = .alternative
        current.path = .editing
        current.reason = .editingObserved
        current.submission = .pending
        func record(_ value: LayoutObservation, into target: LayoutJournalStore = store) -> Bool {
            let result: Result<Void, Error> = JournalStoreTests.wait { target.recordObservation(value, completion: $0) }
            return (try? result.get()) != nil
        }
        func snapshot(_ target: LayoutJournalStore = store) -> LayoutJournalSnapshot {
            JournalStoreTests.wait { target.snapshot(completion: $0) }
        }
        t.check("Обновление наблюдения сохраняет фактическую альтернативу", record(current) && snapshot().observations == [current])
        current.submission = .submitted
        t.check("Подтверждение записи обновляет тот же идентификатор", record(current) && snapshot().observations == [current])
        var stale = current
        stale.submission = .pending
        stale.alternative = nil
        let staleAccepted = record(stale)
        stale.submission = .rejected
        t.check("Поздние pending и противоположный ответ не отменяют submitted", staleAccepted && record(stale) && snapshot().observations == [current])
        let restarted = LayoutJournalStore(directory: directory, now: { JournalStoreTests.date })
        t.check("Наблюдение и ответ переживают перезапуск без дублей", snapshot(restarted).observations == [current] && snapshot(restarted).cases.isEmpty)
        var rejected = current
        rejected.id = UUID()
        rejected.submission = .rejected
        t.check("Отклонённая запись сохранена", record(rejected))
        var opposite = rejected
        opposite.submission = .submitted
        t.check("Поздний submitted не отменяет rejected", record(opposite) && snapshot().observations.last == rejected)
        var invalid = current
        invalid.id = UUID()
        invalid.alternative = String(repeating: "x", count: 129)
        t.check("Длинная альтернатива отклоняется без изменения памяти", !record(invalid) && snapshot().observations.count == 2)
        invalid = current
        invalid.typed = ""
        t.check("Пустое наблюдение отклоняется", !record(invalid))
        invalid = current
        invalid.proposed = String(repeating: "x", count: 129)
        t.check("Длинная замена отклоняется", !record(invalid))
        var callbacksMain = true
        store.recordObservation(observation) { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        store.clear { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        var afterClear = observation
        afterClear.id = UUID()
        afterClear.typed = "new"
        store.recordObservation(afterClear) { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        t.check("Очередь record clear record оставляет только новое наблюдение", snapshot().observations == [afterClear] && callbacksMain)
        let permissions = try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        t.check("Наблюдения сохраняются в закрытом файле", permissions.intValue == 0o600)

        let legacyDirectory = directory.appendingPathComponent("legacy")
        let legacy = LayoutJournalStore(directory: legacyDirectory, now: { JournalStoreTests.date })
        let feedback = JournalStoreTests.feedback()
        let _: Result<Void, Error> = JournalStoreTests.wait { legacy.record(feedback, completion: $0) }
        let item = snapshot(legacy).cases[0]
        let receipt = LayoutRuleReceipt(sourceCaseID: item.id, typed: item.typed, expected: item.expected, before: [:], written: [:])
        let _: Result<Void, Error> = JournalStoreTests.wait { legacy.prepareRule(receipt, completion: $0) }
        let legacyFile = legacyDirectory.appendingPathComponent("layout-journal-v1.json")
        var old = try! JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        old.removeValue(forKey: "observations")
        try! JSONSerialization.data(withJSONObject: old).write(to: legacyFile)
        let legacyRestored = LayoutJournalStore(directory: legacyDirectory, now: { JournalStoreTests.date })
        let oldState = snapshot(legacyRestored)
        t.check("Старый v1 без наблюдений сохраняет случаи и квитанции", oldState.loadError == nil && oldState.observations.isEmpty && oldState.cases == snapshot(legacy).cases && oldState.rules.first?.id == receipt.id)
        t.check("После чтения старого v1 можно записать наблюдение", record(current, into: legacyRestored))
        let _: Result<Void, Error> = JournalStoreTests.wait { legacyRestored.clear(completion: $0) }
        t.check("Очистка наблюдений сохраняет pending квитанцию", snapshot(legacyRestored).observations.isEmpty && snapshot(legacyRestored).cases.isEmpty && snapshot(legacyRestored).rules.first?.status == .pending)
        let _: Result<Void, Error> = JournalStoreTests.wait { legacyRestored.activateRule(id: receipt.id, completion: $0) }
        let _ = record(current, into: legacyRestored)
        let _: Result<Void, Error> = JournalStoreTests.wait { legacyRestored.clear(completion: $0) }
        t.check("Очистка наблюдений сохраняет активную квитанцию", snapshot(legacyRestored).observations.isEmpty && snapshot(legacyRestored).rules.first?.status == .active)

        let saturatedDirectory = directory.appendingPathComponent("saturated")
        let saturated = LayoutJournalStore(directory: saturatedDirectory, now: { JournalStoreTests.date }, maxCases: 1)
        let _: Result<Void, Error> = JournalStoreTests.wait { saturated.record(feedback, completion: $0) }
        let saturatedAccepted = record(current, into: saturated)
        let saturatedRestarted = LayoutJournalStore(directory: saturatedDirectory, now: { JournalStoreTests.date }, maxCases: 1)
        t.check("Заполненный лимит случаев не вытесняет новое наблюдение", saturatedAccepted && snapshot(saturatedRestarted).observations == [current] && snapshot(saturatedRestarted).cases.count == 1)

        let saturatedBytesDirectory = directory.appendingPathComponent("saturated-bytes")
        let saturatedBytes = LayoutJournalStore(directory: saturatedBytesDirectory, now: { JournalStoreTests.date })
        var oldFeedback = feedback
        oldFeedback.createdAt = JournalStoreTests.date.addingTimeInterval(-60)
        let _: Result<Void, Error> = JournalStoreTests.wait { saturatedBytes.record(oldFeedback, completion: $0) }
        let oldCase = snapshot(saturatedBytes).cases[0]
        let activeReceipt = LayoutRuleReceipt(sourceCaseID: oldCase.id, typed: oldCase.typed, expected: oldCase.expected, before: [:], written: [:])
        let _: Result<Void, Error> = JournalStoreTests.wait { saturatedBytes.prepareRule(activeReceipt, completion: $0) }
        let _: Result<Void, Error> = JournalStoreTests.wait { saturatedBytes.activateRule(id: activeReceipt.id, completion: $0) }
        let byteBudget = try! Data(contentsOf: saturatedBytesDirectory.appendingPathComponent("layout-journal-v1.json")).count
        let byteConstrained = LayoutJournalStore(directory: saturatedBytesDirectory, now: { JournalStoreTests.date }, maxBytes: byteBudget)
        let bytesAccepted = record(current, into: byteConstrained)
        let bytesRestarted = LayoutJournalStore(directory: saturatedBytesDirectory, now: { JournalStoreTests.date }, maxBytes: byteBudget)
        let persistedBytes = snapshot(bytesRestarted)
        t.check("Бюджет байтов вытесняет старый случай вместо нового наблюдения", bytesAccepted && persistedBytes.observations == [current] && persistedBytes.cases.isEmpty && persistedBytes.prunedCount == 1)
        t.check("Вытеснение случая по байтам сохраняет активную квитанцию", persistedBytes.rules.first?.id == activeReceipt.id && persistedBytes.rules.first?.status == .active)

        let _: Result<Void, Error> = JournalStoreTests.wait { bytesRestarted.clear(completion: $0) }
        let ledgerFile = saturatedBytesDirectory.appendingPathComponent("layout-journal-v1.json")
        let ledgerBytes = try! Data(contentsOf: ledgerFile)
        let ledgerConstrained = LayoutJournalStore(directory: saturatedBytesDirectory, now: { JournalStoreTests.date }, maxBytes: ledgerBytes.count)
        let ledgerAccepted = record(current, into: ledgerConstrained)
        let ledgerAfter = snapshot(ledgerConstrained)
        t.check("Недостаточный бюджет квитанций возвращает ошибку вместо потери нового решения", !ledgerAccepted && ledgerAfter.observations.isEmpty && ledgerAfter.rules.first?.status == .active && (try? Data(contentsOf: ledgerFile)) == ledgerBytes)

        let limitedDirectory = directory.appendingPathComponent("limited")
        let limited = LayoutJournalStore(directory: limitedDirectory, now: { JournalStoreTests.date }, maxCases: 2, maxObservations: 1)
        let _: Result<Void, Error> = JournalStoreTests.wait { limited.record(feedback, completion: $0) }
        for index in 0..<3 {
            var value = observation
            value.id = UUID()
            value.typed = "word\(index)"
            value.recordedAt = JournalStoreTests.date.addingTimeInterval(Double(index - 3))
            let _ = record(value, into: limited)
        }
        let limitedState = snapshot(limited)
        t.check("Отдельный лимит наблюдений сохраняет новые решения и случаи", limitedState.cases.count == 1 && limitedState.observations.map(\.typed) == ["word2"] && limitedState.prunedCount == 2)
        let aged = LayoutJournalStore(directory: limitedDirectory, now: { JournalStoreTests.date.addingTimeInterval(31 * 86400) })
        t.check("Наблюдения старше тридцати дней удалены при загрузке", snapshot(aged).observations.isEmpty && snapshot(aged).cases.isEmpty && snapshot(aged).prunedCount == 4)
        let bytesDirectory = directory.appendingPathComponent("bytes")
        let bytes = LayoutJournalStore(directory: bytesDirectory, now: { JournalStoreTests.date })
        let _: Result<Void, Error> = JournalStoreTests.wait { bytes.record(feedback, completion: $0) }
        let caseBytes = try! Data(contentsOf: bytesDirectory.appendingPathComponent("layout-journal-v1.json")).count
        var olderObservation = current
        olderObservation.recordedAt = JournalStoreTests.date.addingTimeInterval(-60)
        let _ = record(olderObservation, into: bytes)
        let constrained = LayoutJournalStore(directory: bytesDirectory, now: { JournalStoreTests.date }, maxBytes: caseBytes)
        t.check("Лимит байтов удаляет наблюдение старше случая", snapshot(constrained).observations.isEmpty && snapshot(constrained).cases.count == 1 && snapshot(constrained).prunedCount == 1)
        let loadedDirectory = directory.appendingPathComponent("loaded-invalid")
        let loadedStore = LayoutJournalStore(directory: loadedDirectory, now: { JournalStoreTests.date })
        let _ = record(current, into: loadedStore)
        let loadedFile = loadedDirectory.appendingPathComponent("layout-journal-v1.json")
        var loadedJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: loadedFile)) as! [String: Any]
        var loadedObservations = loadedJSON["observations"] as! [[String: Any]]
        loadedObservations[0]["alternative"] = String(repeating: "x", count: 129)
        loadedJSON["observations"] = loadedObservations
        try! JSONSerialization.data(withJSONObject: loadedJSON).write(to: loadedFile)
        let invalidRestored = LayoutJournalStore(directory: loadedDirectory, now: { JournalStoreTests.date })
        t.check("Загруженная длинная альтернатива удаляется без усечения", snapshot(invalidRestored).observations.isEmpty && snapshot(invalidRestored).prunedCount == 1)
        let zero = LayoutJournalStore(directory: directory.appendingPathComponent("zero"), now: { JournalStoreTests.date }, maxObservations: 0)
        t.check("Нулевой лимит удаляет наблюдение и учитывает удаление", record(current, into: zero) && snapshot(zero).observations.isEmpty && snapshot(zero).prunedCount == 1)
        let invalidDirectory = LayoutJournalStore(directory: file, now: { JournalStoreTests.date })
        t.check("Ошибка каталога не принимает наблюдение", !record(current, into: invalidDirectory) && snapshot(invalidDirectory).loadError != nil)
        let tiny = LayoutJournalStore(directory: directory.appendingPathComponent("tiny"), now: { JournalStoreTests.date }, maxBytes: 1)
        t.check("Ошибка размера не публикует несохранённое наблюдение", !record(current, into: tiny) && snapshot(tiny).observations.isEmpty)
    }
}
