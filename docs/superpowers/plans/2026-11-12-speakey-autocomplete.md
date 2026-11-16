# Автодополнение Speakey — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speakey дописывает текст при наборе как Cotypist (серый текст у каретки, Tab по слову, Esc, ⌥Tab), с личным корпусом, контекстом экрана и контекстом для диктовки Whisper.

**Architecture:** Инференс — `llama-server` из vendor/llama.cpp, положенный в бандл как `Contents/Helpers/speakey-complete`, слушает unix-socket; Speakey говорит с ним HTTP/1.1 по сокету. Тап только отмечает нажатия (O(1)); запрос идёт после паузы с фоновой очереди, ответ показывается, только если поле не изменилось. Подсказка — неактивируемый NSPanel у каретки. Все новые модули — отдельные файлы в `Sources/Speakey/`, чистая логика покрыта swiftc-харнессом.

**Tech Stack:** Swift 5/AppKit, llama.cpp (Metal, статика), ScreenCaptureKit + Vision, CryptoKit AES-GCM + Keychain, swiftc-харнессы.

**Spec:** `docs/superpowers/specs/2026-11-12-speakey-autocomplete-design.md`

## Результат

Отдельный раздел настроек «Автодополнение» и пункт в меню строки состояния. После загрузки модели подсказки появляются в TextEdit, Notes, Safari, Chrome; Tab принимает слово; терминалы молчат.

## Global Constraints

- Колбэк тапа: внутри только O(1). AX, OCR, сокет, диск — вне main-колбэка.
- В логах (`kbLog`) только длины и счётчики, никакого текста.
- Вставка — только через `TextReplacer.insert` / `TextReplacer.replace` (маркер `kbSyntheticMarker`).
- Синтетические события (с маркерами Speakey) подсказку не вызывают и не принимают — они до `Engine.handleKeyDown` не доходят, этого достаточно.
- Сеть — только явная загрузка модели с проверкой SHA-256. Помощник слушает unix-socket в `~/Library/Application Support/Speakey/` (не TCP).
- Всё новое выключено по умолчанию, кроме самих подсказок после того, как человек включил фичу.
- Ключи UserDefaults новых настроек — с префиксом `ac.`.
- Терминалы (`com.apple.Terminal`, `com.mitchellh.ghostty`, `com.cmuxterm.app`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `net.kovidgoyal.kitty`, `io.alacritty`) и менеджеры паролей (`com.1password.1password`, `com.bitwarden.desktop`, `com.apple.Passwords`) — жёсткое исключение. VS Code/Cursor (`com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`) — выключены по умолчанию.
- Не коммитить spec и plan. Коммиты кода без AI-атрибуции.

**User decisions (already made):**
- «давай как есть. мне нравится всё» — механика Cotypist 1:1.
- «давай терминал потом» — терминалы вне объёма.
- «все настройки принимай, все вопросы решай сам» — исполнитель решает сам, вопросов не задаёт.
- «в настройках должен появиться отдельный пункт меню» — свой раздел в сайдбаре настроек.

## Review Focus

1. Tab в поле без видимой подсказки — должен работать как раньше (сниппеты, раскладка, обычный Tab). Тест: `handleKey` без подсказки возвращает `false`.
2. Ответ модели пришёл после того, как человек допечатал/ушёл из поля — не показывать. Тест: `CompletionText.isFresh` на изменённом префиксе → `false`.
3. Модель вернула текст с переводом строки, повтором уже набранного или пустоту — подсказки нет или она обрезана до строки. Тест на `clean`.
4. Подсказка висит после смены приложения/клика мышью — скрывается. Интеграция: `handleContextReset` → `hide`.
5. Пароли/токены в личном корпусе — вырезаются. Тест на `redactSecrets`.

---

## Файлы

