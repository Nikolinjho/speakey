import Foundation

enum PresenterTests: DiagnosticSuite {
    static let name = "presenter"
    static func run(_ tests: DiagnosticTests) {
        var a = LayoutCase(typed: "ghbdtn", produced: nil, expected: "привет", kind: .missedConversion, bundleID: "test", isCompleteWord: true)
        var b = a; b.id = UUID(); b.expected = "другое"; b.count = 2
        a.status = .resolved
        let presenter = LayoutJournalPresenter()
        tests.check("Разные ожидания остаются отдельными", presenter.rows(cases: [a,b], filter: .init(), sort: .repeats).count == 2)
        tests.check("Повторы сортируются по убыванию", presenter.rows(cases: [a,b], filter: .init(), sort: .repeats).first?.id == b.id)
        tests.check("Применённый случай остаётся видимым", presenter.rows(cases: [a], filter: .init(), sort: .recent).count == 1)
        tests.check("Ревью не применяет правило", !presenter.allowedActions(for: b).contains(.force))
        b.status = .confirmed; b.isCompleteWord = false
        tests.check("Неполное слово нельзя применить", !presenter.allowedActions(for: b).contains(.force))
        b.isCompleteWord = true
        var observation = LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "test", typed: "ghbdtn", proposed: nil, path: .boundary, reason: .appDisabled, action: .blocked, submission: .notNeeded, isCompleteWord: true, uptime: 1)
        b.evidence = [LayoutFeedback(observationID: observation.id, observation: observation, expected: b.expected, kind: b.kind, source: .explicit)]
        tests.check("Заблокированное решение нельзя применить", !presenter.allowedActions(for: b).contains(.force))
        observation.action = .keep; observation.reason = .detectorKeep
        b.evidence[0].observation = observation
        tests.check("Подтверждённый случай доступен для проверки пары", presenter.allowedActions(for: b).contains(.force))
        var older = observation; older.recordedAt = Date(timeIntervalSince1970: 1)
        var latest = observation; latest.id = UUID(); latest.recordedAt = Date(timeIntervalSince1970: 2); latest.bundleID = "other"; latest.dictionaryMatch = .neither
        tests.check("Решения по умолчанию показывают свежие первыми", presenter.observations([older, latest], filter: .init()).map(\.id) == [latest.id, older.id])
        tests.check("Решения фильтруются по приложению и словарю", presenter.observations([older, latest], filter: .init(bundleID: "other", dictionaryMatch: .neither)).map(\.id) == [latest.id])
        tests.check("Решения фильтруются по причине и действию", presenter.observations([older, latest], filter: .init(action: .blocked, reason: .appDisabled)).isEmpty)
        a.count = b.count; a.lastSeen = b.lastSeen
        let expected = [a,b].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        tests.check("Равные повторы имеют стабильный порядок", presenter.rows(cases: [b,a], filter: .init(), sort: .repeats).map(\.id) == expected)
    }
}
