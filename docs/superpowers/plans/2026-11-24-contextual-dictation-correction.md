# Уточнение диктовки по контексту (слой A) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** после первого прохода Whisper найти в контексте Ники слова, похожие на слова расшифровки, распознать аудио второй раз с ними в затравке и принять результат только при точечных заменах на эти слова; доказать эффект замером.

**Architecture:** два чистых модуля без `whisper.cpp` (`ContextLexicon` — подбор кандидатов, `ContextualRedecode` — решение о втором проходе и приём результата) + параметр `contextWords` в `WhisperBridge.transcribe` + сбор источников контекста в `DictationContext` + проводка в `VoiceController`. Стенд: флаги `--context`/`--deterministic` в `SpeechEvaluationCLI`, сравнение прогонов в `Tools/SpeechEvaluation`.

**Tech Stack:** Swift 5 / AppKit, whisper.cpp, тесты-бинарники через `swiftc` + `scripts/test-*.sh`, Python 3 `unittest` для `Tools/SpeechEvaluation`.

**Spec:** `docs/superpowers/specs/2026-11-24-contextual-dictation-correction-design.md`

## Global Constraints

- Лог (`kbLog`) и консоль — только числа: сколько кандидатов, был ли второй проход, принят ли, миллисекунды. Ни слов кандидатов, ни текста экрана, корпуса, расшифровки.
- Затравка Whisper целиком ≤ 600 символов (`WhisperBridge.promptMaxChars`). Фраза про пунктуацию не урезается никогда; при переполнении сначала отбрасываются хвостовые слова контекста, потом слова словаря.
- В затравку не попадают `«`, `»`, `:`, `;` (правило в `WhisperBridge.transcribe`).
- Второй проход: только движок Whisper, только финальный текст (не живой черновик), только если `AppSettings.voiceContextRefine` и `AutocompletePrefs.dictationContext` включены.
- Второй проход не запускается, если `firstPassSeconds * 2 > 0.6 * timeoutSeconds`, где `timeoutSeconds` — бюджет сторожа из `beginTranscription` (`min(90, max(15, duration * 1.5))`, +60 при холодной загрузке).
- T2 принимается целиком или отклоняется целиком. Изменённых слов ≤ `max(1, floor(0.3 × слов T1))`, каждое новое слово — кандидат или форма кандидата (общая основа), вставки и удаления слов запрещены.
- Комментарии и тексты проверок — по-русски, в стиле файлов вокруг. Коммиты — английский Conventional Commits, без AI-атрибуции (правило Ники).
- Личные отчёты и прогоны — вне репозитория (`write_report` и `run_corpus` это уже проверяют).

**User decisions (already made):**
- «мне важнее точность» — задержка ради точности допустима.
- «давай, как ты предлагаешь» — сначала слой A, слой B (языковая модель) решается по замеру после этого плана.
- Дизайн-док утверждён («да», 24.11.2026) вместе с решениями дизайнера в нём.

## Review Focus

1. Пустая или однословная расшифровка, тишина → нет кандидатов, нет второго прохода, текст как раньше (тест в Task 1 и Task 3).
2. Второй проход вернул пустоту или эхо затравки при непустом T1 → остаётся T1 (тест в Task 3).
3. Слово расшифровки уже есть в контексте Ники в той же форме («мобилке») → для него кандидата нет, правильное слово не трогаем (тест в Task 1).
4. Слова контекста с запрещёнными знаками, очень длинные или их много → затравка ≤ 600, фраза пунктуации цела, запрещённых знаков нет (тест в Task 2).
5. Длинная диктовка, где первый проход занял больше 30% бюджета сторожа → второго прохода нет, отдаётся T1 без ожидания (тест в Task 3).

---

### Task 1: ContextLexicon — подбор слов-кандидатов

**Goal:** чистая функция, которая по расшифровке и источникам контекста возвращает ранжированные слова-кандидаты на замену.

**Files:**
- Create: `Sources/Speakey/ContextLexicon.swift`
- Create: `Tests/ContextLexicon/main.swift`
- Create: `scripts/test-context-lexicon.sh`

**Acceptance Criteria:**
- [ ] На примере Ники кандидаты содержат `DPR` (замена `tpr`) и форму с основой «подборк» (замена `подбора`).
- [ ] Пустые источники и пустая расшифровка дают `[]`.
- [ ] Слово расшифровки, которое есть в источниках в той же форме, кандидатов не получает.
- [ ] Кириллица и латиница сопоставляются: «спики» находит `Speakey`, `next` находит `Nuxt`.
- [ ] Файл компилируется только с Foundation.

