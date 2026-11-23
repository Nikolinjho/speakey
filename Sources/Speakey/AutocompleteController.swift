import AppKit
import IOKit.ps

/// АВТОДОПОЛНЕНИЕ ПРИ НАБОРЕ (механика Cotypist, спека 2026-11-12).
///
/// Живёт в двух мирах. `handleKey` зовётся изнутри колбэка тапа на main и делает только O(1):
/// сравнить клавишу с видимой подсказкой, сдвинуть «поколение» и перевзвести таймер паузы.
/// Всё, что трогает WindowServer, AX, сокет помощника или словарь орфографии, идёт асинхронно:
/// перерисовка панели — следующим тиком main, снимок поля и орфография — на фоновой очереди.
/// Ответ показывается, только если с момента запроса не было ни одного нажатия и клика
/// (поколение не сдвинулось), иначе он про устаревший текст.
///
/// В лог — только длины, счётчики и коды причин (принцип №2).
final class AutocompleteController {
    static let shared = AutocompleteController()

    /// «Слово перед кареткой — триггер сниппета или кандидат на исправление раскладки»: тогда
    /// подсказку не показываем, и Tab при видимой подсказке всегда однозначен (решение спеки).
    /// Зовётся на main — так же, как эти проверки зовёт сам Engine.
    var suppressForWord: ((String) -> Bool)? = { word in
        guard !word.isEmpty else { return false }
        if SnippetStore.shared.expansion(forTyped: word) != nil { return true }
        if case .convert = LayoutDetector.liveDecide(word: word) { return true }
        return false
    }

    /// Снимки поля и орфография. Отдельно от записи корпуса, чтобы запись на диск не задерживала подсказку.
    private let queue = DispatchQueue(label: "dev.speakey.autocomplete", qos: .userInitiated)
    private let corpusQueue = PersonalCorpus.workQueue
    private let corpus: PersonalCorpus

    // Состояние — только на main.
    private var generation = 0
    /// Копия `generation` для фоновой очереди: устаревший снимок не стоит даже начинать.
    private let genLock = NSLock()
    private var genShadow = 0
    private var pending: DispatchWorkItem?
    private var ghost = ""
    private var ghostIsCorrection = false
    /// Для исправления опечатки: сколько символов стереть и чем заменить.
    private var correction: (deleteCount: Int, text: String)?
    private var caret = NSRect.zero
    private var fieldBounds: NSRect?
    private var suggestionFont: NSFont?
    private var sourceTarget: CompletionTarget?
    private var guardedTarget: CompletionTarget?
    private var midlineSuggestion = false
    private var midlineAnchor: NSRect?
    private var midlinePrefix = ""
    private var inlineBusy = false
    private var queuedAcceptance = AutocompleteAcceptanceQueue()
    private var alternativesPending: DispatchWorkItem?
    private var suppression = CompletionSuppression()
    private var currentApp = ""
    private var controlsObserver: NSObjectProtocol?
    private var recordingObserver: NSObjectProtocol?
    private var shortcuts = AutocompletePrefs.shortcuts
    private var escapeMode = AutocompletePrefs.escapeMode
    private var trailingSpace = AutocompletePrefs.trailingSpace
    private var trailingPunctuation = AutocompletePrefs.trailingPunctuation
    private var tabEnabled = AutocompletePrefs.tabEnabled
    /// Кэш главного выключателя: колбэк тапа не читает UserDefaults на каждое нажатие.
    private(set) var enabled = AutocompletePrefs.enabled
    /// Подсказка, которую никто не трогает, гаснет сама: окно могли прокрутить или сдвинуть.
    private var ttl: DispatchWorkItem?
    private var scrollMonitor: Any?
    /// Для личного корпуса: последний виденный текст поля и был ли принят хоть один кусок.
    private var fieldSession = AutocompleteRecordingSession<CompletionFieldIdentity>()
    private var recordingEpoch = 0
    private var shown = 0, accepted = 0

