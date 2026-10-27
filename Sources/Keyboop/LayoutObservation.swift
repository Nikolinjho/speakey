import Foundation

enum LayoutPath: String, Codable, Equatable {
    case boundary, enter, inlineLive, pauseLive, live, manual, editing
}

enum LayoutReason: String, Codable, Equatable, CaseIterable {
    case detectorKeep, detectorConvert, mixedRescue, sessionProtected, softShort, softGap
    case notReady, unsupportedScript, appDisabled, developerMode, autoDisabled, triggerDisabled
    case antiResonance, writeNotSubmitted, explicit, editingObserved
}

enum LayoutAction: String, Codable, Equatable, CaseIterable { case keep, replace, blocked }
enum LayoutSubmission: String, Codable, Equatable { case notNeeded, pending, submitted, rejected, unknown }
enum LayoutErrorKind: String, Codable, Equatable { case missedConversion, unwantedConversion }
enum LayoutReviewStatus: String, Codable, Equatable { case candidate, confirmed, rejected, resolved }
enum LayoutFeedbackSource: String, Codable, Equatable { case manualFlip, retype, explicit }
enum LayoutRuleReceiptStatus: String, Codable, Equatable { case pending, active, removed, conflict }

enum LayoutDictionaryMatch: String, Codable, Equatable, CaseIterable { case source, alternative, both, neither, unavailable }

struct LayoutObservation: Codable, Equatable, Identifiable {
    var id = UUID()
    var occurrenceID: UUID
    var contextID: UUID
    var bundleID: String
    var typed: String
    var proposed: String?
    var alternative: String? = nil
    var dictionaryMatch: LayoutDictionaryMatch? = nil
    var path: LayoutPath
    var reason: LayoutReason
    var action: LayoutAction
    var submission: LayoutSubmission
    var isCompleteWord: Bool
    var uptime: TimeInterval
    var recordedAt = Date()
}

struct LayoutFeedback: Codable, Equatable, Identifiable {
    var id = UUID()
    var observationID: UUID
    var observation: LayoutObservation
    var expected: String
    var kind: LayoutErrorKind
    var source: LayoutFeedbackSource
    var createdAt = Date()
}

struct LayoutCase: Codable, Equatable, Identifiable {
    var id = UUID()
    var typed: String
    var produced: String?
    var expected: String
    var kind: LayoutErrorKind
    var bundleID: String
    var isCompleteWord: Bool
    var count = 1
    var firstSeen = Date()
    var lastSeen = Date()
    var status: LayoutReviewStatus = .candidate
    var evidence: [LayoutFeedback] = []
    var receiptIDs: [UUID] = []
}

struct LayoutRuleMembership: Codable, Equatable {
    var ignored = false
    var learned = false
    var forceSwap = false
}

struct LayoutRuleReceipt: Codable, Equatable, Identifiable {
    var id = UUID()
    var sourceCaseID: UUID
    var typed: String
    var expected: String
    var before: [String: LayoutRuleMembership]
    var written: [String: LayoutRuleMembership]
    var status: LayoutRuleReceiptStatus = .pending
    var createdAt = Date()
}

struct LayoutObservationFacts {
    var alternative: String?
    var dictionaryMatch: LayoutDictionaryMatch

    static func evaluate(_ typed: String, wordsRu: Set<String>?, wordsEn: Set<String>?,
                         convert: (String, Bool) -> String) -> LayoutObservationFacts {
        let value = typed.lowercased()
        let latin = !value.isEmpty && value.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        let cyrillic = !value.isEmpty && value.unicodeScalars.allSatisfy { (1072...1103).contains($0.value) || $0.value == 1105 }
        guard latin || cyrillic else { return LayoutObservationFacts(alternative: nil, dictionaryMatch: .unavailable) }
        let alternative = convert(typed, latin)
        let opposite = alternative.lowercased().unicodeScalars.allSatisfy {
            latin ? ((1072...1103).contains($0.value) || $0.value == 1105) : (97...122).contains($0.value)
        }
        guard opposite, alternative != typed, convert(alternative, !latin) == typed else {
            return LayoutObservationFacts(alternative: nil, dictionaryMatch: .unavailable)
        }
        guard let wordsRu, let wordsEn else { return LayoutObservationFacts(alternative: alternative, dictionaryMatch: .unavailable) }
        let sourceFound = (latin ? wordsEn : wordsRu).contains(value)
        let alternativeFound = (latin ? wordsRu : wordsEn).contains(alternative.lowercased())
        let match: LayoutDictionaryMatch = sourceFound ? (alternativeFound ? .both : .source) : (alternativeFound ? .alternative : .neither)
        return LayoutObservationFacts(alternative: alternative, dictionaryMatch: match)
    }
}