**Verify:** `bash scripts/test-context-lexicon.sh` → все строки `PASS`, код выхода 0.

**Steps:**

- [ ] **Step 1: Тесты.** В `Tests/ContextLexicon/main.swift` харнесс `check(_:_:)` как в `Tests/PersonalWriting/main.swift`, `exit(failures == 0 ? 0 : 1)`. Проверки:

```swift
let corpus = ContextSource(kind: .corpus, words: ["DPR": 3, "dpr": 1, "подборки": 6, "подборок": 4, "мобилке": 2])
let example = "Посмотри на этой странице на мобилке, какое tpr у фоток подбора."
let found = ContextLexicon.candidates(for: example, sources: [corpus], limit: 8)
check("tpr получает кандидата DPR", found.contains { $0.replaces == "tpr" && $0.word == "DPR" })
check("подбора получает форму подборки/подборок", found.contains { $0.replaces == "подбора" && ["подборки", "подборок"].contains($0.word) })
check("мобилке без кандидатов", !found.contains { $0.replaces == "мобилке" })
check("пустые источники", ContextLexicon.candidates(for: example, sources: [], limit: 8).isEmpty)
check("пустая расшифровка", ContextLexicon.candidates(for: "", sources: [corpus], limit: 8).isEmpty)
check("кириллица ↔ латиница", ContextLexicon.candidates(for: "открой спики", sources: [ContextSource(kind: .dictionary, words: ["Speakey": 1])], limit: 8).first?.word == "Speakey")
check("next ↔ Nuxt", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .screen, words: ["Nuxt": 2])], limit: 8).first?.word == "Nuxt")
check("ключ tpr == ключ DPR", ContextLexicon.phoneticKey("tpr") == ContextLexicon.phoneticKey("DPR"))
check("основа подбора == основа подборок", ContextLexicon.stem("подбора") == ContextLexicon.stem("подборок"))
check("лимит соблюдается", ContextLexicon.candidates(for: example, sources: [corpus], limit: 1).count == 1)
```

- [ ] **Step 2: Скрипт** `scripts/test-context-lexicon.sh` по образцу `scripts/test-personal-writing.sh`: `swiftc -O -swift-version 5` с `Sources/Speakey/ContextLexicon.swift Tests/ContextLexicon/main.swift`. Запуск → ошибка компиляции (типов нет).

- [ ] **Step 3: Реализация** в `Sources/Speakey/ContextLexicon.swift`:

```swift
struct ContextSource {
    enum Kind { case screen, recentDictation, corpus, dictionary }
    let kind: Kind
    let words: [String: Int]          // написание → сколько раз встречалось
}
struct ContextCandidate: Equatable {
    let word: String                  // как писать (самая частая форма из источников)
    let replaces: String              // слово расшифровки, как оно было
    let score: Double
}
enum ContextLexicon {
    static func words(in text: String) -> [String]      // буквы/цифры, без пунктуации, порядок сохранён
    static func phoneticKey(_ word: String) -> String
    static func stem(_ word: String) -> String
    static func candidates(for transcript: String, sources: [ContextSource], limit: Int) -> [ContextCandidate]
}
```

Правила, которые тесты не фиксируют полностью:
- `phoneticKey`: lowercase → транслитерация кириллицы в латиницу (ж→zh, ш/щ→sh, ч→ch, ц→ts, х→h, й→y, ь/ъ→пусто) → склейка звонких с глухими (d→t, b→p, g→k, z→s, v→f, zh→sh) → `c`/`q`/`ck`→k, `x`→ks, `ph`→f → удалить гласные (a e i o u y э ы ю я ё), кроме первой буквы слова → схлопнуть повторы букв.
- `stem`: lowercase; для кириллицы срезать самое длинное окончание из списка (`ами ями ого его ому ему ыми ими ах ях ов ев ей ой ий ый ая яя ое ее ые ие ом ем ок ек а я о е ы и у ю ь`), если остаётся ≥ 4 букв; латиница без изменений.
- Совпадение слова расшифровки `w` с формой `c` из источника: `c` не совпадает с `w` без учёта регистра; и либо `phoneticKey` равны и длиной ≥ 3 (сила 1.0), либо равны `stem` и длина основы ≥ 4 (сила 0.8). Слова расшифровки короче 2 букв пропускаются.
- Если `w` в той же форме (без учёта регистра) есть в любом источнике — для `w` кандидатов нет.
- Счёт: `сила × вес источника × log(1 + count)`; веса screen 3, recentDictation 2, dictionary 2, corpus 1. Формы одного слова из разных источников складываются; `word` — форма с наибольшим count. На каждое `w` — лучший кандидат; итог сортируется по счёту, обрезается до `limit`.

