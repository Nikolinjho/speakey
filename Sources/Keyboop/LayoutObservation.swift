import Foundation

enum LayoutPath: String, Codable, Equatable {
    case boundary, enter, inlineLive, pauseLive, live, manual
}

enum LayoutReason: String, Codable, Equatable {
    case detectorKeep, detectorConvert, mixedRescue, sessionProtected, softShort, softGap
    case notReady, unsupportedScript, appDisabled, developerMode, autoDisabled
    case antiResonance, writeNotSubmitted, explicit
}

enum LayoutAction: String, Codable, Equatable { case keep, replace, blocked }
enum LayoutSubmission: String, Codable, Equatable { case notNeeded, pending, submitted, rejected, unknown }
enum LayoutErrorKind: String, Codable, Equatable { case missedConversion, unwantedConversion }
enum LayoutReviewStatus: String, Codable, Equatable { case candidate, confirmed, rejected, resolved }
enum LayoutFeedbackSource: String, Codable, Equatable { case manualFlip, retype, explicit }
enum LayoutRuleReceiptStatus: String, Codable, Equatable { case pending, active, removed, conflict }

struct LayoutObservation: Codable, Equatable, Identifiable {
    var id = UUID()
    var occurrenceID: UUID
    var contextID: UUID
    var bundleID: String
    var typed: String
    var proposed: String?
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
