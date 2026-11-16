import Foundation

var checks = 0
var failures = 0
func expect(_ yes: Bool, _ name: String) {
    checks += 1
    if !yes { failures += 1; print("FAIL: \(name)") }
}

// Независимые правила пробела и пунктуации, без потери остатка.
expect(CompletionText.acceptedChunk("слово, потом", trailingSpace: false, punctuation: true) == ("слово,", " потом"), "прежнее принятие")
expect(CompletionText.acceptedChunk("слово, потом", trailingSpace: true, punctuation: true) == ("слово, ", "потом"), "пробел не дублируется")
expect(CompletionText.acceptedChunk("слово, потом", trailingSpace: true, punctuation: false) == ("слово", ", потом"), "пробел не ставится перед оставленной запятой")
expect(CompletionText.acceptedChunk(", потом", trailingSpace: true, punctuation: false) == (", ", "потом"), "оставленная пунктуация принимается следующим нажатием")
expect(CompletionText.acceptedChunk("it's time", trailingSpace: false, punctuation: false) == ("it's", " time"), "внутренний апостроф сохраняется")
expect(CompletionText.acceptedChunk("что-то! дальше", trailingSpace: false, punctuation: false) == ("что-то", "! дальше"), "внутренний дефис сохраняется")
expect(CompletionText.acceptedChunk("你好！ 后面", trailingSpace: false, punctuation: false) == ("你好", "！ 后面"), "пунктуация Unicode")
expect(CompletionText.acceptedChunk("👨‍👩‍👧", trailingSpace: true, punctuation: true) == ("👨‍👩‍👧 ", ""), "семейный эмодзи цел")
expect(CompletionText.acceptedChunk("", trailingSpace: true, punctuation: true) == ("", ""), "пустая подсказка")
expect(CompletionText.acceptedChunk("слово  потом", trailingSpace: true, punctuation: true) == ("слово ", " потом"), "остальные пробелы не теряются")

let tab = CompletionShortcut(keyCode: 48, modifiers: 0)
expect(tab.matches(keyCode: 48, modifiers: 0), "Tab совпадает")
expect(!tab.matches(keyCode: 48, modifiers: 1 << 19), "Option Tab не совпадает")
expect(tab.matches(keyCode: 48, modifiers: 1 << 16), "Caps Lock не меняет сочетание")
expect(!tab.matches(keyCode: 48, modifiers: 1 << 17), "Shift различается")
expect(CompletionShortcut.conflict(tab, for: .acceptAll, bindings: [.nextWord: tab]) == .nextWord, "дубликат отклоняется")
expect(CompletionShortcut.conflict(tab, for: .nextWord, bindings: [.nextWord: tab]) == nil, "собственное назначение допустимо")
expect(!CompletionShortcut(keyCode: 0, modifiers: 0).isValid(for: .manual), "обычная буква не глобальная команда")
expect(!CompletionShortcut(keyCode: 53, modifiers: 0).isValid(for: .nextWord), "Esc зарезервирован")
expect(!CompletionShortcut(keyCode: 48, modifiers: 1 << 19).isValid(for: .acceptAll), "Option Tab зарезервирован")
expect(CompletionShortcut(keyCode: 50, modifiers: 1 << 18).isValid(for: .manual), "Ctrl сочетание разрешено")
expect(tab.decision(action: .acceptAll, keyCode: 48, modifiers: 0, isRepeat: false, tabEnabled: false) == .pass, "выключенный Tab не принимает всё")
expect(tab.decision(action: .nextWord, keyCode: 48, modifiers: 0, isRepeat: false, tabEnabled: false) == .pass, "выключенный Tab не принимает слово")
let toggle = CompletionShortcut(keyCode: 50, modifiers: 1 << 18)
expect(toggle.decision(action: .toggleGlobal, keyCode: 50, modifiers: 1 << 18, isRepeat: true, tabEnabled: true) == .consume, "повтор глобального переключателя проглатывается без действия")
expect(toggle.decision(action: .toggleApp, keyCode: 50, modifiers: 1 << 18, isRepeat: true, tabEnabled: true) == .consume, "повтор паузы не снимает её")
expect(toggle.decision(action: .toggleGlobal, keyCode: 50, modifiers: 1 << 18, isRepeat: false, tabEnabled: true) == .perform, "первое нажатие переключает")
expect(tab.decision(action: .nextWord, keyCode: 48, modifiers: 0, isRepeat: true, tabEnabled: true) == .perform, "удержание Tab принимает следующие слова")
let data = try! JSONEncoder().encode(tab)
expect(try! JSONDecoder().decode(CompletionShortcut.self, from: data) == tab, "сочетание Codable")