    init(corpus: PersonalCorpus = .shared) {
        self.corpus = corpus
        recordingObserver = NotificationCenter.default.addObserver(forName: AutocompletePrefs.recordingChanged,
                                                                  object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.recordingEpoch += 1
            self.fieldSession = AutocompleteRecordingSession()
            self.invalidate()
        }
        controlsObserver = NotificationCenter.default.addObserver(forName: AutocompletePrefs.controlsChanged,
                                                                  object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.shortcuts = AutocompletePrefs.shortcuts
            self.escapeMode = AutocompletePrefs.escapeMode
            self.trailingSpace = AutocompletePrefs.trailingSpace
            self.trailingPunctuation = AutocompletePrefs.trailingPunctuation
            self.tabEnabled = AutocompleteAppStore.shared.tabEnabled(self.currentApp, global: AutocompletePrefs.tabEnabled)
            self.invalidate()
        }
    }

    // MARK: - Вкл/выкл

    func setEnabled(_ on: Bool) {
        invalidate()
        AutocompletePrefs.enabled = on
        enabled = on
        if on {
            prepareCurrentApp()
            if let model = currentModelURL() { CompletionEngine.shared.ensureRunning(model: model) }
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
                    guard let self, !self.ghost.isEmpty else { return }
                    self.hide()
                }
            }
        } else {
            hide()
            CompletionEngine.shared.stop()
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
        kbLog("autocomplete: \(on ? "включено" : "выключено")")
    }

    /// Подготовка AX выполняется перед снимками поля на той же последовательной очереди.
    private func prepareCurrentApp() {
        guard enabled, let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier, AutocompleteAppStore.shared.isEnabled(bid),
              Engine.isElectronApp(app) else { return }
        let pid = app.processIdentifier
        queue.async {
            guard AutocompletePrefs.enabled else { return }
            AXFocusedElement.prepareElectron(pid: pid)
        }
    }

    private func currentModelURL() -> URL? {
        let id = effectiveModelID()
        guard let m = CompletionModels.all.first(where: { $0.id == id }) ?? CompletionModels.all.first,
              CompletionModels.isInstalled(m) else { return nil }
        return CompletionModels.localURL(m)
    }

    /// На батарее в режиме экономии берём лёгкую модель (первая в каталоге — лёгкая).
    private func effectiveModelID() -> String {
        if AutocompletePrefs.batteryLight, Self.onBattery,
           let light = CompletionModels.all.first(where: { $0.id == CompletionModels.defaultID }),
           CompletionModels.isInstalled(light) { return light.id }
        return AutocompletePrefs.modelID
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: - Горячий путь (колбэк тапа, main, O(1))

    /// true = клавишу проглотить.
    func handleKey(keyCode: Int64, characters: String, flags: CGEventFlags, app: String, isRepeat: Bool = false) -> Bool {
        currentApp = app
        let now = ProcessInfo.processInfo.systemUptime
        // Только сравнения с кэшем. Запись настроек и запуск помощника — следующим тиком.
        func decision(_ action: CompletionAction) -> CompletionShortcut.Decision {
            shortcuts[action]?.decision(action: action, keyCode: keyCode, modifiers: flags.rawValue,
                                        isRepeat: isRepeat, tabEnabled: tabEnabled) ?? .pass
        }
        if decision(.toggleGlobal) != .pass {
            guard decision(.toggleGlobal) == .perform else { return true }
            invalidate()
            DispatchQueue.main.async { self.setEnabled(!self.enabled) }
            return true
        }
        guard enabled, !AutocompleteAppStore.hardExcluded.contains(app) else { return false }
        let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if decision(.toggleApp) != .pass {
            guard decision(.toggleApp) == .perform else { return true }
            invalidate()
            suppression.toggle(app: app, now: now)
            return true
        }
        if decision(.manual) != .pass {
            guard decision(.manual) == .perform else { return true }
            invalidate()
            suppression.resume(app: app)
            schedule()
            return true
        }
        for action in [CompletionAction.alternatives, .synonyms] where decision(action) != .pass {
            guard decision(action) == .perform else { return true }
            let initial = !ghostIsCorrection && !ghost.isEmpty ? ghost : nil
            let target = sourceTarget
            invalidate()
            DispatchQueue.main.async {
                CompletionVariantsController.shared.request(action == .synonyms ? .synonyms : .alternatives,
                    model: self.currentModelURL(), target: action == .alternatives ? target : nil, initial: initial)
            }
            return true
        }
        if CompletionVariantsController.shared.handleKey(keyCode: keyCode, flags: flags, tabEnabled: tabEnabled) { return true }
        if inlineBusy {
            if decision(.nextWord) == .perform { queuedAcceptance.append(.nextWord); return true }
            if decision(.acceptAll) == .perform { queuedAcceptance.append(.all); return true }
            // Ручной ввод может опередить подтверждение синтетики. Старый остаток больше не свеж.
            hide()
        }
        bumpGeneration()
        if suppression.isSuppressed(app: app, now: now) { hide(); return false }

        if !ghost.isEmpty {
            if shortcuts[.nextWord] == CompletionShortcut(keyCode: 48, modifiers: 0), tabEnabled {
                if keyCode == 48, mods == [.maskAlternate] {
                    // ⌥Tab — обычный Tab, даже при видимой подсказке.
                    hide()
                    DispatchQueue.main.async { self.postPlainTab() }
                    return true
                }
            }
            if decision(.nextWord) == .perform {
                let guarded = guardedTarget != nil
                DispatchQueue.main.async { kbLog("autocomplete: приём клавишей, проверяемая цель=\(guarded)") }
                acceptChunk(); return true
            }
            if keyCode == 53 && mods.isEmpty {
                hide()
                suppression.dismiss(mode: escapeMode, app: app, now: now)
                return escapeMode != .passThrough
            }
            if decision(.acceptAll) == .perform {
                acceptAll()
                return true
            }
            // Человек печатает то, что и так подсказано, — «съедаем» без нового запроса.
            if (guardedTarget == nil || midlineSuggestion), !ghostIsCorrection, mods.subtracting(.maskShift).isEmpty, isPrintable(characters),
               let rest = CompletionText.consume(ghost, typed: characters), !rest.isEmpty {
                ghost = rest
                sourceTarget = sourceTarget?.expectingInsertion(characters)
                guardedTarget = guardedTarget?.expectingInsertion(characters)
                if midlineSuggestion { midlinePrefix += characters }
                let typed = characters
                DispatchQueue.main.async { self.advance(by: typed) }
                return false
            }
            hide()
        }
        // Шорткаты (⌘/⌃) и Escape без подсказки — не набор: подсказку не зовём.
        if mods.contains(.maskCommand) || mods.contains(.maskControl) || keyCode == 53 { return false }
        schedule()
        return false
    }

    /// Клик или смена поля: подсказка устарела, пауза Esc снимается. `appChanged` — сменилось
    /// приложение: тогда сессия поля закончена и уходит в корпус (на клике — нет, иначе дубли).
    func contextReset(appChanged: Bool = false) {
        bumpGeneration()
        pending?.cancel(); pending = nil
        hide()
        suppression.contextReset(appChanged: appChanged)
        if appChanged {
            currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            tabEnabled = AutocompleteAppStore.shared.tabEnabled(currentApp, global: AutocompletePrefs.tabEnabled)
        }
        if appChanged {
            prepareCurrentApp()
            flushFieldToCorpus()
        }
        if enabled, AutocompletePrefs.autoSynonyms { schedule(delayMs: AutocompletePrefs.variantsDelayMs) }
    }

    private func bumpGeneration() {
        queuedAcceptance.clear()
        generation &+= 1
        genLock.lock(); genShadow = generation; genLock.unlock()
    }

    private func invalidate() {
        bumpGeneration()
        pending?.cancel(); pending = nil
        hide()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return genShadow == gen
    }

    // MARK: - Пауза → запрос

    private func schedule(delayMs: Int? = nil) {
        pending?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in self?.request(gen: gen) }
        pending = item
        let ms = max(40, delayMs ?? AutocompletePrefs.pauseMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
    }

    /// Подсказка частично «съедена»: сразу сдвинуть панель на ширину набранного, а после паузы
    /// подровнять по настоящей каретке.
    private func advance(by typed: String) {
        guard !ghost.isEmpty else { return }
        if !midlineSuggestion { caret.origin.x += textWidth(typed) }
        present()
        scheduleRealign()
    }

    private func scheduleRealign() {
        pending?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard self?.isCurrent(gen) == true else { return }
                let element = AXFocusedElement.read(timeout: 0.25)
                let rect = element.flatMap { CaretLocator.caretScreenRect(preferCharBefore: true, element: $0) }
                let bounds = element.flatMap { CaretLocator.fieldScreenRect(element: $0) }
                DispatchQueue.main.async {
                    guard let self, gen == self.generation, !self.ghost.isEmpty, let rect else { return }
                    self.caret = rect
                    self.fieldBounds = bounds
                    self.present()
                }
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    /// Почему подсказки не было — в лог только код причины и только на его смену (без текста).
    private var lastSkip = ""
    private func skip(_ reason: String) {
        let log = { [weak self] in
            // Скрытый ключ для отладки: `defaults write dev.speakey.app.dev ac.debugSkips -bool true`
            // пишет каждую причину, а не только смену.
            guard let self, self.lastSkip != reason || UserDefaults.standard.bool(forKey: "ac.debugSkips") else { return }
            self.lastSkip = reason
            kbLog("autocomplete: пропуск — \(reason)")
        }
        if Thread.isMainThread { log() } else { DispatchQueue.main.async(execute: log) }
    }

    private func request(gen: Int) {
        guard gen == generation else { return }
        guard enabled, !suppression.isSuppressed(app: currentApp, now: ProcessInfo.processInfo.systemUptime), !Pause.active,
              !VoiceController.shared.isBusyWithDictation,
              !SnippetPicker.shared.isOpen,
              !TextReplacer.secureInputActive else { skip("пауза/диктовка/секрет"); return }
        let started = ProcessInfo.processInfo.systemUptime
        let typoFix = AutocompletePrefs.typoFix
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            guard let snap = ContextHub.snapshot() else { self.skip("нет снимка поля"); return }
            guard AutocompleteAppStore.shared.isEnabled(snap.bundleID),
                  !AutocompleteAppStore.hardExcluded.contains(snap.bundleID) else { self.skip("приложение выключено"); return }
            guard SecureInputPolicy.focusedFieldVerdict() == .ordinary else { self.skip("поле не обычное"); return }
            guard snap.caretRect.width < 400, snap.caretRect.height > 4 else { self.skip("нет каретки"); return }
            if let target = snap.target, !target.selected.isEmpty {
                if AutocompletePrefs.autoSynonyms, CompletionEditing.selectionEligible(target.selected) {
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        self.hide()
                        CompletionVariantsController.shared.request(.synonyms, model: self.currentModelURL(), target: target)
                    }
                }
                return
            }
            guard !snap.textAfterOnLine || (AutocompletePrefs.inlineCompletion && snap.target != nil) else { self.skip("текст справа от каретки"); return }
            if AutocompletePrefs.onlyCurrentWord, (CompletionText.lastWord(snap.before).isEmpty || snap.target == nil) { return }
            let before = snap.before
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.skip("пустое поле"); return }
            // Орфография — здесь, на фоновой очереди: NSSpellChecker грузит словари и не O(1).
            let typo = typoFix && !snap.textAfterOnLine ? self.typoCandidate(before: before) : nil
            let canRecord = AutocompleteAppStore.shared.shouldRecord(snap.bundleID, mode: AutocompletePrefs.recordMode,
                                                                     accepted: true, autocompleteEnabled: AutocompletePrefs.enabled)
            let fieldText = canRecord ? snap.target?.fieldIdentity.readText() : nil
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.noteField(snap, text: fieldText)
                self.sourceTarget = snap.target
                self.suggestionFont = snap.target?.textFont
                self.fieldBounds = snap.fieldBounds
                if AutocompletePrefs.useScreen { ScreenContextProvider.shared.refreshIfNeeded(pid: snap.pid) }
                if let typo, self.suppressForWord?(typo.word) != true {
                    self.showCorrection(typo.fix, word: typo.word, caret: snap.caretRect)
                    return
                }
                // Слово-триггер (сниппет, неверная раскладка) — Tab принадлежит им.
                if let last = before.last, !last.isWhitespace,
                   self.suppressForWord?(CompletionText.lastWord(before)) == true { self.skip("слово-триггер"); return }
                self.complete(snap: snap, gen: gen, started: started)
            }
        }
    }

    private func complete(snap: FieldSnapshot, gen: Int, started: TimeInterval) {
        guard let model = currentModelURL() else { skip("модель не установлена"); return }
        let engine = CompletionEngine.shared
        engine.noteUse()
        // Сменилась нужная модель (батарея, выбор в настройках) — перезапуск помощника.
        if engine.currentModel != nil, engine.currentModel != model { engine.ensureRunning(model: model) }
        guard case .ready = engine.state else {
            skip("помощник не готов")
            engine.ensureRunning(model: model)
            return
        }
        let light = AutocompletePrefs.batteryLight && Self.onBattery
        let maxWords = light ? min(3, AutocompletePrefs.maxWords) : AutocompletePrefs.maxWords
        // Хвостовой пробел в промпт не отдаём: у токенизатора слова начинаются с пробела, и base-модель
        // после «голого» пробела теряется — отвечает пустотой или переводом строки (Safari, 12.11).
        // Отрезаем его и ждём ответ, начинающийся новым словом; сам пробел человек уже напечатал.
        let endsSpace = snap.before.hasSuffix(" ") && !snap.before.hasSuffix("  ")
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            var ctx = ContextHub.context(for: snap, corpus: self.corpus)
            if endsSpace { ctx.before = String(ctx.before.dropLast()) }
            let prompt = snap.textAfterOnLine && !AutocompletePrefs.onlyCurrentWord
                ? CompletionEditing.insertionPrompt(before: snap.before, after: snap.target?.after ?? "")
                : CompletionPrompt.build(ctx)
            engine.complete(prompt: prompt, maxTokens: maxWords * 3 + 2, temperature: CompletionPrompt.continuationTemperature) { [weak self] reply in
                guard let self, var raw = reply, gen == self.generation else { self?.skip("ответ устарел"); return }
                if endsSpace && !snap.textAfterOnLine {
                    guard raw.first == " " else { self.skip("ответ продолжает слово после пробела"); return }
                    raw.removeFirst()
                }
                var text = snap.textAfterOnLine
                    ? CompletionEditing.insertion(raw, before: snap.before, after: snap.target?.after ?? "", continuingWord: AutocompletePrefs.onlyCurrentWord)
                    : CompletionPrompt.cleanContinuation(raw, before: snap.before, context: ctx, maxWords: maxWords)
                if AutocompletePrefs.onlyCurrentWord { text = CompletionEditing.currentWord(text, before: snap.before) }
                guard !text.isEmpty else { self.skip("пустой ответ"); return }
                // Проверка стыка слова — тоже орфография, тоже не на main.
                self.queue.async {
                    let fresh = snap.target.map { target in CompletionTarget.capture().map { target.matches($0) } ?? false } ?? true
                    let ok = fresh && self.plausible(text, before: snap.before)
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        guard ok else { self.skip("обрыв слова"); return }
                        self.lastSkip = ""
                        self.sourceTarget = snap.target
                        self.suggestionFont = snap.target?.textFont
                        self.fieldBounds = snap.fieldBounds
                        self.guardedTarget = (snap.textAfterOnLine || AutocompletePrefs.onlyCurrentWord) ? snap.target : nil
                        self.midlineSuggestion = snap.textAfterOnLine
                        self.midlineAnchor = snap.textAfterOnLine ? snap.caretRect : nil
                        self.midlinePrefix = ""
                        self.ghost = text
                        self.ghostIsCorrection = false
                        self.correction = nil
                        self.caret = snap.caretRect
                        self.present()
                        if AutocompletePrefs.autoAlternatives, let target = snap.target {
                            self.alternativesPending?.cancel()
                            let item = DispatchWorkItem {
                                guard gen == self.generation, !self.ghost.isEmpty else { return }
                                let initial = self.ghost
                                self.hide()
                                CompletionVariantsController.shared.request(.alternatives, model: self.currentModelURL(), target: target, initial: initial)
                            }
                            self.alternativesPending = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(AutocompletePrefs.variantsDelayMs), execute: item)
                        }
                        self.shown += 1
                        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                        if self.shown == 1 || self.shown % 50 == 0 {
                            kbLog("autocomplete: показано \(self.shown), принято \(self.accepted), задержка \(ms) мс, длина \(text.count)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Орфография (только на `queue`)

    /// Фильтр обрыва слова (спайк 12.11): base-модель на «добави» начинает НОВОЕ слово, а на «пото»
    /// дописывает мусор. Поэтому слово на стыке каретки сверяем со словарём системы: начатое слово
    /// должно быть законченным, если подсказка начинается с пробела, и склеиться в настоящее слово,
    /// если подсказка его продолжает.
    private func plausible(_ text: String, before: String) -> Bool {
        guard let last = before.last, last.isLetter else { return true }
        let word = CompletionText.lastWord(before)
        guard !word.isEmpty else { return true }
        if let first = text.first, first.isWhitespace || first.isPunctuation {
            return isKnownWord(word)
        }
        let joined = word + CompletionText.nextChunk(text).chunk
            .trimmingCharacters(in: .punctuationCharacters)
        return isKnownWord(joined)
    }

    private func isKnownWord(_ word: String) -> Bool {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter }) else { return true }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language(of: word),
                                                       wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    private func language(of word: String) -> String {
        word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } ? "ru" : "en"
    }

    /// Опечатка в слове перед пробелом — только при высокой уверенности (ревью 12.11: Tab, нажатый
    /// ради отступа после «kubectl », не должен молча менять слово). Берём лишь строчные слова из букв,
    /// не выученные системой и не из личных терминов, с единственным кандидатом на расстоянии 1.
    private func typoCandidate(before: String) -> (word: String, fix: String)? {
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return nil }
        let word = CompletionText.lastWord(String(before.dropLast()))
        guard word.count >= 4, word.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return nil }
        let checker = NSSpellChecker.shared
        let lang = language(of: word)
        if checker.hasLearnedWord(word) { return nil }
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location != NSNotFound else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: 0) ?? []
        let close = guesses.filter { $0.lowercased() != word && Self.editDistance($0.lowercased(), word) == 1 }
        guard close.count == 1, let fix = close.first else { return nil }
        if corpus.topTerms(limit: 200).contains(where: { $0.lowercased() == word }) { return nil }
        return (word, fix)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private func showCorrection(_ fix: String, word: String, caret: NSRect) {
        ghost = fix
        ghostIsCorrection = true
        correction = (word.count + 1, fix + " ")
        self.caret = caret
        present()
    }

    // MARK: - Приём

    private func acceptChunk() {
        if ghostIsCorrection, let c = correction {
            let target = sourceTarget
            let epoch = recordingEpoch
            let revision = AutocompletePrefs.recordingRevision
            hide()
            inlineBusy = true
            let gen = generation
            queue.async {
                guard self.isCurrent(gen) else {
                    DispatchQueue.main.async { self.finishInsertion() }; return
                }
                // Проверка выполняется до синтетики, вне колбэка тапа.
                if let target {
                    guard let current = CompletionTarget.capture(), target.matches(current) else {
                        DispatchQueue.main.async { self.finishInsertion() }; return
                    }
                }
                DispatchQueue.main.async {
                    guard gen == self.generation else { self.finishInsertion(); return }
                    TextReplacer.replace(deleteCount: c.deleteCount, with: c.text, onSubmission: { submitted in
                        guard submitted, let target else { self.finishInsertion(); return }
                        self.verifyRecordedInsertion(target, text: c.text, deletingBefore: c.deleteCount,
                                                     gen: gen, epoch: epoch, revision: revision)
                    })
                }
            }
            return
        }
        var (chunk, rest) = CompletionText.acceptedChunk(ghost, trailingSpace: trailingSpace && !AutocompletePrefs.onlyCurrentWord && guardedTarget == nil, punctuation: trailingPunctuation)
        if guardedTarget != nil, rest.allSatisfy({ $0.isWhitespace }) { chunk += rest; rest = "" }
        guard !chunk.isEmpty else { hide(); return }
        insert(chunk, rest: rest)
    }

    private func acceptAll() {
        if ghostIsCorrection { acceptChunk(); return }
        insert(ghost, rest: "")
    }

    private func insert(_ text: String, rest: String) {
        guard !text.isEmpty else { hide(); return }
        let epoch = recordingEpoch
        let revision = AutocompletePrefs.recordingRevision
        if let target = guardedTarget {
            let gen = generation
            inlineBusy = true
            queue.async {
                guard self.isCurrent(gen), AutocompletePrefs.enabled else {
                    DispatchQueue.main.async { self.finishInsertion() }; return
                }
                let ok = target.commit(text)
                let candidate = ok ? CompletionTarget.capture() : nil
                let updated = candidate.flatMap { target.verifies(text, updated: $0) ? $0 : nil }
                let bounds = updated.flatMap { CaretLocator.fieldScreenRect(element: $0.element) }
                let finalText = updated.flatMap { self.recordingText(for: $0.fieldIdentity, bundleID: target.bundleID, revision: revision) }
                DispatchQueue.main.async {
                    defer { self.finishInsertion() }
                    guard gen == self.generation else { return }
                    guard ok, let updated else { self.hide(); return }
                    self.accepted += 1
                    self.confirmRecordedInsertion(target.fieldIdentity, text: finalText, epoch: epoch, revision: revision)
                    if self.midlineSuggestion { self.midlinePrefix += text }
                    self.ghost = updated.selected.isEmpty ? rest : ""; self.guardedTarget = updated; self.sourceTarget = updated; self.caret = updated.caret
                    self.fieldBounds = bounds
                    if self.ghost.isEmpty { self.hide() } else { self.present() }
                }
            }
            return
        }
        let target = sourceTarget
        inlineBusy = true
        ghost = rest
        if rest.isEmpty { hide() }
        let gen = generation
        queue.async {
            guard self.isCurrent(gen) else {
                DispatchQueue.main.async { self.finishInsertion() }; return
            }
            if let target {
                guard let current = CompletionTarget.capture(), target.matches(current) else {
                    DispatchQueue.main.async { if gen == self.generation { self.hide() }; self.finishInsertion() }; return
                }
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { self.finishInsertion(); return }
                if !rest.isEmpty {
                    self.caret.origin.x += self.textWidth(text)
                    self.present()
                }
                TextReplacer.insert(text) { [weak self] in
                    guard let self else { return }
                    guard gen == self.generation else { self.finishInsertion(); return }
                    // completion не гарантирует запись: принятие подтверждает только чтение результата.
                    if let target {
                        self.verifyRecordedInsertion(target, text: text, gen: gen, epoch: epoch, revision: revision)
                    } else { self.finishInsertion() }
                    if !self.ghost.isEmpty { self.scheduleRealign() }
                }
            }
        }
    }

    /// Синтетические события могут быть ещё в очереди приложения. Ждём ограниченно и проверяем
    /// обе стороны каретки и идентичность поля, а не сам факт вызова транспорта.
    private func verifyRecordedInsertion(_ target: CompletionTarget, text: String, deletingBefore: Int = 0,
                                         gen: Int, epoch: Int, revision: UInt64) {
        queue.async {
            // Пока вставка не подтверждена, повторный Tab не меняет поколение и цель.
            defer { DispatchQueue.main.async { self.finishInsertion() } }
            let deadline = Date().addingTimeInterval(0.35)
            repeat {
                guard self.isCurrent(gen) else { return }
                if let updated = CompletionTarget.capture(), target.verifies(text, updated: updated, deletingBefore: deletingBefore) {
                    let finalText = self.recordingText(for: updated.fieldIdentity, bundleID: target.bundleID, revision: revision)
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        self.accepted += 1
                        self.sourceTarget = updated
                        self.confirmRecordedInsertion(target.fieldIdentity, text: finalText, epoch: epoch, revision: revision)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            DispatchQueue.main.async { if gen == self.generation { self.hide() } }
        }
    }

    /// Подтверждённая вставка обновила цель до запуска следующего ожидающего нажатия.
    private func finishInsertion() {
        inlineBusy = false
        guard !ghost.isEmpty, let intent = queuedAcceptance.take() else {
            queuedAcceptance.clear(); return
        }
        switch intent {
        case .nextWord: acceptChunk()
        case .all: acceptAll()
        }
    }

    private func recordingText(for field: CompletionFieldIdentity, bundleID: String, revision: UInt64) -> String? {
        guard revision == AutocompletePrefs.recordingRevision,
              AutocompleteAppStore.shared.shouldRecord(bundleID, mode: AutocompletePrefs.recordMode, accepted: true,
                                                       autocompleteEnabled: AutocompletePrefs.enabled) else { return nil }
        return field.readText()
    }

    private func confirmRecordedInsertion(_ field: CompletionFieldIdentity, text: String?, epoch: Int, revision: UInt64) {
        guard epoch == recordingEpoch, revision == AutocompletePrefs.recordingRevision else { return }
        fieldSession.confirmInsertion(field: field, text: text)
    }

    /// ⌥Tab: подсказку прячем, а в приложение уходит обычный Tab без модификаторов.
    private func postPlainTab() {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 48, keyDown: down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Показ

    /// Нарисовать текущую подсказку и завести TTL. Вызывать вне колбэка тапа.
    private func present() {
        guard !ghost.isEmpty else { return }
        GhostSuggestionPanel.shared.show(ghost, caret: midlineAnchor ?? caret, isCorrection: ghostIsCorrection,
                                         belowLine: midlineSuggestion, typedPrefix: midlinePrefix, textFont: suggestionFont,
                                         fieldBounds: fieldBounds)
        ttl?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.hide()
        }
        ttl = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    /// Состояние — сразу; само окно прячем следующим тиком, чтобы не звать WindowServer из колбэка тапа.
    private func hide() {
        queuedAcceptance.clear()
        alternativesPending?.cancel(); alternativesPending = nil
        CompletionVariantsController.shared.cancel()
        sourceTarget = nil; guardedTarget = nil; midlineSuggestion = false
        midlineAnchor = nil; midlinePrefix = ""
        suggestionFont = nil
        fieldBounds = nil
        ghost = ""
        ghostIsCorrection = false
        correction = nil
        ttl?.cancel(); ttl = nil
        DispatchQueue.main.async {
            guard self.ghost.isEmpty, GhostSuggestionPanel.shared.isVisible else { return }
            GhostSuggestionPanel.shared.hide()
        }
    }

    private func isPrintable(_ s: String) -> Bool {
        guard let ch = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return false }
        return !CharacterSet.controlCharacters.contains(ch) && ch.value != 0x7F
            && !(0xF700...0xF8FF).contains(ch.value)   // функциональные клавиши AppKit
    }

    /// Ширина набранного шрифтом подсказки — чтобы панель ехала за кареткой без нового AX-чтения.
    private func textWidth(_ s: String) -> CGFloat {
        let size = min(28, max(11, (caret.height * 0.85).rounded()))
        return (s as NSString).size(withAttributes: [.font: suggestionFont ?? NSFont.systemFont(ofSize: size)]).width
    }

    // MARK: - Личный корпус

    private func noteField(_ snap: FieldSnapshot, text: String?) {
        guard AutocompleteAppStore.shared.shouldRecord(snap.bundleID, mode: AutocompletePrefs.recordMode, accepted: true,
                                                       autocompleteEnabled: AutocompletePrefs.enabled) else {
            flushFieldToCorpus(); return
        }
        let field = snap.target?.fieldIdentity
        if fieldSession.field != field { flushFieldToCorpus() }
        enqueueField(fieldSession.note(field: field, bundleID: snap.bundleID, text: text))
    }

    /// Завершаем сессию сразу, но перечитываем именно прежнее поле на фоновой очереди.
    private func flushFieldToCorpus() {
        let pendingSession = fieldSession
        fieldSession = AutocompleteRecordingSession()
        recordingEpoch += 1
        guard let field = pendingSession.field else { return }
        let revision = AutocompletePrefs.recordingRevision
        queue.async {
            guard revision == AutocompletePrefs.recordingRevision,
                  AutocompleteAppStore.shared.shouldRecord(pendingSession.bundleID, mode: AutocompletePrefs.recordMode,
                                                           accepted: pendingSession.accepted,
                                                           autocompleteEnabled: AutocompletePrefs.enabled) else { return }
            // Недоступное или удалённое поле пропускается: старый снимок мог содержать опечатку.
            var completedSession = pendingSession
            let completed = completedSession.finish(finalText: field.readText() ?? "")
            DispatchQueue.main.async {
                guard revision == AutocompletePrefs.recordingRevision else { return }
                self.enqueueField(completed, revision: revision)
            }
        }
    }

    private func enqueueField(_ completed: AutocompleteRecordingSession<CompletionFieldIdentity>.Completed?, revision suppliedRevision: UInt64? = nil) {
        guard let completed else { return }
        let text = completed.text, bid = completed.bundleID, accepted = completed.accepted
        let revision = suppliedRevision ?? AutocompletePrefs.recordingRevision
        guard revision == AutocompletePrefs.recordingRevision, !text.isEmpty, !bid.isEmpty,
              AutocompleteAppStore.shared.shouldRecord(bid, mode: AutocompletePrefs.recordMode, accepted: accepted,
                                                       autocompleteEnabled: AutocompletePrefs.enabled) else { return }
        corpusQueue.async {
            guard revision == AutocompletePrefs.recordingRevision,
                  AutocompleteAppStore.shared.shouldRecord(bid, mode: AutocompletePrefs.recordMode, accepted: accepted,
                                                           autocompleteEnabled: AutocompletePrefs.enabled) else { return }
            self.corpus.add(text, bundleID: bid)
        }
    }
}
