# Неявное подтверждение диктовок — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** неисправленные напечатанные диктовки через 12 часов сами становятся подтверждёнными парами «звук + эталон» с пометкой «неявно» и больше не удаляются.

**Architecture:** логика подтверждения и списка отказов — в `SpeechReviewStore` (тот же замок `SpeechDiagnostics.reviewLock`, то же шифрование). `SpeechDiagnosticsStore.prune` перестаёт трогать свежие неподтверждённые. Триггеры (старт, после сохранения примера, перед выгрузкой) — в `SpeechDiagnostics` и окне проверки. Стенд различает источник эталона.

**Tech Stack:** Swift 5 / AppKit, CryptoKit, тест-бинарники через `swiftc` (`scripts/test-speech-review.sh`, `scripts/test-speech-diagnostics.sh`), Python `unittest` для `Tools/SpeechEvaluation`.

**Spec:** `docs/superpowers/specs/2026-11-24-implicit-dictation-confirmation-design.md`

## Global Constraints

- Порог созревания — ровно 12 часов (`12 * 3600` с) от даты создания файла примера (`creationDate`, как в `SpeechReviewStore.load`).
- Подтверждается неявно только пример с `snapshot.outcome == "insertion_requested"` и непустым (после trim) текстом последнего события стадии `dictionary`.
- Эталон неявного = текст стадии `dictionary`; `editedText` = текст последнего события `output_options`, а если его нет — тот же `dictionary`; `silence = false`; `sessionID`/`split` — по правилам `saveConfirmed` (`recorded-<yyyy-MM-dd MSK>`, `dev`).
- Источник: `SpeechReviewCorrection.source` — `"explicit"` или `"implicit"`; файл без поля читается как `"explicit"`. Выгрузка: `reference_source` = `explicit_user_confirmation` | `implicit_unedited`.
- Явная правка всегда перезаписывает неявную. Любое удаление эталона из окна заносит id в список отказов; id из отказов никогда не подтверждается неявно.
- Неподтверждённые записи моложе 13 часов (`12 ч + 1 ч` запаса) не удаляются `prune` ни по возрасту, ни по потолку 200 и не учитываются в потолке.
- Подтверждение и `prune` выполняются под `SpeechDiagnostics.reviewLock`, подтверждение — раньше `prune`. Не на главном потоке.
- Сбор выключен или ключ недоступен — проход тихо пропускается; в лог только числа.
- Ни в лог, ни в консоль не попадает текст диктовок.
- Проверка сборки: `bash scripts/typecheck-app.sh` (`swift build` в проекте не работает). Swift-тесты пишут во временный каталог FileManager и в песочнице bash падают с Code=513 — запускать с отключённой песочницей.
- Комментарии по-русски в стиле файлов. Коммиты — английский Conventional Commits, без AI-атрибуции.

**User decisions (already made):**
- «я считаю верными [неоткрытые записи], потому что я читаю их, когда они печатаются» — неисправленное = верно (вариант B).
- «3 дня много, 12 часов» — порог 12 часов.
- Спека утверждена («да», 24.11.2026) вместе с решениями дизайнера 1–5.
- Потоковый режим в коде выключен навсегда (`AppSettings.voiceStreaming` всегда `false`), поэтому все диктовки создают пример — ограничение из спеки не действует.

## Review Focus

1. Пример с правкой, удалённой Никой, не должен через час «воскреснуть» неявным (тест в Task 1).
2. Явная правка, сохранённая после неявной, становится явной, и метка в окне меняется (тесты в Task 1 и Task 3).
3. Повреждённый или нечитаемый пример не должен валить весь проход: пропускается, остальные подтверждаются (тест в Task 1).
4. Десятки свежих диктовок за час при потолке 200 не удаляют созревающие (тест в Task 2).
5. Старые манифесты без `reference_source` фильтром «все» читаются как раньше (тест в Task 4).

---

### Task 1: Источник эталона, отказы и проход подтверждения

**Goal:** `SpeechReviewStore` умеет подтверждать созревшие неисправленные примеры неявно, помнит отказы и различает источник эталона.