var pause = CompletionSuppression()
pause.dismiss(mode: .brief, app: "A", now: 10)
expect(pause.isSuppressed(app: "A", now: 12), "краткая пауза активна")
expect(!pause.isSuppressed(app: "B", now: 12), "другое приложение не затронуто")
expect(!pause.isSuppressed(app: "A", now: 13), "краткая пауза истекла")
pause.dismiss(mode: .untilAppSwitch, app: "A", now: 20)
pause.contextReset(appChanged: false)
expect(pause.isSuppressed(app: "A", now: 999), "клик не снимает паузу до смены приложения")
pause.contextReset(appChanged: true)
expect(!pause.isSuppressed(app: "A", now: 999), "смена приложения снимает паузу Esc")
pause.toggle(app: "A", now: 100)
pause.contextReset(appChanged: true)
expect(pause.isSuppressed(app: "A", now: 200), "пятиминутная пауза переживает смену приложения")
expect(!pause.isSuppressed(app: "A", now: 400), "пятиминутная пауза истекла")
pause.toggle(app: "A", now: 500)
pause.toggle(app: "A", now: 501)
expect(!pause.isSuppressed(app: "A", now: 502), "повторное сочетание снимает паузу")
pause.dismiss(mode: .untilAppSwitch, app: "A", now: 600)
pause.resume(app: "A")
expect(!pause.isSuppressed(app: "A", now: 601), "ручной вызов снимает паузу")
pause.dismiss(mode: .passThrough, app: "A", now: 700)
expect(!pause.isSuppressed(app: "A", now: 701), "сквозной Esc не ставит паузу")
// Настройки приложения и наследование проверяются в отдельном домене.
let suite = "speakey-controls-tests-" + UUID().uuidString
let isolatedDefaults = UserDefaults(suiteName: suite)!
defer { isolatedDefaults.removePersistentDomain(forName: suite) }
let apps = AutocompleteAppStore(defaults: isolatedDefaults)
expect(apps.tabEnabled("A", global: true), "Tab наследует включение")
expect(!apps.tabEnabled("A", global: false), "Tab наследует выключение")
apps.setTabEnabled("A", false)
expect(!apps.tabEnabled("A", global: true), "Tab выключен для приложения")
apps.setTabEnabled("A", true)
expect(apps.tabEnabled("A", global: false), "Tab включён для приложения")
apps.setTabEnabled("A", nil)
expect(apps.tabOverride("A") == nil, "наследование восстанавливается")
apps.setTabEnabled("A", false)
let restored = AutocompleteAppStore(defaults: isolatedDefaults)
expect(restored.tabOverride("A") == false, "переопределение переживает чтение с диска")
expect(!apps.isEnabled("com.cmuxterm.app"), "cmux остаётся исключён")
apps.setEnabled("com.cmuxterm.app", true)
expect(!apps.isEnabled("com.cmuxterm.app"), "ручное разрешение не снимает исключение")
// Наследование не закрепляется при добавлении приложения.
apps.register("com.new")
expect(apps.enabledOverride("com.new") == nil, "новое приложение наследует доступность")
expect(apps.recordOverride("com.new") == nil, "новое приложение наследует запись")
apps.setEnabled("com.new", false)
expect(!apps.isEnabled("com.new"), "явный запрет приложения")
apps.setEnabled("com.new", nil)
expect(apps.isEnabled("com.new") && apps.enabledOverride("com.new") == nil, "возврат к общей доступности")
apps.setRecordAllowed("com.new", false)
expect(!apps.shouldRecord("com.new", mode: .all, accepted: true), "запрет приложения останавливает запись")
apps.setRecordAllowed("com.new", nil)
expect(apps.shouldRecord("com.new", mode: .all, accepted: false), "запись наследует общий режим")
expect(!apps.shouldRecord("com.new", mode: .accepted, accepted: false), "режим принятых подсказок не пишет другие сессии")
expect(apps.shouldRecord("com.new", mode: .accepted, accepted: true), "принятая подсказка разрешает запись")
apps.setRecordAllowed("com.new", true)
expect(!apps.shouldRecord("com.new", mode: .off, accepted: true), "переопределение не снимает глобальный запрет записи")
expect(!apps.shouldRecord("com.cmuxterm.app", mode: .all, accepted: true), "терминал никогда не записывается")
expect(!apps.shouldRecord("com.new", mode: .all, accepted: true, autocompleteEnabled: false), "общий выключатель автодополнения останавливает запись")
apps.setEnabled("com.new", false)
expect(!apps.shouldRecord("com.new", mode: .all, accepted: true), "выключенное приложение не записывается")
apps.setEnabled("com.new", nil)
let loadedApps = AutocompleteAppStore(defaults: isolatedDefaults)
expect(loadedApps.enabledOverride("com.new") == nil && loadedApps.recordOverride("com.new") == true, "трёхсоставная настройка перечитывается")
let revision = AutocompletePrefs.recordingRevision
apps.setRecordAllowed("com.new", false)
expect(AutocompletePrefs.recordingRevision != revision, "смена политики отменяет ожидающие записи")
// Домен test executable изолирован от установленного приложения Speakey.
let prefs = UserDefaults.standard
let bindingKeys = CompletionAction.allCases.map { "ac.shortcut." + $0.rawValue }
let keys = bindingKeys + ["ac.enabled", "ac.acceptAllKeyCode", "ac.trailingSpace", "ac.trailingPunctuation", "ac.escapeMode", "ac.onlyCurrentWord", "ac.inlineCompletion", "ac.autoAlternatives", "ac.autoSynonyms", "ac.variantsDelayMs"]
let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { k in prefs.object(forKey: k).map { (k, $0) } })
defer {
    for k in keys { if let old = saved[k] { prefs.set(old, forKey: k) } else { prefs.removeObject(forKey: k) } }
}
for k in keys { prefs.removeObject(forKey: k) }
expect(!AutocompletePrefs.trailingSpace && AutocompletePrefs.trailingPunctuation, "прежние правила принятия по умолчанию")
expect(AutocompletePrefs.shortcut(.nextWord) == tab, "Tab назначен по умолчанию")
expect(AutocompletePrefs.shortcut(.manual) == nil, "новая глобальная команда не назначается сама")
AutocompletePrefs.acceptAllKeyCode = 50
expect(AutocompletePrefs.shortcut(.acceptAll)?.keyCode == 50, "миграция прежнего принятия всего")
AutocompletePrefs.setShortcut(nil, for: .acceptAll)
expect(AutocompletePrefs.shortcut(.acceptAll) == nil, "очистка не восстанавливает старое сочетание")
AutocompletePrefs.setShortcut(tab, for: .manual)
expect(AutocompletePrefs.shortcut(.manual) == nil, "недопустимое сочетание не сохраняется")
AutocompletePrefs.setShortcut(tab, for: .acceptAll)
expect(AutocompletePrefs.shortcut(.acceptAll) == nil, "дубликат не сохраняется")
let manual = CompletionShortcut(keyCode: 50, modifiers: 1 << 18)
AutocompletePrefs.setShortcut(manual, for: .manual)
expect(AutocompletePrefs.shortcut(.manual) == manual, "новое сочетание сохраняется")
AutocompletePrefs.trailingSpace = true
AutocompletePrefs.trailingPunctuation = false
expect(AutocompletePrefs.trailingSpace && !AutocompletePrefs.trailingPunctuation, "правила независимы")
AutocompletePrefs.enabled = true
let enabledRevision = AutocompletePrefs.recordingRevision
AutocompletePrefs.enabled = false
expect(AutocompletePrefs.recordingRevision != enabledRevision, "главный выключатель отменяет ожидающие записи")
expect(!AutocompletePrefs.onlyCurrentWord && !AutocompletePrefs.inlineCompletion && !AutocompletePrefs.autoAlternatives && !AutocompletePrefs.autoSynonyms, "новые режимы включаются явно")
expect(AutocompletePrefs.shortcut(.alternatives) == nil && AutocompletePrefs.shortcut(.synonyms) == nil, "новые команды не занимают сочетания сами")
AutocompletePrefs.variantsDelayMs = 10
expect(AutocompletePrefs.variantsDelayMs == 300, "задержка ограничена снизу")
AutocompletePrefs.variantsDelayMs = 5000
expect(AutocompletePrefs.variantsDelayMs == 2000, "задержка ограничена сверху")
AutocompletePrefs.setShortcut(manual, for: .synonyms)
expect(AutocompletePrefs.shortcut(.synonyms) == nil, "новая команда не дублирует существующее сочетание")
AutocompletePrefs.setShortcut(tab, for: .alternatives)
expect(AutocompletePrefs.shortcut(.alternatives) == nil, "альтернативы требуют модификатор")
let synonyms = CompletionShortcut(keyCode: 40, modifiers: (1 << 18) | (1 << 19))
AutocompletePrefs.setShortcut(synonyms, for: .synonyms)
expect(AutocompletePrefs.shortcut(.synonyms) == synonyms, "синонимы сохраняют отдельную команду")
print("autocomplete controls: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
