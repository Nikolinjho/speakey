import AppKit
import IOKit.ps

/// АВТОДОПОЛНЕНИЕ ПРИ НАБОРЕ (механика Cotypist, спека 2026-11-12).
///
/// Живёт в двух мирах. `handleKey` зовётся изнутри колбэка тапа на main и делает только O(1):
/// сравнить клавишу с видимой подсказкой, сдвинуть «поколение» и перевзвести таймер паузы.
/// Всё дорогое — AX, сокет помощника, проверка орфографии — идёт после паузы: снимок поля на
/// фоновой очереди, ответ модели на main. Ответ показывается, только если с момента запроса не было
/// ни одного нажатия и клика (поколение не сдвинулось), иначе он про устаревший текст.
///
/// В лог — только длины и счётчики (принцип №2).
final class AutocompleteController {
    static let shared = AutocompleteController()

    /// «Слово перед кареткой — триггер сниппета или кандидат на исправление раскладки»: тогда
    /// подсказку не показываем, и Tab при видимой подсказке всегда однозначен (решение спеки).
    var suppressForWord: ((String) -> Bool)? = { word in
        guard !word.isEmpty else { return false }
        if SnippetStore.shared.expansion(forTyped: word) != nil { return true }
        if case .convert = LayoutDetector.liveDecide(word: word) { return true }
        return false
    }

    private let queue = DispatchQueue(label: "dev.speakey.autocomplete", qos: .userInitiated)

    // Состояние — только на main.
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var ghost = ""
    private var ghostIsCorrection = false
    /// Для исправления опечатки: сколько символов стереть и чем заменить.
    private var correction: (deleteCount: Int, text: String)?
    private var caret = NSRect.zero
    /// Esc прячет подсказку до клика или смены приложения — как у Cotypist.
    private var suspended = false
    /// Для личного корпуса: последний виденный текст поля и был ли принят хоть один кусок.
    private var fieldText = ""
    private var fieldBundleID = ""
    private var acceptedInField = false
    private var shown = 0, accepted = 0

    private init() {}

    // MARK: - Вкл/выкл