| Файл | Ответственность |
|---|---|
| `Sources/Speakey/CompletionText.swift` | чистая логика: чистка ответа, разбиение по словам, «съедание», свежесть, фильтр секретов |
| `Sources/Speakey/CompletionPrompt.swift` | сборка промпта модели и затравки Whisper (фича B) в бюджет |
| `Sources/Speakey/CompletionEngine.swift` | запуск/останов помощника, HTTP по unix-socket, отмена, выгрузка при простое |
| `Sources/Speakey/CompletionModels.swift` | каталог GGUF, загрузка с SHA-256, пути |
| `Sources/Speakey/AutocompleteSettings.swift` | ключи `ac.*` (расширение AppSettings через UserDefaults) и `AutocompleteAppStore` (по приложению) |
| `Sources/Speakey/PersonalCorpus.swift` | зашифрованный корпус набранного, похожие фрагменты, частые термины |
| `Sources/Speakey/ContextHub.swift` | снимок поля: приложение, текст до каретки, прямоугольник каретки, экран, буфер, инструкции |
| `Sources/Speakey/ScreenContextProvider.swift` | ScreenCaptureKit + Vision OCR активного окна, только в памяти |
| `Sources/Speakey/GhostSuggestionPanel.swift` | призрачный текст у каретки |
| `Sources/Speakey/AutocompleteController.swift` | оркестратор: клавиши, пауза, запрос, показ, приём, опечатки |
| `Sources/Speakey/AutocompleteSettingsView.swift` | раздел настроек |
| `Sources/Speakey/{Engine,SettingsWindow,MenuBarController,L10n,WhisperBridge}.swift` | точечная интеграция |
| `build-app.sh`, `scripts/sign-speakey-app.sh` | положить и подписать помощник |
| `scripts/test-autocomplete.sh`, `Tests/Autocomplete/main.swift` | харнесс чистой логики |

## Задачи

### Task 0: Спайк llama.cpp и выбор модели

**Goal:** Собран статический `llama-server` с Metal, выбраны модели по задержке.

**Files:**
- Create: `vendor/llama.cpp/` (вне git), scratchpad `spike-llama.md`

**Acceptance Criteria:**
- [ ] `vendor/llama.cpp/build-speakey/bin/llama-server` существует, `otool -L` — только системные библиотеки
- [ ] p50 задержки на 20 запросах записан для двух моделей, URL+SHA-256 записаны

**Verify:** `otool -L vendor/llama.cpp/build-speakey/bin/llama-server` → только `/usr/lib` и `/System`

```json:metadata
{"files": ["vendor/llama.cpp"], "verifyCommand": "otool -L vendor/llama.cpp/build-speakey/bin/llama-server", "acceptanceCriteria": ["static llama-server built", "latency p50 measured for 2 models"], "modelTier": "standard"}
```

### Task 1: Чистая логика и промпт

**Goal:** `CompletionText` и `CompletionPrompt` с харнессом.

**Files:**
- Create: `Sources/Speakey/CompletionText.swift`, `Sources/Speakey/CompletionPrompt.swift`, `Tests/Autocomplete/main.swift`, `scripts/test-autocomplete.sh`

**Acceptance Criteria:**
- [ ] `bash scripts/test-autocomplete.sh` печатает `OK` и выходит с 0
- [ ] Все тесты из шагов ниже есть и проходят

**Verify:** `bash scripts/test-autocomplete.sh` → `autocomplete: N checks OK`

**Steps:**

- [ ] **Step 1: интерфейсы**

```swift
enum CompletionText {
    /// Обрезать на первом \n, убрать повтор хвоста `before`, ограничить maxWords словами; "" если пусто/мусор.
    static func clean(_ raw: String, before: String, maxWords: Int) -> String
    /// Следующий кусок для Tab: ведущие пробелы + непрерывный не-пробельный ран (пунктуация входит).
    static func nextChunk(_ s: String) -> (chunk: String, rest: String)
    /// Человек напечатал `typed` поверх подсказки: остаток, если `s` начинается с `typed`; иначе nil.
    static func consume(_ s: String, typed: String) -> String?
    /// Ответ свеж, если текст до каретки сейчас равен тому, с которым запрашивали.
    static func isFresh(requestedBefore: String, currentBefore: String) -> Bool
    static func redactSecrets(_ text: String) -> String   // токены ≥20 симв. со смесью букв/цифр, sk-/ghp_/xox, пароли после «пароль:/password:» → «•••»
    static func lastWord(_ before: String) -> String
}
struct CompletionContext {
    var appName: String; var before: String
    var screenText: String? = nil; var clipboard: String? = nil
    var globalInstruction: String? = nil; var appInstruction: String? = nil
    var snippets: [String] = []; var terms: [String] = []
}
enum CompletionPrompt {
    /// Документ для base-модели: шапка с инструкциями/контекстом, затем `before` ДОСЛОВНО в конце.
    /// Приоритет при нехватке бюджета: before(≤1200) > инструкции > snippets > terms > screen > clipboard.
    static func build(_ c: CompletionContext, budget: Int = 3000) -> String
    /// Затравка-словарь для Whisper (фича B): слова через запятую, без повторов, ≤ maxChars.
    static func dictationHint(dictionary: [String], screenTerms: [String], corpusTerms: [String], maxChars: Int = 240) -> String?
    /// Термины из текста экрана: слова с заглавной не в начале предложения, латиница, слова с цифрами; по частоте.
    static func terms(from text: String, max: Int) -> [String]
}
```

