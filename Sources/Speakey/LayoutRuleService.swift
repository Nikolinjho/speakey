import Foundation

protocol LayoutRuleBackend: AnyObject {
    func membership(of word: String) -> LayoutRuleMembership
    func setMembership(_ value: LayoutRuleMembership, of word: String)
    func opposite(of word: String) -> String?
}

enum LayoutRuleAction { case keep, force }
enum LayoutRuleError: Error { case ineligible, unsupportedPair, conflict, busy }

final class LayoutRuleService {
    private let store: LayoutJournalStore
    private let backend: LayoutRuleBackend
    private var busy = false

    init(store: LayoutJournalStore, backend: LayoutRuleBackend) {
        self.store = store
        self.backend = backend
    }

    static func prepare(case item: LayoutCase, action: LayoutRuleAction, backend: LayoutRuleBackend) throws -> LayoutRuleReceipt {
        let allowed: Set<LayoutReason> = [.detectorKeep, .detectorConvert, .mixedRescue, .sessionProtected, .softShort, .softGap, .explicit]
        guard item.status == .confirmed, item.isCompleteWord, let last = item.evidence.last,
              last.observation.isCompleteWord, last.observation.action != .blocked,
              allowed.contains(last.observation.reason) else { throw LayoutRuleError.ineligible }
        let source = item.typed.lowercased(), target = item.expected.lowercased()
        var before = [source: backend.membership(of: source)]
        var written = before
        switch action {
        case .keep:
            guard item.typed == item.expected, !source.isEmpty,
                  !source.contains(where: { $0.isWhitespace }) else { throw LayoutRuleError.unsupportedPair }
            written[source]!.ignored = true
            written[source]!.forceSwap = false
        case .force:
            guard backend.opposite(of: item.typed) == item.expected, target != source else { throw LayoutRuleError.unsupportedPair }
            before[target] = backend.membership(of: target)
            written[source] = LayoutRuleMembership()
            written[target] = LayoutRuleMembership(forceSwap: true)
        }
        return LayoutRuleReceipt(sourceCaseID: item.id, typed: item.typed, expected: item.expected, before: before, written: written)
    }

    private static func matches(_ values: [String: LayoutRuleMembership], backend: LayoutRuleBackend) -> Bool {
        values.allSatisfy { backend.membership(of: $0.key) == $0.value }
    }

    static func applyPrepared(_ receipt: LayoutRuleReceipt, backend: LayoutRuleBackend) throws {
        guard matches(receipt.before, backend: backend) else { throw LayoutRuleError.conflict }
        for (word, value) in receipt.written { backend.setMembership(value, of: word) }
    }

    static func restore(_ receipt: LayoutRuleReceipt, backend: LayoutRuleBackend) throws {
        // Сначала проверяем обе стороны, чтобы конфликт не оставил частичный откат.
        guard matches(receipt.written, backend: backend) else { throw LayoutRuleError.conflict }
        for (word, value) in receipt.before { backend.setMembership(value, of: word) }
    }

    func apply(caseID: UUID, action: LayoutRuleAction, completion: @escaping (Result<LayoutRuleReceipt, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !busy else { completion(.failure(LayoutRuleError.busy)); return }
        busy = true
        func finish(_ result: Result<LayoutRuleReceipt, Error>) { self.busy = false; completion(result) }
        store.snapshot { snapshot in
            do {
                guard let item = snapshot.cases.first(where: { $0.id == caseID }) else { throw LayoutJournalError.missingCase }
                let receipt = try Self.prepare(case: item, action: action, backend: self.backend)
                self.store.prepareRule(receipt) { result in
                    do {
                        try result.get()
                        try Self.applyPrepared(receipt, backend: self.backend)
                        self.store.activateRule(id: receipt.id) { result in
                            finish(result.map { var active = receipt; active.status = .active; return active })
                        }
                    } catch {
                        // Сохранённая pending-квитанция остаётся для восстановления при запуске.
                        finish(.failure(error))
                    }
                }
            } catch { finish(.failure(error)) }
        }
    }

    func remove(id: UUID, completion: @escaping LayoutJournalStore.Completion) {
        precondition(Thread.isMainThread)
        guard !busy else { completion(.failure(LayoutRuleError.busy)); return }
        busy = true
        func finish(_ result: Result<Void, Error>) { self.busy = false; completion(result) }
        store.snapshot { snapshot in
            guard let receipt = snapshot.rules.first(where: { $0.id == id }) else { finish(.failure(LayoutJournalError.missingReceipt)); return }
            guard receipt.status != .removed else { finish(.success(())); return }
            do {
                guard receipt.status == .active || receipt.status == .conflict else { throw LayoutRuleError.conflict }
                try Self.restore(receipt, backend: self.backend)
                self.store.removeRule(id: id, completion: finish)
            } catch {
                self.store.markRuleConflict(id: id) { result in
                    if case .failure(let failure) = result { finish(.failure(failure)) }
                    else { finish(.failure(error)) }
                }
            }
        }
    }

    func forgetConflict(id: UUID, completion: @escaping LayoutJournalStore.Completion) {
        precondition(Thread.isMainThread)
        guard !busy else { completion(.failure(LayoutRuleError.busy)); return }
        busy = true
        store.snapshot { snapshot in
            guard snapshot.rules.contains(where: { $0.id == id && $0.status == .conflict }) else {
                self.busy = false
                completion(.failure(LayoutRuleError.conflict))
                return
            }
            // Явный отказ от квитанции сохраняет текущий выбор пользователя в настройках.
            self.store.removeRule(id: id) { result in self.busy = false; completion(result) }
        }
    }

    func reconcilePending(completion: @escaping LayoutJournalStore.Completion) {
        precondition(Thread.isMainThread)
        guard !busy else { completion(.failure(LayoutRuleError.busy)); return }
        busy = true
        store.snapshot { snapshot in
            let receipts = snapshot.rules.filter { $0.status == .pending }
            func next(_ index: Int) {
                guard index < receipts.count else { self.busy = false; completion(.success(())); return }
                let receipt = receipts[index]
                let done: LayoutJournalStore.Completion = { result in
                    if case .failure = result { self.busy = false; completion(result) }
                    else { next(index + 1) }
                }
                if Self.matches(receipt.before, backend: self.backend) {
                    self.store.removeRule(id: receipt.id, completion: done)
                } else if Self.matches(receipt.written, backend: self.backend) {
                    self.store.activateRule(id: receipt.id, completion: done)
                } else {
                    self.store.markRuleConflict(id: receipt.id, completion: done)
                }
            }
            next(0)
        }
    }
}