- [ ] **Step 4: Проверить.** `bash scripts/test-context-lexicon.sh` → все `PASS`.

- [ ] **Step 5: Коммит.** `git add Sources/Speakey/ContextLexicon.swift Tests/ContextLexicon scripts/test-context-lexicon.sh && git commit -m "feat: add context lexicon for dictation candidates"`

---

### Task 2: Слова контекста в затравке Whisper

**Goal:** `WhisperBridge.transcribe` принимает слова контекста и ставит их в затравку раньше словаря, в пределах 600 символов.

**Files:**
- Modify: `Sources/Speakey/WhisperPrompt.swift` (новая чистая функция)
- Modify: `Sources/Speakey/WhisperBridge.swift:80` (`transcribe`), `:297-336` (`punctuationPrompt`)
- Create: `Tests/WhisperPrompt/main.swift`, `scripts/test-whisper-prompt.sh`

**Acceptance Criteria:**
- [ ] `WhisperPrompt.wordsPhrase(contextWords:hintWords:language:maxChars:)` ставит слова контекста первыми, без дублей (без учёта регистра).
- [ ] При переполнении отбрасываются хвостовые слова контекста, затем слова словаря; фраза пунктуации цела; итоговая затравка ≤ 600.
- [ ] Из слов вырезаются `«`, `»`, `:`, `;`; слова длиннее 40 символов отбрасываются.
- [ ] Вызовы `transcribe` без нового параметра работают как раньше (затравка байт-в-байт та же при пустом `contextWords`).
- [ ] `stripEcho` срезает эхо новой фразы целиком.

**Verify:** `bash scripts/test-whisper-prompt.sh` → все `PASS`; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.

**Steps:**

- [ ] **Step 1: Тесты** в `Tests/WhisperPrompt/main.swift`: пустой контекст → результат равен прежней фразе `" Часто встречаются слова: a, b."` для `hintWords ["a","b"]`, `ru`; контекст `["DPR","подборок"]` + hint `["Speakey","dpr"]` → `" Часто встречаются слова: DPR, подборок, Speakey."`; `en` → префикс `" Words that often come up: "`; 200 длинных слов + фраза `WhisperPrompt.ru` → `(WhisperPrompt.ru + phrase).count <= 600` и `phrase` начинается с первого слова контекста; слово `"a«b:c;"` превращается в `"abc"`; `WhisperPrompt.stripEcho(WhisperPrompt.ru + phrase + " текст", prompt: WhisperPrompt.ru + phrase).text == "текст"`.

- [ ] **Step 2: Скрипт** по образцу Task 1 с `Sources/Speakey/WhisperPrompt.swift`. Запуск → не компилируется.

- [ ] **Step 3: Реализация.**
  - `static func wordsPhrase(contextWords: [String], hintWords: [String], language: String, maxChars: Int) -> String` в `WhisperPrompt` — возвращает `""` при пустом списке, иначе `" Часто встречаются слова: …."` / `" Words that often come up: …."`; `maxChars` — бюджет на саму фразу.
  - `WhisperBridge.transcribe(samples:language:contextWords: [String] = [], diagnostics:)`; `punctuationPrompt(for:contextWords:)` берёт `hintWords` из `recognitionHint()` (разбивка по `", "`), вызывает `wordsPhrase` с `maxChars = promptMaxChars - head.count - tail.count`. Лог «подмешано N слов» дополнить числом слов контекста.

- [ ] **Step 4: Проверить.** Скрипт → `PASS`; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.

- [ ] **Step 5: Коммит.** `git commit -m "feat: accept context words in whisper prompt"` (файлы задачи).

---

### Task 3: ContextualRedecode — когда второй проход и что принимать

**Goal:** чистые функции решения о втором проходе и приёма T2.

**Files:**
- Create: `Sources/Speakey/ContextualRedecode.swift`
- Create: `Tests/ContextualRedecode/main.swift`, `scripts/test-contextual-redecode.sh`

