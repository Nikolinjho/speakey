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
    var neural: NeuralLayoutEvidence? = nil
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
        guard !typed.isEmpty, !typed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            return LayoutObservationFacts(alternative: nil, dictionaryMatch: .unavailable)
        }
        let pair = [true, false].compactMap { direction -> (String, Bool)? in
            let candidate = convert(typed, direction)
            guard candidate.count == typed.count,
                  zip(typed, candidate).allSatisfy({ $0 != $1 }),
                  convert(candidate, !direction) == typed else { return nil }
            return (candidate, direction)
        }.first
        guard let (alternative, toCyrillic) = pair else {
            return LayoutObservationFacts(alternative: nil, dictionaryMatch: .unavailable)
        }
        guard let wordsRu, let wordsEn else { return LayoutObservationFacts(alternative: alternative, dictionaryMatch: .unavailable) }
        let sourceFound = (toCyrillic ? wordsEn : wordsRu).contains(value)
        let alternativeFound = (toCyrillic ? wordsRu : wordsEn).contains(alternative.lowercased())
        let match: LayoutDictionaryMatch = sourceFound ? (alternativeFound ? .both : .source) : (alternativeFound ? .alternative : .neither)
        return LayoutObservationFacts(alternative: alternative, dictionaryMatch: match)
    }
}