    func setEnabled(_ on: Bool) {
        AutocompletePrefs.enabled = on
        if on, let model = currentModelURL() {
            CompletionEngine.shared.ensureRunning(model: model)
        } else {
            hide()
            CompletionEngine.shared.stop()
        }
        kbLog("autocomplete: \(on ? "включено" : "выключено")")
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
    func handleKey(keyCode: Int64, characters: String, flags: CGEventFlags) -> Bool {
        guard AutocompletePrefs.enabled else { return false }
        generation &+= 1
        let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let visible = !ghost.isEmpty

        if visible {
            if keyCode == 48 {
                if mods == [.maskAlternate] {
                    // ⌥Tab — обычный Tab, даже при видимой подсказке.
                    hide()
                    postPlainTab()
                    return true
                }
                if mods.isEmpty { acceptChunk(); return true }
            }
            if keyCode == 53 && mods.isEmpty {
                hide()
                suspended = true
                return true
            }
            if keyCode == Int64(AutocompletePrefs.acceptAllKeyCode) && mods.subtracting(.maskShift).isEmpty {
                acceptAll()
                return true
            }
            // Человек печатает то, что и так подсказано, — «съедаем» без нового запроса.
            if !ghostIsCorrection, mods.subtracting(.maskShift).isEmpty, isPrintable(characters),
               let rest = CompletionText.consume(ghost, typed: characters) {
                if rest.isEmpty {
                    hide()
                } else {
                    ghost = rest
                    caret.origin.x += textWidth(characters)
                    GhostSuggestionPanel.shared.show(rest, caret: caret, isCorrection: false)
                    scheduleRealign()
                    return false
                }
            } else {
                hide()
            }
        }
        if suspended { return false }
        // Шорткаты (⌘/⌃) — не набор: подсказку не зовём.
        if mods.contains(.maskCommand) || mods.contains(.maskControl) { return false }
        // Escape без подсказки и прочие служебные клавиши тоже не повод.
        if keyCode == 53 { return false }
        schedule()
        return false
    }

    /// Клик, смена приложения или поля: подсказка устарела, пауза Esc снимается.
    func contextReset() {
        generation &+= 1
        pending?.cancel(); pending = nil
        hide()
        suspended = false
        flushFieldToCorpus()
    }

    // MARK: - Пауза → запрос

    private func schedule() {
        pending?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in self?.request(gen: gen) }
        pending = item
        let ms = max(40, AutocompletePrefs.pauseMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
    }

    /// Подсказка «съедена» частично: после паузы подровнять её по настоящей каретке.
    private func scheduleRealign() {
        pending?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            self?.queue.async {
                let rect = CaretLocator.caretScreenRect(preferCharBefore: true)
                DispatchQueue.main.async {
                    guard let self, gen == self.generation, !self.ghost.isEmpty, let rect else { return }
                    self.caret = rect
                    GhostSuggestionPanel.shared.show(self.ghost, caret: rect, isCorrection: self.ghostIsCorrection)
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
            guard let self, self.lastSkip != reason else { return }
            self.lastSkip = reason
            kbLog("autocomplete: пропуск — \(reason)")
        }
        if Thread.isMainThread { log() } else { DispatchQueue.main.async(execute: log) }
    }

    private func request(gen: Int) {
        guard gen == generation else { return }
        guard AutocompletePrefs.enabled, !Pause.active,
              !VoiceController.shared.isBusyWithDictation,
              !SnippetPicker.shared.isOpen,
              !TextReplacer.secureInputActive else { skip("пауза/диктовка/секрет"); return }
        let started = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self else { return }
            guard let snap = ContextHub.snapshot() else { self.skip("нет снимка поля"); return }
            guard AutocompleteAppStore.shared.isEnabled(snap.bundleID),
                  !AutocompleteAppStore.hardExcluded.contains(snap.bundleID) else { self.skip("приложение выключено"); return }
            guard SecureInputPolicy.focusedFieldVerdict() == .ordinary else { self.skip("поле не обычное"); return }
            guard snap.caretRect.width < 400, snap.caretRect.height > 4 else { self.skip("нет каретки"); return }
            let before = snap.before
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.skip("пустое поле"); return }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.noteField(snap)
                if AutocompletePrefs.useScreen { ScreenContextProvider.shared.refreshIfNeeded(pid: snap.pid) }
                if AutocompletePrefs.typoFix, self.offerTypoFix(before: before, caret: snap.caretRect) { return }
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
        guard case .ready = engine.state else {
            skip("помощник не готов")
            engine.ensureRunning(model: model)
            return
        }
        let light = AutocompletePrefs.batteryLight && Self.onBattery
        let maxWords = light ? min(3, AutocompletePrefs.maxWords) : AutocompletePrefs.maxWords
        queue.async {
            let prompt = CompletionPrompt.build(ContextHub.context(for: snap))
            engine.complete(prompt: prompt, maxTokens: maxWords * 3 + 2) { [weak self] raw in
                guard let self, let raw, gen == self.generation else { self?.skip("ответ устарел"); return }
                let text = CompletionText.clean(raw, before: snap.before, maxWords: maxWords)
                guard !text.isEmpty else { self.skip("пустой ответ"); return }
                guard self.plausible(text, before: snap.before) else { self.skip("обрыв слова"); return }
                self.lastSkip = ""
                self.ghost = text
                self.ghostIsCorrection = false
                self.correction = nil
                self.caret = snap.caretRect
                GhostSuggestionPanel.shared.show(text, caret: snap.caretRect, isCorrection: false)
                self.shown += 1
                let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                if self.shown == 1 || self.shown % 50 == 0 {
                    kbLog("autocomplete: показано \(self.shown), принято \(self.accepted), задержка \(ms) мс, длина \(text.count)")
                }
            }
        }
    }

    /// Фильтр обрыва слова (спайк 12.11): base-модель на «добави» начинает НОВОЕ слово, а на «пото»
    /// дописывает мусор. Поэтому слово на стыке каретки сверяем со словарём системы: начатое слово
    /// должно быть законченным, если подсказка начинается с пробела, и склеиться в настоящее слово,
    /// если подсказка его продолжает. Вызывать на main (NSSpellChecker).
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
        let cyr = word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: cyr ? "ru" : "en",
                                                       wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    // MARK: - Опечатки

    /// Слово перед пробелом с ошибкой → «→ исправление» серым. true — подсказка показана.
    private func offerTypoFix(before: String, caret: NSRect) -> Bool {
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return false }
        let trimmed = String(before.dropLast())
        let word = CompletionText.lastWord(trimmed)
        guard word.count >= 3, word.allSatisfy({ $0.isLetter }) else { return false }
        // Раскладку и цифры чинят свои правила — у них приоритет.
        if suppressForWord?(word) == true { return false }
        let checker = NSSpellChecker.shared
        let cyr = word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        let lang = cyr ? "ru" : "en"
        let ns = word as NSString
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location != NSNotFound,
              let fix = checker.correction(forWordRange: NSRange(location: 0, length: ns.length), in: word,
                                           language: lang, inSpellDocumentWithTag: 0),
              fix != word, fix.lowercased() != word.lowercased() else { return false }
        ghost = fix
        ghostIsCorrection = true
        correction = (word.count + 1, fix + " ")
        self.caret = caret
        GhostSuggestionPanel.shared.show(fix, caret: caret, isCorrection: true)
        return true
    }

