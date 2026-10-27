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
        b.evidence[0].observation.path = .neuralLive
        tests.check("Частичный neuralLive не становится глобальным правилом", presenter.allowedActions(for: b) == [.review])
        b.evidence[0].observation.reason = .neuralConvert
        b.evidence[0].observation.isCompleteWord = false
        tests.check("Нейрозамена части слова доступна только для ревью", presenter.allowedActions(for: b) == [.review])
        tests.check("Без evidence нет пустого блока модели", presenter.neuralDetails(for: observation) == nil)
        observation.neural = NeuralLayoutEvidence(modelID: "fixture", modelSHA256: String(repeating: "a", count: 64), mode: .observe,
            ru: 0, en: 0, ruFromEn: 0.97, enFromRu: 0.01, unsupported: 0.02, durationMs: 2,
            proposedCyrillic: true, block: .profile, disagreesWithDetector: true)
        let details = presenter.neuralDetails(for: observation)
        tests.check("Предложение модели не заменяет фактическое keep", details?.proposedCyrillic == true && details?.action == .keep && details?.submission == .notNeeded)
        tests.check("Причина отказа и оценка доступны отдельно", details?.block == .profile && details?.score == 0.97 && details?.reason == .detectorKeep)
        let originalNeural = observation.neural!
        for block in [NeuralLayoutBlock.unsupported, .stale, .modifiers, .editing] {
            var unsupported = originalNeural
            unsupported.classScores = Dictionary(uniqueKeysWithValues: NeuralLayoutEvidence.classNames.map { ($0, $0 == "he" ? 0.92 : 0.01) })
            unsupported = NeuralLayoutEvidence(modelID: unsupported.modelID, modelSHA256: unsupported.modelSHA256, mode: unsupported.mode,
                ru: 0.01, en: 0.01, ruFromEn: 0.01, enFromRu: 0.01, unsupported: 0.96, durationMs: 2,
                proposedCyrillic: nil, block: block, disagreesWithDetector: true, classScores: unsupported.classScores)
            observation.neural = unsupported
            let value = presenter.neuralDetails(for: observation)
            tests.check("Неподдерживаемый победитель независим от отказа \(block.rawValue)", value?.unsupported == true && value?.score == 0.92 && value?.block == block)
        }
        for winner in NeuralLayoutEvidence.classNames {
            var full = originalNeural
            full.classScores = Dictionary(uniqueKeysWithValues: NeuralLayoutEvidence.classNames.map { ($0, $0 == winner ? 0.92 : 0.01) })
            observation.neural = full
            let value = presenter.neuralDetails(for: observation)
            let direction: Bool? = winner == "ruFromEn" ? true : winner == "enFromRu" ? false : nil
            let proposal: LayoutJournalPresenter.NeuralProposal
            switch winner {
            case "ru", "en": proposal = .keep
            case "ruFromEn": proposal = .ru
            case "enFromRu": proposal = .en
            default: proposal = .unsupported
            }
            tests.check("Все девять оценок определяют предложение \(winner)", value?.proposal == proposal && value?.proposedCyrillic == direction && value?.score == 0.92)
        }
        var legacy = originalNeural
        legacy = NeuralLayoutEvidence(modelID: legacy.modelID, modelSHA256: legacy.modelSHA256, mode: legacy.mode,
            ru: 0.3, en: 0.1, ruFromEn: 0.05, enFromRu: 0.05, unsupported: 0.5, durationMs: 1,
            proposedCyrillic: nil, block: .stale, disagreesWithDetector: true)
        observation.neural = legacy
        tests.check("Старая сумма классов не выдаётся за keep или оценку победителя", presenter.neuralDetails(for: observation)?.proposal == .unknown && presenter.neuralDetails(for: observation)?.score == nil)
        legacy = NeuralLayoutEvidence(modelID: legacy.modelID, modelSHA256: legacy.modelSHA256, mode: legacy.mode,
            ru: 0.8, en: 0.01, ruFromEn: 0.02, enFromRu: 0.02, unsupported: 0.15, durationMs: 1,
            proposedCyrillic: nil, block: .modifiers, disagreesWithDetector: true)
        observation.neural = legacy
        tests.check("Старый однозначный RU победитель сохраняет keep и оценку", presenter.neuralDetails(for: observation)?.proposal == .keep && presenter.neuralDetails(for: observation)?.score == 0.8)
        observation.neural = originalNeural
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
