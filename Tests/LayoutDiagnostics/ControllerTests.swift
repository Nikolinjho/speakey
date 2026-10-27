import Foundation

enum ControllerTests: DiagnosticSuite {
    static let name = "controller"
    static func run(_ tests: DiagnosticTests) {
        var feedback: [LayoutFeedback] = []
        var clock: TimeInterval = 1
        let controller = LayoutDiagnosticsController(enabled: false, uptime: { clock }, sink: { feedback.append($0) })
        let occurrence = UUID()
        tests.check("Выключенный сбор не хранит решения", controller.record(occurrenceID: occurrence, bundleID: "test", typed: "ghbdtn", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true) == nil)
        controller.setEnabled(true)
        let event = controller.record(occurrenceID: occurrence, bundleID: "test", typed: "ghbdtn", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)!
        controller.manualConverted(occurrenceID: occurrence, contextID: event.contextID, from: "ghbdtn", to: "привет", submitted: true)
        tests.check("Ручная конверсия сохранённого слова даёт пропуск", feedback.last?.kind == .missedConversion)
        controller.clearTemporaryState()
        let replacement = controller.record(occurrenceID: occurrence, bundleID: "test", typed: "ghbdtn", proposed: "привет", path: .live, reason: .detectorConvert, action: .replace, complete: false)!
        controller.submission(observationID: replacement.id, contextID: replacement.contextID, submitted: true)
        controller.record(occurrenceID: occurrence, bundleID: "test", typed: "привет", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)
        tests.check("Граница не подменяет неполное живое решение", controller.recent.count == 1 && !controller.recent[0].isCompleteWord)
        controller.freezeRecent()
        controller.resetContext()
        tests.check("Замороженные решения переживают смену контекста", controller.frozenRecent.count == 1)
        controller.submission(observationID: replacement.id, contextID: replacement.contextID, submitted: true)
        tests.check("Поздняя доставка не восстанавливает контекст", controller.recent.isEmpty)
        controller.setEnabled(false)
        tests.check("Выключение удаляет замороженный снимок", controller.frozenRecent.isEmpty)
        controller.setEnabled(true)
        let long = String(repeating: "x", count: 129)
        tests.check("Слишком длинный токен не попадает в кольцо", controller.record(occurrenceID: UUID(), bundleID: "test", typed: long, proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true) == nil)
        let priorCount = feedback.count
        controller.addManualCase(typed: long, expected: "x", bundleID: "test", kind: .missedConversion)
        controller.addManualCase(typed: "two words", expected: "x", bundleID: "test", kind: .missedConversion)
        tests.check("Ручной случай тоже ограничен одним токеном", feedback.count == priorCount)
        controller.record(occurrenceID: UUID(), bundleID: "test", typed: "hello", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)
        controller.freezeRecent()
        clock += 11
        tests.check("Замороженные слова исчезают через десять секунд", controller.frozenRecent.isEmpty)
        tests.check("Редактор журнала исключает только своё приложение", LayoutDiagnosticsController.bypassesJournal(editing: true, bundleID: "own", ownBundleID: "own") && !LayoutDiagnosticsController.bypassesJournal(editing: true, bundleID: "other", ownBundleID: "own") && !LayoutDiagnosticsController.bypassesJournal(editing: false, bundleID: "own", ownBundleID: "own"))
        for submitted in [false, true] {
            controller.clearTemporaryState()
            let id = UUID()
            let observation = controller.record(occurrenceID: id, bundleID: "test", typed: "hello", proposed: "руддщ", path: .boundary, reason: .detectorConvert, action: .replace, complete: true)!
            controller.submission(observationID: observation.id, contextID: observation.contextID, submitted: submitted)
            let before = feedback.count
            controller.manualConverted(occurrenceID: id, contextID: observation.contextID, from: "руддщ", to: "hello", submitted: true)
            tests.check("Обратная конверсия требует отправленной автозамены: \(submitted)", feedback.count == before + (submitted ? 1 : 0))
        }
        for reset in ["context", "disable", "clear"] {
            controller.setEnabled(true)
            controller.clearTemporaryState()
            let id = UUID()
            let observation = controller.record(occurrenceID: id, bundleID: "test", typed: "hello", proposed: "руддщ", path: .boundary, reason: .detectorConvert, action: .replace, complete: true)!
            if reset == "context" { controller.resetContext() }
            if reset == "disable" { controller.setEnabled(false); controller.setEnabled(true) }
            if reset == "clear" { controller.clearTemporaryState() }
            let before = feedback.count
            controller.submission(observationID: observation.id, contextID: observation.contextID, submitted: true)
            controller.manualConverted(occurrenceID: id, contextID: observation.contextID, from: "руддщ", to: "hello", submitted: true)
            tests.check("Поздние callback не создают случай после сброса: \(reset)", feedback.count == before && controller.recent.isEmpty)
        }
        for path in [LayoutPath.boundary, .enter, .inlineLive, .pauseLive, .live] {
            let blockedBuffer = KeystrokeBuffer()
            blockedBuffer.onContextReset = { controller.resetContext() }
            blockedBuffer.append("hello")
            let occurrence = blockedBuffer.currentOccurrenceID!
            if path == .boundary { blockedBuffer.boundary(" ") }
            let oldContext = controller.contextID
            blockedBuffer.clear()
            let event = controller.record(occurrenceID: occurrence, bundleID: "test", typed: "hello",
                proposed: "руддщ", path: path, reason: .antiResonance, action: .blocked,
                complete: path == .boundary || path == .enter)!
            tests.check("Блокировка сохраняется после сброса буфера: \(path.rawValue)", controller.recent.last == event && event.contextID != oldContext && event.occurrenceID == occurrence && event.submission == .notNeeded)
            let before = feedback.count
            controller.manualConverted(occurrenceID: occurrence, contextID: event.contextID, from: "hello", to: "руддщ", submitted: true)
            tests.check("Антирезонанс не считается ошибкой автоисправления: \(path.rawValue)", feedback.count == before)
            controller.clearTemporaryState()
            tests.check("Очистка удаляет блокировку: \(path.rawValue)", controller.recent.isEmpty)
        }
        let navigationBuffer = KeystrokeBuffer()
        navigationBuffer.append("hello")
        let navigationID = navigationBuffer.currentOccurrenceID!
        let beforeNavigation = controller.record(occurrenceID: navigationID, bundleID: "test", typed: "hello",
            proposed: "руддщ", path: .live, reason: .detectorConvert, action: .replace, complete: false)!
        let feedbackBeforeNavigation = feedback.count
        controller.resetContext()
        tests.check("Навигация без очистки буфера разрывает диагностический контекст", navigationBuffer.currentWord == "hello" && navigationBuffer.currentOccurrenceID == navigationID && controller.recent.isEmpty && controller.contextID != beforeNavigation.contextID)
        controller.submission(observationID: beforeNavigation.id, contextID: beforeNavigation.contextID, submitted: true)
        controller.manualConverted(occurrenceID: navigationID, contextID: beforeNavigation.contextID, from: "руддщ", to: "hello", submitted: true)
        tests.check("Позднее исправление после навигации не связывается со старым решением", feedback.count == feedbackBeforeNavigation && controller.recent.isEmpty)
        var recorded: [LayoutObservation] = []
        var acknowledgements: [UUID] = []
        controller.onObservation = { recorded.append($0) }
        controller.onSubmission = { id, _ in acknowledgements.append(id) }
        controller.clearTemporaryState()
        let persisted = controller.record(occurrenceID: UUID(), bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", dictionaryMatch: .neither, path: .editing, reason: .editingObserved, action: .keep, complete: false)!
        tests.check("Сохраняется фактическое наблюдение без выдуманной замены", recorded.last == persisted && persisted.proposed == nil && persisted.alternative == "ll")
        controller.clearTemporaryState()
        controller.submission(observationID: persisted.id, contextID: persisted.contextID, submitted: true)
        tests.check("Позднее подтверждение не возвращает очищенное наблюдение", acknowledgements.isEmpty)
        for tail in ["", " "] {
            controller.clearTemporaryState()
            let sourceBuffer = KeystrokeBuffer()
            sourceBuffer.append("дд")
            let sourceID = sourceBuffer.currentOccurrenceID!
            if !tail.isEmpty { sourceBuffer.boundary(tail) }
            _ = controller.record(occurrenceID: sourceID, bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", path: tail.isEmpty ? .editing : .boundary, reason: tail.isEmpty ? .editingObserved : .detectorKeep, action: .keep, complete: !tail.isEmpty)
            let before = feedback.count
            for _ in 0..<(2 + tail.count) {
                sourceBuffer.backspace()
                if let id = sourceBuffer.retypingOccurrenceID ?? sourceBuffer.currentOccurrenceID {
                    controller.observeRetyping(occurrenceID: id, current: sourceBuffer.currentWord)
                }
            }
            for letter in "ll" {
                sourceBuffer.append(String(letter))
                controller.observeRetyping(occurrenceID: sourceBuffer.retypingOccurrenceID ?? sourceBuffer.currentOccurrenceID, current: sourceBuffer.currentWord)
            }
            tests.check("Буфер связывает пропуск со старым словом без ложного удаления хвоста: \(tail.count)", feedback.count == before + 1 && feedback.last?.observationID == recorded.last?.id && feedback.last?.observation.isCompleteWord == !tail.isEmpty)
            tests.check("Новый токен получает свою идентичность после пропуска", sourceBuffer.currentOccurrenceID != sourceID)
        }
        for reset in ["context", "off", "expired", "occurrence"] {
            controller.setEnabled(true); controller.clearTemporaryState()
            let event = controller.record(occurrenceID: UUID(), bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", path: .editing, reason: .editingObserved, action: .keep, complete: false)!
            let before = feedback.count
            if reset == "context" { controller.resetContext() }
            if reset == "off" { controller.setEnabled(false) }
            if reset == "expired" { clock += 4.001 }
            let id = reset == "occurrence" ? UUID() : event.occurrenceID
            controller.observeRetyping(occurrenceID: id, current: "")
            controller.observeRetyping(occurrenceID: id, current: "ll")
            tests.check("Пропуск не синтезируется после потери связи: \(reset)", feedback.count == before)
        }
        let recordedWhileOff = recorded.count
        _ = controller.record(occurrenceID: UUID(), bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", path: .editing, reason: .editingObserved, action: .keep, complete: false)
        controller.setEnabled(false)
        let offCount = recorded.count
        _ = controller.record(occurrenceID: UUID(), bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", path: .editing, reason: .editingObserved, action: .keep, complete: false)
        tests.check("Выключение не вызывает сохранение нового наблюдения", recorded.count == offCount && offCount >= recordedWhileOff)
        controller.setEnabled(true)
        let oldObservation = controller.record(occurrenceID: UUID(), bundleID: "test", typed: "дд", proposed: nil, alternative: "ll", path: .boundary, reason: .detectorKeep, action: .keep, complete: true)!
        clock += 11; controller.resetContext()
        controller.mark(observation: oldObservation, expected: "ll", kind: .missedConversion)
        tests.check("Явная отметка сохранённого решения не зависит от кольца и контекста", feedback.last?.observationID == oldObservation.id && feedback.last?.source == .explicit)
        let buffer = KeystrokeBuffer()
        buffer.onContextReset = { controller.resetContext() }
        buffer.append("hello")
        let oldID = buffer.currentOccurrenceID!
        let auto = controller.record(occurrenceID: oldID, bundleID: "test", typed: "hello", proposed: "руддщ", path: .boundary, reason: .detectorConvert, action: .replace, complete: true)!
        controller.submission(observationID: auto.id, contextID: auto.contextID, submitted: true)
        buffer.applyConversion(converted: "руддщ")
        let beforeRetype = feedback.count
        for _ in 0..<5 {
            buffer.backspace()
            controller.observeRetyping(occurrenceID: buffer.retypingOccurrenceID ?? buffer.currentOccurrenceID, current: buffer.currentWord)
        }
        for letter in "hello" {
            buffer.append(String(letter))
            controller.observeRetyping(occurrenceID: buffer.retypingOccurrenceID ?? buffer.currentOccurrenceID, current: buffer.currentWord)
        }
        tests.check("Реальный буфер связывает полное стирание и перенабор с исходной заменой", feedback.count == beforeRetype + 1 && feedback.last?.source == .retype)
        tests.check("Перенабранный физический токен независим от исправленного", buffer.currentOccurrenceID != oldID)
        buffer.boundary(" ")
        let keep = controller.record(occurrenceID: buffer.lastOccurrenceID!, bundleID: "test", typed: "hello", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)!
        controller.manualConverted(occurrenceID: keep.occurrenceID, contextID: keep.contextID, from: "hello", to: "руддщ", submitted: true)
        tests.check("Использованная старая связь не поглощает исправление нового токена", feedback.last?.observationID == keep.id && feedback.last?.kind == .missedConversion)
    }
}