- [ ] **Step 2: тесты (assert-ы харнесса)**

```swift
expect(CompletionText.clean(" в ветку\nещё", before: "потом", maxWords: 6) == " в ветку", "обрезка на строке")
expect(CompletionText.clean("   ", before: "x", maxWords: 6) == "", "пустой ответ")
expect(CompletionText.clean(" а б в г д е ж", before: "x", maxWords: 3) == " а б в", "лимит слов")
expect(CompletionText.nextChunk(" в ветку, потом") == (" в", " ветку, потом"), "первое слово")
expect(CompletionText.nextChunk(" ветку, потом") == (" ветку,", " потом"), "пунктуация с словом")
expect(CompletionText.nextChunk("алить в") == ("алить", " в"), "дописывание слова")
expect(CompletionText.consume(" в ветку", typed: " в") == " ветку", "съедание")
expect(CompletionText.consume(" в ветку", typed: "x") == nil, "расхождение")
expect(CompletionText.consume(" в", typed: " в") == "", "съели целиком")
expect(!CompletionText.isFresh(requestedBefore: "пот", currentBefore: "пото"), "устарело")
expect(!CompletionText.redactSecrets("ключ sk-abcdefghijklmnopqrstuv123").contains("sk-abc"), "секрет")
let p = CompletionPrompt.build(CompletionContext(appName: "Telegram", before: "Привет, как"))
expect(p.hasSuffix("Привет, как"), "before в конце дословно")
let long = CompletionPrompt.build(CompletionContext(appName: "X", before: String(repeating: "а", count: 5000), screenText: "экран"), budget: 3000)
expect(long.count <= 3000, "бюджет")
expect((CompletionPrompt.dictationHint(dictionary: ["Speakey"], screenTerms: ["GitLab", "Speakey"], corpusTerms: [], maxChars: 240) ?? "") == "Speakey, GitLab", "затравка без повторов")
```

- [ ] **Step 3: реализация, Step 4: прогон** — `bash scripts/test-autocomplete.sh` (по образцу `scripts/test-voice-indicator.sh`: swiftc двух файлов + `Tests/Autocomplete/main.swift`, своя заглушка `kbLog`).

```json:metadata
{"files": ["Sources/Speakey/CompletionText.swift", "Sources/Speakey/CompletionPrompt.swift", "Tests/Autocomplete/main.swift", "scripts/test-autocomplete.sh"], "verifyCommand": "bash scripts/test-autocomplete.sh", "acceptanceCriteria": ["harness exits 0", "all listed asserts present"], "modelTier": "standard"}
```

### Task 2: Помощник, клиент и модели

**Goal:** `CompletionEngine` запускает `speakey-complete` с моделью на unix-socket и отдаёт дополнения; `CompletionModels` качает и проверяет GGUF; бандл несёт помощник.

**Files:**
- Create: `Sources/Speakey/CompletionEngine.swift`, `Sources/Speakey/CompletionModels.swift`
- Modify: `build-app.sh` (копировать `vendor/llama.cpp/build-speakey/bin/llama-server` → `$APP/Contents/Helpers/speakey-complete`, если есть), `scripts/sign-speakey-app.sh` (подписать помощник тем же сертификатом до подписи бандла, с hardened runtime и `Speakey.entitlements`-совместимыми правами, без sandbox)

