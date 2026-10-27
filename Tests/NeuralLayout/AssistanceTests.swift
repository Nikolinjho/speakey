import Foundation

enum AssistanceTests: DiagnosticSuite {
    static let name = "assistance"
    static func run(_ t: DiagnosticTests) {
        MarkerTests.run(t)
        var now = 1.0
        var mailbox = NeuralLayoutMailbox(now: { now })
        var session = NeuralLayoutSession()
        let occurrence = UUID()
        func result(_ word: String = "ghbdtn") -> NeuralLayoutResult {
            NeuralLayoutResult(request: NeuralLayoutRequest(epoch: session.epoch, revision: session.revision,
                occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: word),
                scores: try! NeuralLayoutScores(logits: [0, 0, 0, 20, 0, 0, 0, 0, 0]), durationMs: 1)
        }
        let a = mailbox.offer(result: result())!
        let b = mailbox.offer(result: result("ghbdtns"))!
        t.check("Старый A не извлекает новый B", mailbox.take(token: a) == nil)
        t.check("B остаётся доступен", mailbox.take(token: b)?.request.word == "ghbdtns")
        t.check("Повторный B ничего не извлекает", mailbox.take(token: b) == nil)
        let revoked = mailbox.offer(result: result())!
        mailbox.cancel(token: a)
        t.check("Отмена старого A не отзывает новый pending", mailbox.take(token: revoked) != nil)
        let c = mailbox.offer(result: result())!
        mailbox.invalidate()
        t.check("Invalidate отзывает заявку", mailbox.take(token: c) == nil)
        let d = mailbox.offer(result: result())!
        t.check("Token не переиспользуется", d > c)
        now += 0.501
        t.check("TTL ограничен половиной секунды", mailbox.take(token: d) == nil)
        var exhausted = NeuralLayoutMailbox(lastToken: UInt32.max - 1)
        t.check("Последний token разрешён", exhausted.offer(result: result()) == UInt32.max)
        exhausted.invalidate()
        t.check("Переполнение навсегда блокирует новые заявки", exhausted.offer(result: result()) == nil)
        let pending = result()
        let profile = try! NeuralLayoutProfile(modelSHA256: String(repeating: "a", count: 64), enabled: true, minimumScore: 0.7, minimumMargin: 0.3)
        func policy(fresh: Bool, block: NeuralLayoutBlock? = nil, word: String = "ghbdtn") -> NeuralLayoutPolicyResult {
            NeuralLayoutAssistance.policy(result: pending, mode: .assist, modelSHA256: profile.modelSHA256,
                profile: profile, fresh: fresh, block: block, word: word, ruleBlocked: false)
        }
        t.check("Разрешённый профиль предлагает замену", policy(fresh: true) == .propose(toCyrillic: true))
        for block in [NeuralLayoutBlock.app, .developer, .secureInput, .modifiers, .editing, .syntheticFlight, .undo, .unavailable, .rule] {
            t.check("Живой запрет \(block) отклоняет замену", policy(fresh: true, block: block) == .blocked(block))
        }
        t.check("Смешанное слово отклоняется", policy(fresh: true, word: "ghпр") == .blocked(.unsupported))
        let request = pending.request
        let changedRequests = [
            NeuralLayoutRequest(epoch: UUID(), revision: request.revision, occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: "ghbdtn"),
            NeuralLayoutRequest(epoch: request.epoch, revision: request.revision + 1, occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: "ghbdtn"),
            NeuralLayoutRequest(epoch: request.epoch, revision: request.revision, occurrenceID: UUID(), bundleID: "app", layoutCode: "en", word: "ghbdtn"),
            NeuralLayoutRequest(epoch: request.epoch, revision: request.revision, occurrenceID: occurrence, bundleID: "other", layoutCode: "en", word: "ghbdtn"),
            NeuralLayoutRequest(epoch: request.epoch, revision: request.revision, occurrenceID: occurrence, bundleID: "app", layoutCode: "ru", word: "ghbdtn"),
            NeuralLayoutRequest(epoch: request.epoch, revision: request.revision, occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: "ghbdtns")
        ]
        for changed in changedRequests {
            t.check("Изменение snapshot запрещает запись", !session.matches(changed, occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: "ghbdtn"))
        }
        for candidate in [nil, try! NeuralLayoutProfile(modelSHA256: profile.modelSHA256, enabled: false, minimumScore: 0, minimumMargin: 0)] as [NeuralLayoutProfile?] {
            t.check("Профиль без допуска остаётся наблюдением", NeuralLayoutAssistance.policy(result: pending, mode: .assist,
                modelSHA256: profile.modelSHA256, profile: candidate, fresh: true, block: nil,
                word: "ghbdtn", ruleBlocked: false) == .observe)
        }
        t.check("Правило выше модели", NeuralLayoutAssistance.policy(result: pending, mode: .assist,
            modelSHA256: profile.modelSHA256, profile: profile, fresh: true, block: nil,
            word: "ghbdtn", ruleBlocked: true) == .blocked(.rule))
        session.changed()
        var writes = 0
        if case .propose = policy(fresh: session.matches(pending.request, occurrenceID: occurrence, bundleID: "app", layoutCode: "en", word: "ghbdtn")) { writes += 1 }
        t.check("Буква перед marker меняет revision и отменяет запись", writes == 0)
        for keyPath in [\NeuralLayoutLiveGuards.running, \.ready, \.focusAvailable, \.autoEnabled,
                        \.inlineEnabled, \.inlineHealthy, \.liveEnabled, \.warm, \.occurrenceAllowed] {
            var gates = NeuralLayoutLiveGuards()
            gates[keyPath: keyPath] = false
            t.check("Выключенный live guard запрещает запись", gates.block != nil)
        }
        for keyPath in [\NeuralLayoutLiveGuards.paused, \.secureInput, \.modifiers, \.muted,
                        \.markerInFlight, \.edited, \.contextPending, \.journalEditing,
                        \.developer, \.appBlocked, \.sameAsLast, \.undo] {
            var gates = NeuralLayoutLiveGuards()
            gates[keyPath: keyPath] = true
            t.check("Активный live guard запрещает запись", gates.block != nil)
        }
        t.check("Все live guards разрешены", NeuralLayoutLiveGuards().block == nil)
        var commits = 0
        var submissions: [Bool] = []
        let rejected = NeuralLayoutAssistance.submit({ writes += 1; return false }, submission: { submissions.append($0) }, committed: { commits += 1 })
        t.check("Rejected не меняет состояние", !rejected && commits == 0)
        let submitted = NeuralLayoutAssistance.submit({ writes += 1; return true }, submission: { submissions.append($0) }, committed: { commits += 1 })
        t.check("Submitted меняет состояние ровно один раз", submitted && commits == 1)
        t.check("Каждая actual submission записана ровно один раз", submissions == [false, true])
    }
}
