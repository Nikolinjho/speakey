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
    private let corpusQueue = DispatchQueue(label: "dev.speakey.autocomplete.corpus", qos: .utility)

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
    /// Esc прячет подсказку в этом поле — до клика, смены приложения или Return, как у Cotypist.
    private var suspended = false
    /// Кэш главного выключателя: колбэк тапа не читает UserDefaults на каждое нажатие.
    private(set) var enabled = AutocompletePrefs.enabled
    /// Подсказка, которую никто не трогает, гаснет сама: окно могли прокрутить или сдвинуть.
    private var ttl: DispatchWorkItem?
    private var scrollMonitor: Any?
    /// Для личного корпуса: последний виденный текст поля и был ли принят хоть один кусок.
    private var fieldText = ""
    private var fieldBundleID = ""
    private var acceptedInField = false
    private var shown = 0, accepted = 0

    private init() {}

    // MARK: - Вкл/выкл

    func setEnabled(_ on: Bool) {
        AutocompletePrefs.enabled = on
        enabled = on
        if on {
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
        guard enabled else { return false }
        bumpGeneration()
        let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if !ghost.isEmpty {
            if keyCode == 48 {
                if mods == [.maskAlternate] {
                    // ⌥Tab — обычный Tab, даже при видимой подсказке.
                    hide()
                    DispatchQueue.main.async { self.postPlainTab() }
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
               let rest = CompletionText.consume(ghost, typed: characters), !rest.isEmpty {
                ghost = rest
                let typed = characters
                DispatchQueue.main.async { self.advance(by: typed) }
                return false
            }
            hide()
        }
        if keyCode == 36 { suspended = false }   // Return — новая строка, пауза Esc снимается
        if suspended { return false }
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
        suspended = false
        if appChanged { flushFieldToCorpus() }
    }

    private func bumpGeneration() {
        generation &+= 1
        genLock.lock(); genShadow = generation; genLock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return genShadow == gen
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

    /// Подсказка частично «съедена»: сразу сдвинуть панель на ширину набранного, а после паузы
    /// подровнять по настоящей каретке.
    private func advance(by typed: String) {
        guard !ghost.isEmpty else { return }
        caret.origin.x += textWidth(typed)
        present()
        scheduleRealign()
    }

    private func scheduleRealign() {
        pending?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard self?.isCurrent(gen) == true else { return }
                let rect = CaretLocator.caretScreenRect(preferCharBefore: true)
                DispatchQueue.main.async {
                    guard let self, gen == self.generation, !self.ghost.isEmpty, let rect else { return }
                    self.caret = rect
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
        guard enabled, !Pause.active,
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
            guard !snap.textAfterOnLine else { self.skip("текст справа от каретки"); return }
            let before = snap.before
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.skip("пустое поле"); return }
            // Орфография — здесь, на фоновой очереди: NSSpellChecker грузит словари и не O(1).
            let typo = typoFix ? self.typoCandidate(before: before) : nil
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.noteField(snap)
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
            var ctx = ContextHub.context(for: snap)
            if endsSpace { ctx.before = String(ctx.before.dropLast()) }
            let prompt = CompletionPrompt.build(ctx)
            engine.complete(prompt: prompt, maxTokens: maxWords * 3 + 2) { [weak self] reply in
                guard let self, var raw = reply, gen == self.generation else { self?.skip("ответ устарел"); return }
                if endsSpace {
                    guard raw.first == " " else { self.skip("ответ продолжает слово после пробела"); return }
                    raw.removeFirst()
                }
                let text = CompletionText.clean(raw, before: snap.before, maxWords: maxWords)
                guard !text.isEmpty else { self.skip("пустой ответ"); return }
                // Проверка стыка слова — тоже орфография, тоже не на main.
                self.queue.async {
                    let ok = self.plausible(text, before: snap.before)
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        guard ok else { self.skip("обрыв слова"); return }
                        self.lastSkip = ""
                        self.ghost = text
                        self.ghostIsCorrection = false
                        self.correction = nil
                        self.caret = snap.caretRect
                        self.present()
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
        if PersonalCorpus.shared.topTerms(limit: 200).contains(where: { $0.lowercased() == word }) { return nil }
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
            hide()
            accepted += 1
            acceptedInField = true
            DispatchQueue.main.async { TextReplacer.replace(deleteCount: c.deleteCount, with: c.text) }
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
        if rest.isEmpty { hide() }
        let gen = generation
        DispatchQueue.main.async {
            if !rest.isEmpty {
                self.caret.origin.x += self.textWidth(text)
                self.present()
            }
            TextReplacer.insert(text) { [weak self] in
                // Вставка ушла — подровнять остаток по настоящей каретке.
                guard let self, gen == self.generation, !self.ghost.isEmpty else { return }
                self.scheduleRealign()
            }
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

    // MARK: - Показ

    /// Нарисовать текущую подсказку и завести TTL. Вызывать вне колбэка тапа.
    private func present() {
        guard !ghost.isEmpty else { return }
        GhostSuggestionPanel.shared.show(ghost, caret: caret, isCorrection: ghostIsCorrection)
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
        return (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    // MARK: - Личный корпус

    private func noteField(_ snap: FieldSnapshot) {
        if snap.bundleID != fieldBundleID { flushFieldToCorpus() }
        fieldBundleID = snap.bundleID
        fieldText = snap.before
    }

    /// Уход из приложения: текст сессии — в личный корпус, если человек это разрешил.
    private func flushFieldToCorpus() {
        defer { fieldText = ""; acceptedInField = false }
        let text = fieldText, bid = fieldBundleID
        guard !text.isEmpty, !bid.isEmpty, AutocompleteAppStore.shared.recordAllowed(bid) else { return }
        switch AutocompletePrefs.recordMode {
        case .off: return
        case .accepted: guard acceptedInField else { return }
        case .all: break
        }
        corpusQueue.async { PersonalCorpus.shared.add(text, bundleID: bid) }
    }
}