**Acceptance Criteria:**
- [ ] Смоук-скрипт `scripts/test-completion-engine.sh` (swiftc CompletionEngine+CompletionModels+заглушки) запускает помощник на установленной модели и получает непустое дополнение к «Привет, как у тебя» за < 3 с после готовности
- [ ] Отмена предыдущего запроса работает (второй `complete` до ответа первого → первый колбэк получает nil)

**Verify:** `bash scripts/test-completion-engine.sh` → `engine: ok <ms>`

**Steps:**

```swift
struct CompletionModel { let id, title, fileName, url, sha256: String; let bytes: Int64; let note: String }
enum CompletionModels {
    static let all: [CompletionModel]          // лёгкая (по умолчанию) и стандартная — URL/SHA из спайка
    static var defaultID: String
    static var directory: URL                   // ~/Library/Application Support/Speakey/Models
    static func localURL(_ m: CompletionModel) -> URL
    static func isInstalled(_ m: CompletionModel) -> Bool   // файл есть и размер совпал
    static func download(_ m: CompletionModel, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void)  // URLSession, SHA-256 через ModelDownloader.sha256(ofFileAt:), атомарный move
    static func delete(_ m: CompletionModel)
}
final class CompletionEngine {
    static let shared = CompletionEngine()
    private(set) var state: State                 // .stopped / .starting / .ready / .failed(String)
    var onStateChange: ((State) -> Void)?         // на main
    func ensureRunning(model: URL)                // идемпотентно; повторный вызов с другой моделью перезапускает
    func stop()
    /// Отменяет предыдущий незавершённый запрос (его колбэк получает nil). Колбэк — на main.
    func complete(prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void)
    func noteUse()                                // для выгрузки после `ac.idleUnloadMinutes` простоя
}
```

Аргументы помощника: `-m <gguf> --host <sock> -c 4096 -ngl 99 --no-webui -np 1` (+ флаги, найденные в спайке). Запрос `POST /completion` `{"prompt", "n_predict", "temperature":0.2, "top_k":20, "cache_prompt":true, "stop":["\n"]}` → поле `content`. HTTP — свой минимальный клиент POSIX `socket(AF_UNIX)` + `Connection: close`, таймаут 2 с. Помощник ищется в `Bundle.main.bundleURL/Contents/Helpers/speakey-complete`, иначе env `SPEAKEY_COMPLETE_BIN`. Процесс помощника завершается вместе со Speakey (terminate в `applicationWillTerminate` и kill по pid-файлу старого при старте).

```json:metadata
{"files": ["Sources/Speakey/CompletionEngine.swift", "Sources/Speakey/CompletionModels.swift", "build-app.sh", "scripts/sign-speakey-app.sh", "scripts/test-completion-engine.sh"], "verifyCommand": "bash scripts/test-completion-engine.sh", "acceptanceCriteria": ["non-empty completion via helper", "cancel delivers nil to previous"], "modelTier": "standard"}
```

### Task 3: Настройки, корпус, контекст, оверлей

**Goal:** Хранилища и источники контекста, оверлей подсказки.

**Files:**
- Create: `Sources/Speakey/AutocompleteSettings.swift`, `Sources/Speakey/PersonalCorpus.swift`, `Sources/Speakey/ContextHub.swift`, `Sources/Speakey/ScreenContextProvider.swift`, `Sources/Speakey/GhostSuggestionPanel.swift`
- Test: дописать в `Tests/Autocomplete/main.swift` проверки корпуса (через временный каталог)

**Acceptance Criteria:**
- [ ] Корпус: записанный текст не читается как UTF-8 из файла на диске (зашифрован); `similar(to:)` находит фрагмент с общими словами; `topTerms` возвращает частые слова; секреты вырезаны
- [ ] `bash scripts/test-autocomplete.sh` зелёный

**Verify:** `bash scripts/test-autocomplete.sh`