**Files:**
- Modify: `Sources/Speakey/SpeechReviewStore.swift`
- Test: `Tests/SpeechReview/main.swift` (+ при необходимости `scripts/test-speech-review.sh`)

**Acceptance Criteria:**
- [ ] `SpeechReviewCorrection` имеет `var source: String = "explicit"`; декодирование старого JSON без поля даёт `"explicit"`.
- [ ] `saveConfirmed` пишет `source = "explicit"` и снимает id из отказов.
- [ ] `removeCorrection(id:)` добавляет id в отказы.
- [ ] `confirmMatured(now:minimumAge:) throws -> Int` подтверждает ровно подходящие примеры по Global Constraints и возвращает их число; повреждённый пример пропускается без исключения.
- [ ] `SpeechReviewItem` имеет `var source: String?` (nil — не подтверждён), `list()` его заполняет.
- [ ] `exportConfirmed` пишет `reference_source` по источнику.

**Verify:** `bash scripts/test-speech-review.sh` (без песочницы) → все проверки проходят, код 0.

**Steps:**

- [ ] **Step 1: Тесты** в `Tests/SpeechReview/main.swift` (стиль существующих `check(_, _)`, трассы через `SpeechDiagnosticTrace` + `record(stage:text:)`, дата создания через `setAttributes([.creationDate:])`):
  - `checkImplicitConfirmation`: вставленная (`outcome "insertion_requested"`, `dictionary` «текст диктовки», `output_options` «Текст диктовки.») 13 ч назад → `confirmMatured(now:, minimumAge: 12*3600) == 1`, эталон `"текст диктовки"`, `editedText` `"Текст диктовки."`, `source == "implicit"`; повторный проход → `0`.
  - моложе 12 ч → не подтверждается; `outcome "history_only"`, `"empty"`, `"secure_input_history_only"` → не подтверждаются; пустой `dictionary` → не подтверждается.
  - явная правка после неявной → `source == "explicit"`, эталон из правки.
  - `removeCorrection` неявной → следующий `confirmMatured` возвращает `0`, эталона нет; затем `saveConfirmed` → эталон есть, `source == "explicit"`.
  - JSON эталона без `source` (записать старым форматом) → `load(...).correction?.source == "explicit"`.
  - повреждённый `.enc` среди подходящих → проход не бросает, подходящие подтверждены.
  - выгрузка: явная строка `reference_source == "explicit_user_confirmation"`, неявная — `"implicit_unedited"`.
- [ ] **Step 2:** запуск → не компилируется / падает.
- [ ] **Step 3: Реализация.** Отказы — зашифрованный тем же ключом JSON-массив UUID в файле `speech-review-refusals.enc` в родительском каталоге `correctionsDirectory` (не внутри него: `records(in:)` читает только `UUID.enc`). Запись атомарно, права `0600`. Текст стадии — последнее событие с нужным `stage`.
- [ ] **Step 4:** тест → проходит; `bash scripts/typecheck-app.sh` → `PASS: typecheck`.
- [ ] **Step 5:** `git commit -m "feat: confirm unedited dictations implicitly"`

---

### Task 2: Не удалять созревающие примеры

**Goal:** `SpeechDiagnosticsStore.prune` не трогает неподтверждённые записи моложе 13 часов.

**Files:**
- Modify: `Sources/Speakey/SpeechDiagnostics.swift` (`prune`, ~:177)
- Test: `Tests/SpeechDiagnostics/main.swift`

**Acceptance Criteria:**
- [ ] `prune(now:maximumRecords:maximumAge:protectedAge:)` с `protectedAge` по умолчанию `13 * 3600`: записи с `modified` новее `now - protectedAge` не удаляются и не входят в счёт 200.
- [ ] Остальные неподтверждённые удаляются по прежним правилам; подтверждённые не трогаются.

**Verify:** `bash scripts/test-speech-diagnostics.sh` (без песочницы) → все `PASS`.

**Steps:**

- [ ] **Step 1: Тест:** 250 неподтверждённых записей с датами «сейчас − 1 мин…» и 10 записей возрастом 8 дней → после `prune(now:)` живы все 250 свежих, 8-дневные удалены; при `protectedAge: 0` поведение прежнее (остаётся 200 самых новых).
- [ ] **Step 2:** запуск → падает.
- [ ] **Step 3:** реализация; сигнатура с параметром по умолчанию, вызов в `save` без изменений.
- [ ] **Step 4:** тест → `PASS`; typecheck → `PASS: typecheck`.
- [ ] **Step 5:** `git commit -m "fix: keep maturing speech examples from pruning"`

