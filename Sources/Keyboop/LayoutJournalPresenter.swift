import Foundation

struct LayoutJournalPresenter {
    struct Filter {
        var kind: LayoutErrorKind?
        var bundleID: String?
        var status: LayoutReviewStatus?
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
              last.observation.isCompleteWord, last.observation.action != .blocked,
              [.detectorKeep, .detectorConvert, .mixedRescue, .sessionProtected, .softShort, .softGap, .explicit].contains(last.observation.reason) else { return [.review] }
        return [.review, item.typed == item.expected ? .keep : .force]
    }
}