```swift
// AutocompleteSettings.swift — UserDefaults.standard, ключи "ac.*"
enum AutocompleteRecordMode: String { case off, accepted, all }
enum AutocompletePrefs {
    static var enabled: Bool            // false
    static var modelID: String          // CompletionModels.defaultID
    static var maxWords: Int            // 6
    static var pauseMs: Int             // 120
    static var recordMode: AutocompleteRecordMode   // .off
    static var personalStrength: Int    // 0…3, 2
    static var globalInstruction: String
    static var useScreen: Bool          // false
    static var useClipboard: Bool       // false
    static var typoFix: Bool            // true
    static var dictationContext: Bool   // false
    static var batteryLight: Bool       // false — на батарее лёгкая модель и 3 слова
    static var idleUnloadMinutes: Int   // 60
    static var acceptAllKeyCode: Int    // -1 (не назначено); 50 = клавиша над Tab
}
final class AutocompleteAppStore {      // UserDefaults "ac.apps" JSON {bid: {enabled, record, instruction}}
    static let shared: AutocompleteAppStore
    static let hardExcluded: Set<String>         // терминалы + менеджеры паролей
    static let offByDefault: Set<String>         // VS Code, Cursor
    func isEnabled(_ bid: String) -> Bool
    func setEnabled(_ bid: String, _ on: Bool)
    func instruction(_ bid: String) -> String
    func setInstruction(_ bid: String, _ s: String)
    func recordAllowed(_ bid: String) -> Bool
    func setRecordAllowed(_ bid: String, _ on: Bool)
    var configuredApps: [String]
}
// PersonalCorpus.swift — файл ~/Library/Application Support/Speakey/corpus.bin, AES-GCM, ключ в Keychain (как VoiceHistory)
final class PersonalCorpus {
    static let shared: PersonalCorpus
    init(directory: URL, keyProvider: @escaping () -> SymmetricKey)   // для тестов
    func add(_ text: String, bundleID: String)   // < 20 симв. не пишем; redactSecrets; потолок 5000 записей
    func similar(to before: String, limit: Int) -> [String]   // пересечение слов, свежесть как тай-брейк
    func topTerms(limit: Int) -> [String]
    func removeAll(); func remove(bundleID: String)
    var count: Int
}
// ContextHub.swift — только вне main-колбэка тапа
struct FieldSnapshot { let bundleID: String; let appName: String; let before: String; let caretRect: NSRect; let pid: pid_t }
enum ContextHub {
    static func snapshot(maxBefore: Int = 1500) -> FieldSnapshot?   // AXScreenCheck.textBeforeCaret + CaretLocator.caretScreenRect + frontmost app
    static func context(for s: FieldSnapshot) -> CompletionContext  // инструкции, корпус по силе, экран/буфер по настройкам
}
// ScreenContextProvider.swift — SCScreenshotManager окна фронтального приложения → VNRecognizeTextRequest(ru,en), кэш 10 с на окно
final class ScreenContextProvider {
    static let shared: ScreenContextProvider
    var latestText: String?                          // последний распознанный текст активного окна, ≤ 2000 симв.
    func refreshIfNeeded(pid: pid_t)                 // асинхронно, не чаще раза в 3 с; без разрешения — тихо nil
    static var hasPermission: Bool                   // CGPreflightScreenCaptureAccess
    static func requestPermission()                  // CGRequestScreenCaptureAccess
}
// GhostSuggestionPanel.swift — по образцу VoiceIndicator.makePanel(): .nonactivatingPanel, ignoresMouseEvents, level .statusBar, .moveToActiveSpace
final class GhostSuggestionPanel {
    static let shared: GhostSuggestionPanel
    func show(_ text: String, caret: NSRect, isCorrection: Bool)   // справа от каретки, шрифт = высоте каретки (11…28pt), серый secondaryLabelColor; isCorrection — с префиксом «→ »
    func hide()
    var isVisible: Bool
}
```

```json:metadata
{"files": ["Sources/Speakey/AutocompleteSettings.swift", "Sources/Speakey/PersonalCorpus.swift", "Sources/Speakey/ContextHub.swift", "Sources/Speakey/ScreenContextProvider.swift", "Sources/Speakey/GhostSuggestionPanel.swift"], "verifyCommand": "bash scripts/test-autocomplete.sh", "acceptanceCriteria": ["corpus encrypted on disk", "similar/topTerms work", "harness green"], "modelTier": "standard"}
```