**Acceptance Criteria:**
- [ ] `shouldRunSecondPass` false без кандидатов и при `firstPassSeconds * 2 > 0.6 * timeoutSeconds`.
- [ ] `accept` принимает пример Ники и отклоняет: замену не на кандидата, > 30% изменённых слов, вставку/удаление слова, пустой T2 при непустом T1.
- [ ] Разница только в регистре и пунктуации считается нулём изменённых слов и принимается.

**Verify:** `bash scripts/test-contextual-redecode.sh` → все `PASS`.

**Steps:**

- [ ] **Step 1: Тесты:**

```swift
let c = [ContextCandidate(word: "DPR", replaces: "tpr", score: 1), ContextCandidate(word: "подборок", replaces: "подбора", score: 1)]
let t1 = "Посмотри на этой странице на мобилке, какое tpr у фоток подбора."
check("пример Ники", ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборок.", candidates: c))
check("форма кандидата", ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборки.", candidates: c))
check("не кандидат", !ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое TPR у фото подборок.", candidates: c))
check("вставка слова", !ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у всех фоток подборок.", candidates: c))
check("больше 30%", !ContextualRedecode.accept(first: "tpr подбора", second: "DPR подборок", candidates: c)) // 2 изменения при лимите max(1, floor(0.6)) = 1
check("пустой T2", !ContextualRedecode.accept(first: t1, second: "", candidates: c))
check("регистр и точка", ContextualRedecode.accept(first: t1, second: t1.lowercased().replacingOccurrences(of: ".", with: ""), candidates: c))
check("нет кандидатов", !ContextualRedecode.shouldRunSecondPass(firstPassSeconds: 0.5, timeoutSeconds: 15, candidateCount: 0))
check("бюджет ок", ContextualRedecode.shouldRunSecondPass(firstPassSeconds: 0.9, timeoutSeconds: 15, candidateCount: 2))
check("бюджет превышен", !ContextualRedecode.shouldRunSecondPass(firstPassSeconds: 4.6, timeoutSeconds: 15, candidateCount: 2))
```
- [ ] **Step 2: Скрипт** — компилирует `ContextLexicon.swift` + `ContextualRedecode.swift` + тест. Запуск → не компилируется.

- [ ] **Step 3: Реализация:**

```swift
enum ContextualRedecode {
    static let budgetShare = 0.6
    static let maxChangedShare = 0.3
    static func shouldRunSecondPass(firstPassSeconds: Double, timeoutSeconds: Double, candidateCount: Int) -> Bool
    static func accept(first: String, second: String, candidates: [ContextCandidate]) -> Bool
}
```

  `accept`: слова через `ContextLexicon.words(in:)`, сравнение без регистра; одинаковое число слов обязательно (иначе вставка/удаление → false); замены по позициям; новое слово допустимо, если равно `word` кандидата без регистра или `ContextLexicon.stem` совпадает со stem кандидата. Пустой `second` при непустом `first` → false.

- [ ] **Step 4: Проверить** → все `PASS`.

- [ ] **Step 5: Коммит.** `git commit -m "feat: add second-pass decision for contextual dictation"`

---

### Task 4: Источники контекста в приложении

**Goal:** `DictationContext` собирает `[ContextSource]` для текущей диктовки: экран, недавние диктовки, корпус, словарь.

**Files:**
- Modify: `Sources/Speakey/PersonalWritingIndex.swift` (новый `vocabulary`), `Sources/Speakey/PersonalCorpus.swift` (обёртка)
- Modify: `Sources/Speakey/DictationContext.swift`
- Modify: `Tests/PersonalWriting/main.swift`

**Acceptance Criteria:**
- [ ] `PersonalWritingIndex.vocabulary(bundleID:) -> [String: Int]` отдаёт написание → `count + 2 × count_в_приложении`; без `bundleID` — просто `count`.
- [ ] `PersonalCorpus.vocabulary(bundleID:)` возвращает `[:]`, если корпус недоступен.
- [ ] `DictationContext.sources(pid:bundleID:) -> [ContextSource]` при выключенном `AutocompletePrefs.dictationContext` возвращает `[]`; экран берётся только если `useScreen` и приложение разрешено (как в `prepare()`); недавние диктовки — `VoiceHistory.shared.all()` с `resolvedKind == .dictation` за последние 2 часа, не больше 20; словарь — правые части `VoiceDictionary.shared.pairs()`.

**Verify:** `bash scripts/test-personal-writing.sh` → все `PASS`; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.

**Steps:**

