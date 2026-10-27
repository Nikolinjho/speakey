import Foundation
import CryptoKit

struct PilotRow: Codable {
    var id: String
    var family: String
    var text: String
    var language: String
    var source: String
    var license: String
}
struct Provenance: Decodable {
    let version: Int
    let pilotSHA256: String
    let qualitySHA256: String
    let sources: [String: String]
}
struct QualityFamily: Decodable { let family: String }
struct Event { let index: Int; let result: String }
struct FamilyResult: Encodable {
    let id: String
    let language: String
    let baselineFirst: Int?
    let oracleFirst: Int?
    let baselineCorrect: Bool
    let oracleCorrect: Bool
    var modelFirst: Int? = nil
    var modelCorrect: Bool? = nil
}
struct Report: Encodable {
    var mode = "oracle"
    let pilotSHA256: String
    var families = 0, correctControls = 0, wrongSamples = 0, qualityOverlap = 0, negativeChecks = 0, semanticChecks = 0
    var familiesByLanguage: [String: Int] = [:]
    var prefixes = 0, wrongPrefixes = 0, controlPrefixes = 0
    var wrongPrefixCategories: [String: Int] = [:]
    var controlPrefixCategories: [String: Int] = [:]
    var baselineTruePositives = 0, oracleTruePositives = 0
    var baselineFalsePositives = 0, modelFalsePositives = 0, modelAdditionalFalseConversions = 0
    var earlierTimingOpportunities = 0, additionalRecallOpportunities = 0, admissibleCorrectButTooLate = 0
    var controlsWithHardAdmissibleConversion = 0
    var modelTruePositives: Int? = nil
    var modelEarlierTiming = 0, modelAdditionalRecall = 0, modelPredictions = 0
    var modelPolicyCategories: [String: Int] = [:]
    var wrongModelPolicyCategories: [String: Int] = [:]
    var controlModelPolicyCategories: [String: Int] = [:]
    let fixedMinimumScore = 0.95, fixedMinimumMargin = 0.50
    var wrongModelConfidenceDetails: [String: Int] = [:]
    var controlModelConfidenceDetails: [String: Int] = [:]
    var wrongModelWinners: [String: Int] = [:]
    var wrongTargetScoreMaximum = 0.0
    var modelSHA256: String? = nil
    var familyResults: [FamilyResult] = []
}
struct PilotFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw PilotFailure(description: message) }
}
func data(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
func wrongForm(_ row: PilotRow) -> String { Keymap.convert(row.text, toCyrillic: row.language == "en") }
func validate(_ rows: [PilotRow], excluding quality: Set<String>) throws {
    try require(rows.count == 40, "Требуется 40 семей")
    try require(Set(rows.map(\.family)).count == 40 && Set(rows.map(\.id)).count == 40, "Повтор семьи или ID")
    try require(Set(rows.map(\.family)).isDisjoint(with: quality), "Пересечение с quality families")
    for language in ["en", "ru"] { try require(rows.filter { $0.language == language }.count == 20, "Требуется 20 семей языка") }
    let dictionaries = LayoutData.shared
    for row in rows {
        try require(row.family == row.text && row.text == row.text.lowercased() && (4...16).contains(row.text.count), "Невалидная нормализация или длина")
        try require(row.id.hasPrefix(row.language + "-") && row.license == "MIT" && row.source == "keyswitcher:Resources/words_\(row.language).json", "Невалидное происхождение")
        try require(row.text.allSatisfy { row.language == "en" ? ($0.isASCII && $0.isLetter) : "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".contains($0) }, "Невалидный алфавит")
        try require((row.language == "en" ? dictionaries.wordsEn : dictionaries.wordsRu).contains(row.text), "Нет словарной метки")
        let wrong = wrongForm(row)
        try require(wrong != row.text && Keymap.convert(wrong, toCyrillic: row.language == "ru") == row.text, "Необратимая производная")
        try require(!dictionaries.wordsEn.contains(wrong) && !dictionaries.wordsRu.contains(wrong), "Словарная коллизия производной")
    }
}
func negativeChecks(_ rows: [PilotRow], quality: Set<String>) throws -> Int {
    func rejects(_ name: String, _ changed: [PilotRow], excluding: Set<String>? = nil) throws {
        var rejected = false
        do { try validate(changed, excluding: excluding ?? quality) } catch { rejected = true }
        try require(rejected, "Отрицательная проверка не сработала: " + name)
    }
    try rejects("пересечение", rows, excluding: quality.union([rows[0].family]))
    var changed = rows; changed[0] = rows[1]; try rejects("повтор семьи", changed)
    changed = rows; changed[0].text = "x"; try rejects("длина", changed)
    changed = rows; changed[0].license = "unknown"; try rejects("лицензия", changed)
    changed = rows; changed[0].family = "invalid"; try rejects("метка семьи", changed)
    changed = rows; changed[0].text = "abcd efgh"; changed[0].family = changed[0].text; try rejects("пробел", changed)
    try rejects("объём", Array(rows.dropLast()))
    changed = rows; changed[0].text = "zzzzzzzzzzzzzzzz"; changed[0].family = changed[0].text; try rejects("нет словарной метки", changed)
    changed = rows; changed[0].source = "personal-journal"; try rejects("непубличный источник", changed)
    return 9
}
func converted(_ word: String, direction: Bool) -> String? {
    Keymap.liveConvert(word, toCyrillic: direction, isValidTarget: { LayoutData.shared.wordsRu.contains($0.lowercased()) })
}
func outcome(_ text: String, prefix: String, replacement: String, direction: Bool) -> String {
    replacement + Keymap.convert(String(text.dropFirst(prefix.count)), toCyrillic: direction)
}
func first(_ baseline: Event?, _ proposed: Event?) -> Event? {
    guard let proposed else { return baseline }
    if let baseline, baseline.index <= proposed.index { return baseline }
    return proposed
}

do {
    let args = CommandLine.arguments
    func option(_ key: String) -> String? { args.firstIndex(of: key).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let fixturePath = "Tests/NeuralLayout/opportunity-pilot.jsonl"
    let fixtureData = try data(fixturePath)
    let manifest = try JSONDecoder().decode(Provenance.self, from: data("Tests/NeuralLayout/opportunity-pilot.provenance.json"))
    try require(manifest.version == 1 && digest(fixtureData) == manifest.pilotSHA256, "Изменился пилот")
    let qualityData = try data("Tests/NeuralLayout/quality-source.jsonl")
    try require(digest(qualityData) == manifest.qualitySHA256, "Изменился замороженный quality-корпус")
    for (path, sha) in manifest.sources { try require(digest(try data(path)) == sha, "Изменился публичный словарь") }
    let quality = Set(try qualityData.split(separator: 10).map { try JSONDecoder().decode(QualityFamily.self, from: Data($0)).family })
    let rows = try fixtureData.split(separator: 10).map { try JSONDecoder().decode(PilotRow.self, from: Data($0)) }
    try validate(rows, excluding: quality)
    var report = Report(pilotSHA256: digest(fixtureData))
    if args.contains("--self-test") {
        report.negativeChecks = try negativeChecks(rows, quality: quality)
        let baseline = Event(index: 5, result: "baseline")
        try require(first(baseline, Event(index: 5, result: "model"))?.result == "baseline", "Равный префикс: baseline первым")
        try require(first(baseline, Event(index: 4, result: "model"))?.result == "model", "Более ранний кандидат")
        try require(first(baseline, Event(index: 6, result: "model"))?.result == "baseline", "Поздний кандидат")
        try require(first(nil, Event(index: 4, result: "model"))?.result == "model", "Дополнительный кандидат")
        try require(first(baseline, nil)?.result == "baseline", "Нет кандидата: baseline сохранён")
        report.semanticChecks = 5
    }
    let domain = "keyboop-opportunity-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let exceptions = ExceptionStore(defaults: defaults)
    var predict: ((String) throws -> NeuralLayoutScores)?
    var profile: NeuralLayoutProfile?
    var cache: [String: NeuralLayoutScores] = [:]
    #if MODEL_ENABLED
    if let path = option("--model") {
        let sha = digest(try data("Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel"))
        let model = try RightLayoutModel(modelURL: URL(fileURLWithPath: path))
        predict = { try model.predict($0) }
        profile = try NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0.95, minimumMargin: 0.50)
        report.mode = "fixed-model-counterfactual"; report.modelSHA256 = sha; report.modelTruePositives = 0
    }
    #endif
    for row in rows {
        report.families += 1; report.familiesByLanguage[row.language, default: 0] += 1
        for wrong in [true, false] {
            if wrong { report.wrongSamples += 1 } else { report.correctControls += 1 }
            let text = wrong ? wrongForm(row) : row.text
            var baseline: Event?, oracle: Event?, modelEvent: Event?
            var controlAdmissible = false
            for index in 4...min(16, text.count) {
                report.prefixes += 1
                if wrong { report.wrongPrefixes += 1 } else { report.controlPrefixes += 1 }
                let prefix = String(text.prefix(index))
                if baseline == nil, case .convert(let direction) = LayoutDetector.liveDecide(word: prefix, exceptions: exceptions),
                   let result = converted(prefix, direction: direction), result != prefix {
                    baseline = Event(index: index, result: outcome(text, prefix: prefix, replacement: result, direction: direction))
                }
                let supported = NeuralLayoutToken.assistanceSupported(prefix)
                let rule = LayoutDetector.neuralRuleBlock(word: prefix, exceptions: exceptions)
                let direction = !prefix.hasCyrillic
                let replacement = converted(prefix, direction: direction)
                let result = replacement.map { outcome(text, prefix: prefix, replacement: $0, direction: direction) }
                let category: String
                if !supported { category = "unsupported-token" }
                else if rule { category = "protected-rule-or-source" }
                else if replacement == nil { category = "conversion-unavailable" }
                else if replacement == prefix { category = "conversion-unchanged" }
                else if result != row.text { category = "admissible-wrong-outcome"; controlAdmissible = true }
                else {
                    category = "admissible-correct-outcome"
                    if oracle == nil { oracle = Event(index: index, result: result!) }
                }
                if wrong { report.wrongPrefixCategories[category, default: 0] += 1 }
                else { report.controlPrefixCategories[category, default: 0] += 1 }
                if let predict, let profile {
                    let values: NeuralLayoutScores
                    if let cached = cache[prefix] { values = cached }
                    else { values = try predict(prefix); cache[prefix] = values }
                    let admission = NeuralLayoutAdmission(mode: .assist, modelSHA256: profile.modelSHA256, profile: profile, fresh: true,
                        block: !supported ? .unsupported : (rule ? .rule : nil), wordLength: prefix.count, sourceCyrillic: prefix.hasCyrillic)
                    let decision = NeuralLayoutPolicy.evaluate(scores: values, admission: admission)
                    let target: NeuralLayoutClass = prefix.hasCyrillic ? .enFromRu : .ruFromEn
                    let winner = NeuralLayoutClass.allCases.max { values[$0] < values[$1] }!
                    if wrong {
                        report.wrongModelWinners[String(describing: winner), default: 0] += 1
                        report.wrongTargetScoreMaximum = max(report.wrongTargetScoreMaximum, values[target])
                    }
                    if case .blocked(.confidence) = decision {
                        let confidenceDetail: String
                        if winner != target { confidenceDetail = "winner-not-target" }
                        else if values[target] < profile.minimumScore { confidenceDetail = "target-score-below-fixed-0.95" }
                        else {
                            let runner = NeuralLayoutClass.allCases.filter { $0 != target }.map { values[$0] }.max()!
                            confidenceDetail = values[target] - runner < profile.minimumMargin ? "target-margin-below-fixed-0.50" : "unexpected-confidence"
                        }
                        if wrong { report.wrongModelConfidenceDetails[confidenceDetail, default: 0] += 1 }
                        else { report.controlModelConfidenceDetails[confidenceDetail, default: 0] += 1 }
                    }
                    let policyCategory: String
                    switch decision {
                    case .blocked(let block): policyCategory = "blocked." + block.rawValue
                    case .observe: policyCategory = "observe"
                    case .propose(let direction):
                        if let converted = converted(prefix, direction: direction), converted != prefix {
                            policyCategory = "propose"
                            if modelEvent == nil { modelEvent = Event(index: index, result: outcome(text, prefix: prefix, replacement: converted, direction: direction)) }
                        } else { policyCategory = "conversion-unavailable-or-unchanged" }
                    }
                    report.modelPolicyCategories[policyCategory, default: 0] += 1
                    if wrong { report.wrongModelPolicyCategories[policyCategory, default: 0] += 1 }
                    else { report.controlModelPolicyCategories[policyCategory, default: 0] += 1 }
                }
            }
            let oracleChosen = first(baseline, oracle)
            let modelChosen = first(baseline, modelEvent)
            let baselineCorrect = baseline?.result == row.text
            let oracleCorrect = oracleChosen?.result == row.text
            if wrong {
                if baselineCorrect { report.baselineTruePositives += 1 }
                if oracleCorrect { report.oracleTruePositives += 1 }
                if baselineCorrect, let oracle, let baseline, oracle.index < baseline.index { report.earlierTimingOpportunities += 1 }
                if !baselineCorrect && oracleCorrect { report.additionalRecallOpportunities += 1 }
                if !baselineCorrect && !oracleCorrect && oracle != nil { report.admissibleCorrectButTooLate += 1 }
                var family = FamilyResult(id: row.id, language: row.language, baselineFirst: baseline?.index, oracleFirst: oracleChosen?.index, baselineCorrect: baselineCorrect, oracleCorrect: oracleCorrect)
                if predict != nil {
                    family.modelFirst = modelChosen?.index; family.modelCorrect = modelChosen?.result == row.text
                    if family.modelCorrect == true { report.modelTruePositives! += 1 }
                    if family.modelCorrect == true && !baselineCorrect { report.modelAdditionalRecall += 1 }
                    if family.modelCorrect == true, baselineCorrect, let chosen = modelChosen, let baseline, chosen.index < baseline.index { report.modelEarlierTiming += 1 }
                    if let chosen = modelChosen, chosen.result != row.text, baselineCorrect || baseline == nil { report.modelAdditionalFalseConversions += 1 }
                }
                report.familyResults.append(family)
            } else {
                if baseline != nil { report.baselineFalsePositives += 1 }
                if controlAdmissible { report.controlsWithHardAdmissibleConversion += 1 }
                if predict != nil, let chosen = modelChosen {
                    report.modelFalsePositives += 1
                    if chosen.result != row.text && baseline == nil { report.modelAdditionalFalseConversions += 1 }
                }
            }
        }
    }
    report.modelPredictions = cache.count
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let output = try encoder.encode(report)
    guard let path = option("--output") else { throw PilotFailure(description: "Нужен --output") }
    try output.write(to: URL(fileURLWithPath: path))
    print("Пилот: \(report.families) семей, \(report.prefixes) префиксов; baseline \(report.baselineTruePositives)/40; oracle \(report.oracleTruePositives)/40; раньше \(report.earlierTimingOpportunities); дополнительный recall \(report.additionalRecallOpportunities); mode=\(report.mode)")
} catch {
    fputs("FAIL: \(error)\n", stderr); exit(1)
}