    // MARK: - Приём

    private func acceptChunk() {
        if ghostIsCorrection, let c = correction {
            hide()
            accepted += 1
            acceptedInField = true
            TextReplacer.replace(deleteCount: c.deleteCount, with: c.text)
            return
        }
        let (chunk, rest) = CompletionText.nextChunk(ghost)
        guard !chunk.isEmpty else { hide(); return }
        accepted += 1
        acceptedInField = true
        insert(chunk, rest: rest)
    }

    private func acceptAll() {
        if ghostIsCorrection { acceptChunk(); return }
        let all = ghost
        accepted += 1
        acceptedInField = true
        insert(all, rest: "")
    }

    private func insert(_ text: String, rest: String) {
        ghost = rest
        if rest.isEmpty {
            hide()
        } else {
            caret.origin.x += textWidth(text)
            GhostSuggestionPanel.shared.show(rest, caret: caret, isCorrection: false)
        }
        let gen = generation
        TextReplacer.insert(text) { [weak self] in
            // Вставка ушла — подровнять остаток по настоящей каретке.
            guard let self, gen == self.generation, !self.ghost.isEmpty else { return }
            self.scheduleRealign()
        }
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

    // MARK: - Служебное

    private func hide() {
        ghost = ""
        ghostIsCorrection = false
        correction = nil
        if GhostSuggestionPanel.shared.isVisible { GhostSuggestionPanel.shared.hide() }
    }

    private func isPrintable(_ s: String) -> Bool {
        guard let ch = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return false }
        return !CharacterSet.controlCharacters.contains(ch) && ch.value != 0x7F
            && !(0xF700...0xF8FF).contains(ch.value)   // функциональные клавиши AppKit
    }

    /// Ширина набранного шрифтом подсказки — чтобы панель ехала за кареткой без нового AX-чтения.
    private func textWidth(_ s: String) -> CGFloat {
        let size = min(28, max(11, (caret.height * 0.85).rounded()))
        return (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    private func noteField(_ snap: FieldSnapshot) {
        if snap.bundleID != fieldBundleID { flushFieldToCorpus() }
        fieldBundleID = snap.bundleID
        fieldText = snap.before
    }

    /// Уход из поля: текст сессии — в личный корпус, если человек это разрешил.
    private func flushFieldToCorpus() {
        defer { fieldText = ""; acceptedInField = false }
        let text = fieldText, bid = fieldBundleID
        guard !text.isEmpty, !bid.isEmpty, AutocompleteAppStore.shared.recordAllowed(bid) else { return }
        switch AutocompletePrefs.recordMode {
        case .off: return
        case .accepted: guard acceptedInField else { return }
        case .all: break
        }
        queue.async { PersonalCorpus.shared.add(text, bundleID: bid) }
    }
}