---

### Task 3: Триггеры прохода и метка в окне

**Goal:** проход подтверждения запускается при старте, после сохранения примера (не чаще раза в час) и перед выгрузкой; окно показывает «верно (авто)».

**Files:**
- Modify: `Sources/Speakey/SpeechDiagnostics.swift` (`finish`, статическое состояние «последний проход»), `Sources/Speakey/AppDelegate.swift` (`applicationDidFinishLaunching`, ~:99), `Sources/Speakey/SpeechReviewWindow.swift` (бейдж ~:167, статус ~:229, выгрузка ~:388), `Sources/Speakey/L10n.swift`

**Acceptance Criteria:**
- [ ] `SpeechDiagnostics.confirmMaturedIfDue(now:force:)` — на `SpeechDiagnostics.queue`: если сбор выключен — выход; если с прошлого прохода < 1 ч и не `force` — выход; иначе `SpeechReviewStore.confirmMatured` (через `SpeechReviewWindowController.reviewStore()`-эквивалент без UI) и `kbLog`/`NSLog` только с числом подтверждённых или «ошибка» без текста.
- [ ] Вызывается: в конце `applicationDidFinishLaunching` (`force: true`), в `finish` после успешного `save` (без `force`), в окне перед `exportConfirmed` (`force: true`, выгрузка ждёт завершения).
- [ ] Бейдж строки: явная — «✓ сохранено» как сейчас; неявная — новая строка `review.badgeAuto` (ru «✓ верно (авто)», en «✓ correct (auto)»); статус документа для неявной — `review.savedAuto` (ru «Подтверждено автоматически: диктовку не исправляли 12 часов.», en «Confirmed automatically: not corrected within 12 hours.»).

**Verify:** `bash scripts/typecheck-app.sh` → `PASS: typecheck`; `bash scripts/test-speech-review.sh` и `bash scripts/test-speech-diagnostics.sh` (без песочницы) → проходят.

**Steps:**

- [ ] **Step 1:** реализация по Acceptance Criteria; троттлинг — время прошлого прохода в статическом свойстве под тем же `queue`.
- [ ] **Step 2:** typecheck и оба тестовых скрипта → успешно.
- [ ] **Step 3:** `git commit -m "feat: run implicit confirmation and label auto-confirmed examples"`

---

### Task 4: Стенд различает источник эталона

**Goal:** `runners.py` и `evaluate.py` фильтруют строки манифеста по `reference_source`; README предупреждает про неявные эталоны.

**Files:**
- Modify: `Tools/SpeechEvaluation/runners.py`, `Tools/SpeechEvaluation/evaluate.py`, `Tools/SpeechEvaluation/README.md`
- Test: `Tests/SpeechEvaluation/test_runners.py`, `Tests/SpeechEvaluation/test_evaluate.py`

**Acceptance Criteria:**
- [ ] Флаг `--reference-source {all,explicit,implicit}`, по умолчанию `all`, в `runners.py` и в `evaluate.py evaluate`; `explicit` = `explicit_user_confirmation` или отсутствие поля; `implicit` = `implicit_unedited`.
- [ ] Пустая выборка после фильтра → понятная ошибка, как для пустого split.
- [ ] README: абзац «Неявные эталоны — текст самой модели; ошибку на них стенд занижает; редкие термины и честную ошибку мерить с `--reference-source explicit`».

**Verify:** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/SpeechEvaluation -v` → `OK`.

**Steps:**

- [ ] **Step 1: Тесты:** манифест из трёх строк (явная, без поля, неявная) → `all` берёт 3, `explicit` 2, `implicit` 1; пустая выборка → ошибка.
- [ ] **Step 2:** запуск → падают.
- [ ] **Step 3:** реализация + README.
- [ ] **Step 4:** тесты → `OK`.
- [ ] **Step 5:** `git commit -m "feat: filter speech evaluation by reference source"`