- [ ] **Step 1: Тест** в `Tests/PersonalWriting/main.swift`: на `records` из файла `index.vocabulary(bundleID: "mail")["RiverCache"]` равно `2 + 2 × 2`, `index.vocabulary(bundleID: nil)["RiverCache"] == 2`.
- [ ] **Step 2:** запуск → не компилируется.
- [ ] **Step 3: Реализация.** `vocabulary` перебирает `termStatistics`, каждую форму из `forms` кладёт со своим счётом (`forms[form]` + app-бонус пропорционально); `PersonalCorpus.vocabulary` через `withIndex`. `DictationContext.sources(pid:bundleID:)` — экран через `ScreenContextProvider.shared.text(for: pid)` → частоты слов `ContextLexicon.words(in:)`. Диктовки в истории не хранят приложение — берутся все за 2 часа (решение плана, отклонение от «в этом приложении» в спеке).
- [ ] **Step 4:** тест → `PASS`; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.
- [ ] **Step 5: Коммит.** `git commit -m "feat: collect dictation context sources"`

---

### Task 5: Второй проход в VoiceController + настройка

**Goal:** реальная диктовка через Whisper проходит слой A; в настройках диктовки есть переключатель.

**Files:**
- Modify: `Sources/Speakey/VoiceController.swift` (ветка whisper `~:438-452`, `beginTranscription ~:459`)
- Modify: `Sources/Speakey/AppSettings.swift` (`voiceContextRefine`, по умолчанию `true`)
- Modify: `Sources/Speakey/SettingsWindow.swift` (переключатель в разделе диктовки), `Sources/Speakey/L10n.swift` (ru/en строки)

**Acceptance Criteria:**
- [ ] `beginTranscription` сохраняет бюджет сторожа по `gen` (словарь `transcriptionBudgets[gen]`), ветка whisper читает его.
- [ ] `pid`/`bundleID` фиксируются в начале записи (там же, где `DictationContext.prepare()`), источники собираются на main до ухода в `transcribeQueue`.
- [ ] В `transcribeQueue`: T1 → `ContextLexicon.candidates(limit: 8)` → `shouldRunSecondPass` → T2 с `contextWords` → `accept` → итог.
- [ ] В диагностику (`diagnostics?.record("context_refine", metadata:)`) — `candidates`, `secondPass`, `accepted`, `firstMs`, `secondMs`; в `kbLog` — те же числа, без слов.
- [ ] Выключенный переключатель — поведение байт-в-байт прежнее (нет сбора источников, нет второго прохода).
- [ ] Ветки Parakeet и запасной Whisper после Parakeet не меняются.

**Verify:** `bash scripts/typecheck-app.sh` → `PASS: typecheck`; все `scripts/test-context-lexicon.sh`, `test-whisper-prompt.sh`, `test-contextual-redecode.sh`, `test-personal-writing.sh` → `PASS`.

**Steps:**

- [ ] **Step 1:** `AppSettings.voiceContextRefine` (ключ `voiceContextRefine`, по умолчанию `true`) + переключатель «Уточнять по контексту» / «Refine with context» с подсказкой «Если в расшифровке есть слово, похожее на ваши частые слова, фраза распознаётся ещё раз с ними. Добавляет до секунды.» / англ. аналог.
- [ ] **Step 2:** проводка по Acceptance Criteria. Длительность T1 — `CFAbsoluteTimeGetCurrent()` вокруг первого `transcribe`.
- [ ] **Step 3:** `bash scripts/typecheck-app.sh` и четыре тестовых скрипта → успешно.
- [ ] **Step 4: Коммит.** `git commit -m "feat: refine whisper dictation with context second pass"`

---

### Task 6: Стенд — контекст в CLI и сравнение прогонов

**Goal:** прогон корпуса в режимах «как сейчас» и «слой A» на одинаковых детерминированных параметрах и отчёт сравнения.

**Files:**
- Modify: `Sources/Speakey/SpeechDiagnosticsExport.swift` (`SpeechCLIArguments`: `--context`, `--deterministic`)
- Modify: `Sources/Speakey/SpeechEvaluationCLI.swift`, `Sources/Speakey/WhisperBridge.swift` (флаг детерминизма: `temperature_inc = 0`)
- Modify: `Tools/SpeechEvaluation/runners.py` (`--context-dir`, `--deterministic`, `--split all`)
- Create: `Tools/SpeechEvaluation/context.py` (сборка контекста из манифеста)
- Modify: `Tools/SpeechEvaluation/evaluate.py` (команда `compare`, метрика редких слов)
- Test: `Tests/SpeechEvaluation/test_context.py`, `test_evaluate.py`, `test_runners.py`; `scripts/test-speech-diagnostics.sh`