### Task 4: Оркестратор и интеграция с тапом

**Goal:** `AutocompleteController` + вызов из `Engine.handleKeyDown`, сброс на смене контекста, остановка при выключении.

**Files:**
- Create: `Sources/Speakey/AutocompleteController.swift`
- Modify: `Sources/Speakey/Engine.swift` (после проверки Secure Input в `handleKeyDown`; `handleContextReset`), `Sources/Speakey/AppDelegate.swift` (старт/стоп)

**Acceptance Criteria:**
- [ ] `./build-app.sh` с `SPEAKEY_BUILD_APP=/private/tmp/...` собирается
- [ ] Без видимой подсказки `handleKey` возвращает false для Tab — сниппеты и раскладка работают как раньше
- [ ] В TextEdit настоящими нажатиями: появляется серый текст, Tab вставляет слово, Esc скрывает

**Verify:** сборка + ручная проверка через Cua Driver (foreground HID-нажатия разрешены Никой)

```swift
final class AutocompleteController {
    static let shared: AutocompleteController
    /// main, внутри колбэка тапа — только O(1). true = проглотить.
    /// Видима подсказка: Tab без мод. → принять кусок; ⌥Tab → скрыть, false; Esc → скрыть и приостановить поле до клика/смены приложения; acceptAll-клавиша → принять всё;
    /// печатный символ → consume (совпал — обновить панель без запроса), иначе скрыть. Любая другая клавиша → скрыть.
    /// В конце — перезапустить таймер паузы (DispatchWorkItem на main, `pauseMs`).
    func handleKey(keyCode: Int64, characters: String, flags: CGEventFlags) -> Bool
    func contextReset()                 // клик/смена приложения: скрыть, сбросить паузу Esc
    func setEnabled(_ on: Bool)         // старт/стоп помощника
    /// Engine даёт предикат «слово перед кареткой — триггер сниппета или кандидат раскладки»: тогда не показываем.
    var suppressForWord: ((String) -> Bool)?
}
```

Таймер паузы → фоновая очередь: проверки (фича включена, приложение не исключено, нет Secure Input через `SecureInputPolicy`, не идёт диктовка) → `ContextHub.snapshot()` → `before` пустой или кончается на перевод строки после пустой строки → нет; `suppressForWord(lastWord)` → нет → `CompletionEngine.complete` → `CompletionText.clean` → повторный `snapshot` и `isFresh` → показ на main. Опечатки (`typoFix`): если `before` оканчивается пробелом и предыдущее слово `NSSpellChecker` (язык по букве) считает ошибкой и даёт `correction` — показать «→ исправление» (`isCorrection`), Tab = `TextReplacer.replace(deleteCount: слово+пробел, with: исправление+" ")`. При приёме: `PersonalCorpus` пишет текст поля на уходе из поля (contextReset) по `recordMode`.

```json:metadata
{"files": ["Sources/Speakey/AutocompleteController.swift", "Sources/Speakey/Engine.swift", "Sources/Speakey/AppDelegate.swift"], "verifyCommand": "SPEAKEY_BUILD_APP=/private/tmp/speakey-ac/Speakey.app ./build-app.sh", "acceptanceCriteria": ["app builds", "Tab without ghost passes through", "ghost shows and Tab accepts word in TextEdit"], "modelTier": "frontier"}
```

### Task 5: Раздел настроек и меню

**Goal:** Раздел «Автодополнение» в сайдбаре и переключатель в меню строки состояния.

**Files:**
- Create: `Sources/Speakey/AutocompleteSettingsView.swift`
- Modify: `Sources/Speakey/SettingsWindow.swift` (case `.autocomplete` после `.voice`, символ `text.cursor`), `Sources/Speakey/L10n.swift` (`sec.autocomplete` и ключи `ac.*`, ru+en), `Sources/Speakey/MenuBarController.swift` (пункт «Автодополнение» с галочкой)

