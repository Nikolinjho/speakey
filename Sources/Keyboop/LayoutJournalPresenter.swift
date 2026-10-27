import Foundation

struct LayoutJournalPresenter {
    struct NeuralDetails: Equatable {
        let proposedCyrillic: Bool?
        let score: Double
        let unsupported: Bool
        let action: LayoutAction
        let submission: LayoutSubmission
        let reason: LayoutReason
        let block: NeuralLayoutBlock?
        let mode: NeuralLayoutMode
    }

    func neuralDetails(for observation: LayoutObservation) -> NeuralDetails? {
        guard let evidence = observation.neural else { return nil }
        return NeuralDetails(proposedCyrillic: evidence.proposedCyrillic,
            score: evidence.proposedCyrillic.map { $0 ? evidence.ruFromEn : evidence.enFromRu } ?? max(evidence.ru, evidence.en),
            unsupported: evidence.block == .unsupported, action: observation.action, submission: observation.submission,
            reason: observation.reason, block: evidence.block, mode: evidence.mode)
    }

    struct Filter {
        var kind: LayoutErrorKind?
        var bundleID: String?
        var status: LayoutReviewStatus?
    }
    struct ObservationFilter {
        var bundleID: String?
        var action: LayoutAction?
        var reason: LayoutReason?
        var dictionaryMatch: LayoutDictionaryMatch?
    }

    func observations(_ observations: [LayoutObservation], filter: ObservationFilter) -> [LayoutObservation] {
        observations.filter {
            (filter.bundleID == nil || $0.bundleID == filter.bundleID) &&
            (filter.action == nil || $0.action == filter.action) &&
            (filter.reason == nil || $0.reason == filter.reason) &&
            (filter.dictionaryMatch == nil || ($0.dictionaryMatch ?? .unavailable) == filter.dictionaryMatch)
        }.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    enum Sort { case repeats, recent }
    enum Action: Equatable { case review, keep, force }

    func rows(cases: [LayoutCase], filter: Filter, sort: Sort) -> [LayoutCase] {
        cases.filter {
            (filter.kind == nil || $0.kind == filter.kind) &&
            (filter.bundleID == nil || $0.bundleID == filter.bundleID) &&
            (filter.status == nil || $0.status == filter.status)
        }.sorted {
            if sort == .repeats, $0.count != $1.count { return $0.count > $1.count }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func allowedActions(for item: LayoutCase) -> [Action] {
        guard item.status == .confirmed, item.isCompleteWord, let last = item.evidence.last,
              last.observation.isCompleteWord, last.observation.path != .neuralLive, last.observation.action != .blocked,
              [.detectorKeep, .detectorConvert, .mixedRescue, .sessionProtected, .softShort, .softGap, .explicit].contains(last.observation.reason) else { return [.review] }
        return [.review, item.typed == item.expected ? .keep : .force]
    }
}
