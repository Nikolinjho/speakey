import Foundation

enum TrackerTests: DiagnosticSuite {
    static let name = "tracker"

    static func observation(typed: String = "ghbdtn", proposed: String? = nil,
                            action: LayoutAction = .keep, submission: LayoutSubmission = .notNeeded,
                            complete: Bool = true, uptime: TimeInterval = 0) -> LayoutObservation {
        LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "test.editor",
                          typed: typed, proposed: proposed, path: complete ? .boundary : .inlineLive,
                          reason: action == .keep ? .detectorKeep : .detectorConvert,
                          action: action, submission: submission, isCompleteWord: complete, uptime: uptime)
    }

    static func manual(_ tracker: LayoutFeedbackTracker, _ event: LayoutObservation,
                       from: String, to: String, time: TimeInterval = 1) -> LayoutFeedback? {
        tracker.manualConvert(occurrenceID: event.occurrenceID, contextID: event.contextID,
                              from: from, to: to, uptime: time)
    }

    static func run(_ tests: DiagnosticTests) {
        let keep = observation()
        let tracker = LayoutFeedbackTracker()
        tracker.record(keep)
        tests.check("Без действия пользователя нет ошибки", tracker.snapshot(uptime: 1) == [keep])
        let missed = manual(tracker, keep, from: "ghbdtn", to: "привет")
        tests.check("Ручное исправление пропуска связано с исходным решением",
                    missed?.kind == .missedConversion && missed?.expected == "привет" && missed?.observation == keep)
        tests.check("Повторное исправление не учитывается", manual(tracker, keep, from: "ghbdtn", to: "привет") == nil)
        tracker.record(keep)
        tests.check("Повторный callback не оживляет использованное решение", manual(tracker, keep, from: "ghbdtn", to: "привет") == nil)
        let repeated = LayoutFeedbackTracker()
        var newer = keep
        newer.id = UUID()
        newer.uptime = 0.2
        repeated.record(keep)
        repeated.record(newer)
        _ = manual(repeated, newer, from: "ghbdtn", to: "привет")
        tests.check("Несколько решений одного слова дают одно исправление",
                    manual(repeated, keep, from: "ghbdtn", to: "привет") == nil)

        for submission in [LayoutSubmission.submitted, .pending, .rejected, .unknown] {
            let event = observation(typed: "hello", proposed: "руддщ", action: .replace, submission: submission)
            let subject = LayoutFeedbackTracker()
            subject.record(event)
            let feedback = manual(subject, event, from: "руддщ", to: "hello")
            tests.check("Обратное исправление требует отправленной замены: \(submission)",
                        submission == .submitted ? feedback?.kind == .unwantedConversion : feedback == nil)
        }
        let pending = observation(typed: "hello", proposed: "руддщ", action: .replace, submission: .pending)
        let acknowledged = LayoutFeedbackTracker()
        acknowledged.record(pending)
        acknowledged.setSubmission(observationID: pending.id, submitted: true)
        tests.check("Подтверждение отправки позволяет связать обратное исправление",
                    manual(acknowledged, pending, from: "руддщ", to: "hello")?.kind == .unwantedConversion)
        let terminal = LayoutFeedbackTracker()
        terminal.record(pending)
        terminal.setSubmission(observationID: pending.id, submitted: false)
        terminal.setSubmission(observationID: pending.id, submitted: true)
        tests.check("Повторный callback не меняет окончательный отказ",
                    terminal.snapshot(uptime: 1).first?.submission == .rejected)

        let stale = LayoutFeedbackTracker()
        stale.record(keep)
        tests.check("Окно исправления заканчивается после четырёх секунд", manual(stale, keep, from: "ghbdtn", to: "привет", time: 4.001) == nil)
        for sameContext in [true, false] {
            let subject = LayoutFeedbackTracker()
            subject.record(keep)
            tests.check("Совпадение текста не заменяет идентичность слова и контекста: \(sameContext)",
                        subject.manualConvert(occurrenceID: sameContext ? UUID() : keep.occurrenceID,
                                              contextID: sameContext ? keep.contextID : UUID(),
                                              from: "ghbdtn", to: "привет", uptime: 1) == nil)
            tests.check("После смены слова или контекста старая связь не восстанавливается: \(sameContext)",
                        manual(subject, keep, from: "ghbdtn", to: "привет", time: 2) == nil)
        }
        let converted = observation(typed: "Hello", proposed: "Руддщ", action: .replace, submission: .submitted)
        let retyping = LayoutFeedbackTracker()
        retyping.record(converted)
        func retype(_ value: String, _ time: TimeInterval) -> LayoutFeedback? {
            retyping.observeRetyping(occurrenceID: converted.occurrenceID, contextID: converted.contextID, current: value, uptime: time)
        }
        tests.check("Частичное удаление не считается исправлением", retype("Руд", 0.2) == nil)
        tests.check("Полное удаление ждёт повторного ввода", retype("", 0.4) == nil)
        tests.check("Неполный повторный ввод ждёт завершения", retype("he", 0.6) == nil)
        let undone = retype("hello", 1)
        tests.check("Повторный ввод исходного слова подтверждает лишнюю замену",
                    undone?.kind == .unwantedConversion && undone?.source == .retype && undone?.observation.typed == "Hello")
        tests.check("Повторный ввод учитывается один раз", retype("hello", 1.1) == nil)

        let divergent = LayoutFeedbackTracker()
        divergent.record(converted)
        _ = divergent.observeRetyping(occurrenceID: converted.occurrenceID, contextID: converted.contextID, current: "", uptime: 0.2)
        _ = divergent.observeRetyping(occurrenceID: converted.occurrenceID, contextID: converted.contextID, current: "other", uptime: 0.4)
        tests.check("Посторонний ввод отменяет связь", divergent.observeRetyping(occurrenceID: converted.occurrenceID, contextID: converted.contextID, current: "hello", uptime: 1) == nil)

        let continued = LayoutFeedbackTracker()
        continued.record(keep)
        _ = continued.observeRetyping(occurrenceID: keep.occurrenceID, contextID: keep.contextID, current: "ghbdtnx", uptime: 0.2)
        tests.check("Продолжение оставленного слова отменяет связь", manual(continued, keep, from: "ghbdtn", to: "привет") == nil)

        let ring = LayoutFeedbackTracker()
        for index in 0..<33 { ring.record(observation(uptime: Double(index) / 100)) }
        tests.check("Кольцо ограничено 32 решениями", ring.snapshot(uptime: 1).count == 32 && ring.snapshot(uptime: 1).first?.uptime == 0.01)
        tests.check("Решения удаляются через десять секунд", ring.snapshot(uptime: 10.321).isEmpty)
        let reset = LayoutFeedbackTracker()
        reset.record(keep)
        reset.reset(contextID: keep.contextID)
        tests.check("Сброс контекста удаляет решения", reset.snapshot(uptime: 1).isEmpty)
        let live = observation(complete: false)
        let partial = LayoutFeedbackTracker()
        partial.record(live)
        tests.check("Незавершённое живое слово остаётся незавершённым",
                    manual(partial, live, from: "GHBDTN", to: "Привет")?.observation.isCompleteWord == false)
        tests.check("Модель решения сохраняет данные при Codable",
                    (try? JSONDecoder().decode(LayoutObservation.self, from: JSONEncoder().encode(live))) == live)
    }
}