**Acceptance Criteria:**
- [ ] `--context <file.json>` формата `{"sources":[{"kind":"corpus","words":{"DPR":3}}]}` включает слой A в CLI; в выходной JSON добавляются `context_candidates`, `second_pass`, `accepted`, `first_ms`, `second_ms`. Без `--context` вывод прежний.
- [ ] `--deterministic 1` ставит `temperature_inc = 0` и пишет это в конфигурацию отчёта.
- [ ] В CLI второй проход запускается при любых кандидатах (без бюджета), чтобы замер видел эффект; это отмечено в конфигурации отчёта.
- [ ] `context.py build <manifest> --output-dir <dir> [--corpus-vocabulary <json>]`: для каждой записи — эталоны до 3 предыдущих записей (по полю времени, если в манифесте есть; иначе по порядку внутри `session_id`) как `screen`, плюс словарь корпуса как `corpus`; сама запись не входит.
- [ ] `evaluate.py compare <baseline_report> <variant_report> --output <file>`: число лучше/хуже/без изменений, id ухудшившихся, ошибки по словам до/после, ошибки по редким словам (слова эталона, которых нет в `--common-words`, по умолчанию `Sources/Speakey/Resources/words_ru.json` + `words_en.json`).
- [ ] Тексты в консоль и логи не выводятся.

**Verify:** `python3 -m unittest discover -s Tests/SpeechEvaluation -v` → `OK`; `bash scripts/test-speech-diagnostics.sh` → все `PASS`; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.

**Steps:**

- [ ] **Step 1: Тесты Python** (синтетические данные во временных каталогах, как существующие): `test_context.py` — соседи не включают саму запись, не больше 3, не пересекают `session_id`; `test_evaluate.py` — `compare` на двух синтетических отчётах даёт верные `better/worse/same` и редкие слова; `test_runners.py` — `--context-dir` передаёт `--context` нужного файла в команду.
- [ ] **Step 2:** запуск → падают.
- [ ] **Step 3: Реализация** по Acceptance Criteria; разбор аргументов CLI расширить по образцу `--engine` (допустимо только для `transcribe` + `whisper`).
- [ ] **Step 4:** все три Verify-команды → успешно.
- [ ] **Step 5: Коммит.** `git commit -m "feat: measure contextual dictation in speech evaluation"`

---

### Task 7: Замер слоя A и отчёт

**Goal:** цифры по критериям готовности из спеки на личном корпусе Ники.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Личные: манифест и прогоны вне репозитория (`~/Library/Application Support/Speakey/speech-corrections` → экспорт в защищённый каталог), отчёт `~/reports/Speaky/2026-11-24-contextual-dictation.html` скилом `report`.

**Acceptance Criteria:**
- [ ] Прогоны baseline и слоя A на всех подтверждённых парах с аудио (`--split all --deterministic 1`) в двух вариантах контекста: «только корпус» и «корпус + соседние эталоны».
- [ ] В отчёте: WER до/после, ошибки по редким словам до/после, число лучше/хуже, p50/p95 `second_ms`, пометка «верхняя оценка» про контекст.
- [ ] Пример Ники: фраза надиктована Никой и подтверждена в окне проверки; прогон даёт `dpr` и `подборок` при контексте, где эти слова есть. Если Ника фразу не надиктовал — пункт помечен как незакрытый, не как пройденный.
- [ ] Рекомендация по слою B: нужен ли, по каким ошибкам, которые A не поймал.

**Verify:** `python3 Tools/SpeechEvaluation/evaluate.py compare <baseline> <variant> --output <file>` → отчёт с полями `better`, `worse`, `wer_before`, `wer_after`; html-отчёт открывается.

**Steps:**

- [ ] **Step 1:** экспорт подтверждённых пар в манифест (существующий `exportConfirmed` / README стенда), `context.py build`.
- [ ] **Step 2:** собрать проверочную сборку, прогнать `runners.py` baseline и с `--context-dir` для обоих вариантов.
- [ ] **Step 3:** `evaluate.py compare` для обоих вариантов.
- [ ] **Step 4:** попросить Нику надиктовать фразу-пример при открытом контексте с «DPR» и «подборки» и подтвердить её в окне проверки; прогнать.
- [ ] **Step 5:** отчёт скилом `report`, ссылка Нике.