**Acceptance Criteria:**
- [ ] Раздел содержит: главный переключатель; модель (выбор, «Скачать» с прогрессом, «Удалить», статус помощника); длина подсказки; пауза; клавиши (подпись: Tab — слово, ⌥Tab — обычный Tab, Esc — скрыть, «Принять всё» — выбор клавиши); опечатки; личный корпус (режим, сила Off/Light/Medium/Strong, счётчик, «Удалить всё»); «О себе»; приложения (список с вкл/выкл и инструкцией, кнопка «Добавить текущее»); контекст экрана (+ запрос разрешения); буфер обмена; контекст для диктовки; батарея; совет выключить встроенные подсказки macOS
- [ ] Снимок окна через `SPEAKEY_WINSHOT` или Cua показывает раздел

**Verify:** сборка + снимок раздела

```json:metadata
{"files": ["Sources/Speakey/AutocompleteSettingsView.swift", "Sources/Speakey/SettingsWindow.swift", "Sources/Speakey/L10n.swift", "Sources/Speakey/MenuBarController.swift"], "verifyCommand": "SPEAKEY_BUILD_APP=/private/tmp/speakey-ac/Speakey.app ./build-app.sh", "acceptanceCriteria": ["settings section visible", "menu toggle present"], "modelTier": "standard"}
```

### Task 6: Контекст диктовки (фича B)

**Goal:** При `dictationContext` затравка Whisper получает термины экрана и корпуса.

**Files:**
- Modify: `Sources/Speakey/WhisperBridge.swift` (дефолтный `recognitionHint` → `DictationContext.hint()`), `Sources/Speakey/VoiceController.swift` (снимок экрана на старте диктовки), Create: `Sources/Speakey/DictationContext.swift`

**Acceptance Criteria:**
- [ ] Выключено — затравка байт-в-байт как раньше
- [ ] Включено — `CompletionPrompt.dictationHint` из словаря + `CompletionPrompt.terms(from: ScreenContextProvider.latestText)` + `PersonalCorpus.topTerms`, ≤ 240 симв., итог ≤ 600
- [ ] CLI оценки: env `SPEAKEY_SPEECH_HINT=1` включает словарную затравку (`SpeechEvaluationCLI.swift:41`)

**Verify:** сборка; `bash scripts/test-autocomplete.sh`

```json:metadata
{"files": ["Sources/Speakey/DictationContext.swift", "Sources/Speakey/WhisperBridge.swift", "Sources/Speakey/VoiceController.swift", "Sources/Speakey/SpeechEvaluationCLI.swift"], "verifyCommand": "bash scripts/test-autocomplete.sh", "acceptanceCriteria": ["off = unchanged prompt", "on = merged hint within 600"], "modelTier": "standard"}
```

### Task 7: Сборка, установка, живая проверка, отчёт

**Goal:** Собранное приложение установлено, проверено настоящими нажатиями, есть отчёт.

**Files:**
- Create: отчёт в `~/reports/Speakey/` через скил `report`

**Acceptance Criteria:**
- [ ] `python3 scripts/install-speakey.py` поставил сборку, Speakey запущен
- [ ] Матрица: TextEdit, Notes, Safari/Chrome — подсказка есть, Tab/Esc/⌥Tab работают; терминал — подсказок нет
- [ ] `grep` логов Speakey за прогон не находит набранного текста
- [ ] Отчёт открыт в браузере

**Verify:** вывод харнессов, снимки окон, grep логов

```json:metadata
{"files": [], "verifyCommand": "bash scripts/test-autocomplete.sh", "acceptanceCriteria": ["installed and running", "manual matrix passed", "no text in logs", "report opened"], "modelTier": "frontier"}
```

## Порядок

Task 0 ‖ Task 1 ‖ Task 3 → Task 2 (после 0) ‖ Task 5 ‖ Task 6 → Task 4 → Task 7. Интерфейсы выше зафиксированы, поэтому 1/3/5/6 пишутся параллельно; каждый агент проверяет только свой харнесс, полная сборка — в Task 4.

## Условия

- Время: 2 часа от 21:30 MSK, к 23:30 — отчёт.
- Если p50 > 200 мс у 4B — по умолчанию лёгкая модель.
- Labs (варианты слова, синонимы, дописывание в середине строки) — вне этого прохода, записать в отчёт как следующий шаг.
