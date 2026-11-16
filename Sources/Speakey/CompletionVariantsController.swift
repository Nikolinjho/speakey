import AppKit

/// Альтернативы и синонимы: локальная генерация и принятие по снимку поля.
final class CompletionVariantsController {
    static let shared = CompletionVariantsController()
    enum Kind: Equatable { case alternatives, synonyms }
    private let queue = DispatchQueue(label: "dev.speakey.completion.variants", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var choices: [String] = []
    private var selected = 0
    private var target: CompletionTarget?
    private var kind: Kind = .alternatives
    private var freshness: Timer?
    private var freshnessPending = false
    private var pendingRequest = false

    func cancel() {
        lock.lock(); generation &+= 1; lock.unlock()
        choices = []; target = nil; selected = 0
        pendingRequest = false
        freshness?.invalidate(); freshness = nil
        DispatchQueue.main.async { if self.choices.isEmpty { CompletionChoicePanel.shared.hide() } }
    }
    private func current(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
    private var token: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// В колбэке тапа — только решение по уже видимому списку и постановка работы в очередь.
    func handleKey(keyCode: Int64, flags: CGEventFlags, tabEnabled: Bool) -> Bool {
        guard !choices.isEmpty else {
            if pendingRequest { cancel() }
            return false
        }
        if keyCode == 48 && !tabEnabled { cancel(); return false }
        let decision = CompletionEditing.choiceKey(keyCode: keyCode, modifiers: flags.rawValue, count: choices.count, selected: selected)
        switch decision {
        case .pass: cancel(); return false
        case .dismiss: cancel(); return true
        case .select(let index):
            selected = index
            DispatchQueue.main.async { self.present() }
            return true
        case .accept(let index):
            guard let target, choices.indices.contains(index) else { cancel(); return true }
            let text = choices[index]
            cancel()
            let gen = token
            queue.async {
                guard self.current(gen), AutocompletePrefs.enabled else { return }
                let ok = target.commit(text)
                if !ok { kbLog("completion variants: принятие отклонено") }
            }
            return true
        }
    }

    func request(_ kind: Kind, model: URL?, target supplied: CompletionTarget? = nil, initial: String? = nil) {
        cancel()
        guard AutocompletePrefs.enabled, !Pause.active, !VoiceController.shared.isBusyWithDictation,
              !SnippetPicker.shared.isOpen, !TextReplacer.secureInputActive, let model else { return }
        pendingRequest = true
        let gen = token
        queue.async { [weak self] in
            guard let self, self.current(gen), let target = CompletionTarget.capture(),
                  AutocompleteAppStore.shared.isEnabled(target.bundleID),
                  (kind == .synonyms ? CompletionEditing.selectionEligible(target.selected) : target.selected.isEmpty),
                  kind == .synonyms || AutocompletePrefs.inlineCompletion || !CompletionEditing.hasTextOnCurrentLine(after: target.after) else { return }
            DispatchQueue.main.async {
                guard self.current(gen) else { return }
                self.kind = kind; self.target = target
                CompletionEngine.shared.ensureRunning(model: model)
                let initial = supplied.map { $0.matches(target) } == true ? initial : nil
                self.generateWhenReady(kind, target: target, initial: initial, gen: gen, deadline: Date().addingTimeInterval(8))
            }
        }
    }
    private func generateWhenReady(_ kind: Kind, target: CompletionTarget, initial: String?, gen: Int, deadline: Date) {
        guard current(gen), Date() < deadline else { return }
        guard CompletionEngine.shared.state == .ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.generateWhenReady(kind, target: target, initial: initial, gen: gen, deadline: deadline)
            }
            return
        }
        CompletionEngine.shared.noteUse()
        if kind == .synonyms {
            let prompt = CompletionEditing.synonymPrompt(before: target.before, selected: target.selected, after: target.after)
            CompletionEngine.shared.complete(prompt: prompt, maxTokens: 60, temperature: 0.35) { [weak self] raw in
                guard let self, self.current(gen) else { return }
                self.publish(CompletionEditing.synonyms(raw ?? "", original: target.selected), target: target, gen: gen)
            }
        } else {
            var values = initial.map { [$0] } ?? []
            func next(_ attempt: Int) {
                guard self.current(gen) else { return }
                if attempt >= 7 || CompletionEditing.alternatives(values).count >= 5 {
                    let inline = CompletionEditing.hasTextOnCurrentLine(after: target.after)
                    let choices = inline ? CompletionEditing.insertionAlternatives(values, before: target.before, after: target.after, continuingWord: AutocompletePrefs.onlyCurrentWord) : CompletionEditing.alternatives(values)
                    self.publish(choices, target: target, gen: gen); return
                }
                let inline = CompletionEditing.hasTextOnCurrentLine(after: target.after)
                let endsSpace = target.before.hasSuffix(" ")
                let prompt = inline && !AutocompletePrefs.onlyCurrentWord
                    ? CompletionEditing.insertionPrompt(before: target.before, after: target.after)
                    : CompletionPrompt.build(CompletionContext(appName: target.appName, before: endsSpace ? String(target.before.dropLast()) : target.before))
                CompletionEngine.shared.complete(prompt: prompt, maxTokens: 12, temperature: 0.95, seed: 170 + attempt * 19) { raw in
                    guard self.current(gen) else { return }
                    var text = raw ?? ""
                    if inline {
                        text = CompletionEditing.insertion(text, before: target.before, after: target.after, continuingWord: AutocompletePrefs.onlyCurrentWord)
                    } else {
                        if endsSpace {
                            if text.first == " " { text.removeFirst() } else { next(attempt + 1); return }
                        }
                        text = CompletionText.clean(text, before: target.before, maxWords: 1)
                    }
                    if AutocompletePrefs.onlyCurrentWord { text = CompletionEditing.currentWord(text, before: target.before) }
                    if !text.isEmpty { values.append(text) }
                    next(attempt + 1)
                }
            }
            next(0)
        }
    }
    private func publish(_ values: [String], target: CompletionTarget, gen: Int) {
        queue.async {
            guard self.current(gen), let now = CompletionTarget.capture(), target.matches(now) else { return }
            DispatchQueue.main.async {
                guard self.current(gen) else { return }
                self.choices = values; self.selected = 0
                if values.isEmpty {
                    CompletionChoicePanel.shared.show([L10n.autocomplete("choiceEmpty")], selected: -1, caret: target.caret,
                                                       title: L10n.autocomplete("choiceTitle"))
                } else { self.present() }
                self.freshness?.invalidate()
                self.freshness = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkFreshness(gen: gen) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.current(gen) { self.cancel() } }
            }
        }
    }
    private func present() {
        guard let target, !choices.isEmpty else { return }
        let display = choices.map { choice in
            kind == .alternatives && target.before.last.map(CompletionEditing.isWord) == true
                && choice.first.map(CompletionEditing.isWord) == true ? CompletionText.lastWord(target.before) + choice : choice
        }
        CompletionChoicePanel.shared.show(display, selected: selected, caret: target.caret,
                                         title: L10n.autocomplete(kind == .synonyms ? "synonymsTitle" : "alternativesTitle"))
    }
    private func checkFreshness(gen: Int) {
        guard !freshnessPending, let target else { return }
        freshnessPending = true
        queue.async {
            let valid = CompletionTarget.capture().map { target.matches($0) } ?? false
            DispatchQueue.main.async {
                self.freshnessPending = false
                if self.current(gen), !valid { self.cancel() }
            }
        }
    }
}
