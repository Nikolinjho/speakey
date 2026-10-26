# Layout Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Делегирование допускается только при отдельной авторизации пользователя или применимого скила.

**Goal:** Добавить в собственную сборку Keyboop локальный журнал пропущенных и лишних переключений, подтверждение случаев и применение обратимых глобальных правил.

**Architecture:** Engine передаёт ограниченные наблюдения в независимый коррелятор. Только случаи с обратной связью сохраняются отдельным store. AppKit-окно позволяет разметить случаи, экспортировать примеры и явно изменить существующий ExceptionStore.

**Tech Stack:** Swift 5 compatibility mode, Foundation, AppKit, Carbon, Codable JSON, standalone swiftc test harnesses. Голосовые зависимости нужны только для полной сборки приложения.

---

## Статус и границы

План подготовлен 26.10.2026, MSK. Это документы для будущей реализации. Код установленного приложения не изменён. Базовый commit: `fb9bdde4eb8f13a486974cf102a8bec9d607e5d2`, тег `v0.4.10`. Репозиторий: `/Users/itsnikoko/tools/keyboop`, ветка документов: `docs/layout-diagnostics-plan`.

Спецификация: [2026-10-26-layout-diagnostics-design.md](../specs/2026-10-26-layout-diagnostics-design.md). Выбранный пользователем вариант – доработка Keyboop. Подробности интерфейса и лимиты ниже являются проектными допущениями плана, их можно скорректировать до реализации.

В первой версии нет дообучения нейросети, удалённого сервера, изменения диктовки или Apple Translation. Сбор молчания не позволяет узнать намерение пользователя. Автоматически найденная ручная правка создаёт candidate, а правило появляется только после отдельного действия пользователя.

## Проверенные точки интеграции

| Файл и функция | Назначение |
|---|---|
| `Engine.swift:1727`, `convertFromBuffer` | Обычная и ручная конверсия |
| `Engine.swift:2108`, `autoConversionProposal` | Решение boundary/enter, guards и soft-фильтр |
| `Engine.swift:2264`, `convertBeforeReturn` | Замена до Enter |
| `Engine.swift:1032`, `handlePauseFixMarker` | Синхронная правка после паузы |
| `Engine.swift:1111`, `tryInlineLiveFix` | Правка незавершённого слова в tap |
| `Engine.swift:1170`, `maybeLiveFix` | Асинхронный live-путь |
| `Engine.swift:429`, `applyPendingContextClear` | Потеря позиции ввода, включая soft reset |
| `UndoLearner.swift:155`, `noteManualConvert` | Точный U1, зависит от настройки обучения |
| `UndoLearner.swift:167`, `observe` | Точный U2, зависит от настройки обучения |
| `TextReplacer.swift:260`, `replace` | Асинхронная запись, completion вызывается и при отказе |
| `TextReplacer.swift:358`, `replaceInline` | Bool подтверждает отправку inline-замены |
| `ExceptionStore.swift` | ignored/learned/forceSwap, UserDefaults |
| `LayoutData.swift:36`, `dataURL` | Уже поддерживает KEYBOOP_DATA_DIR для CLI-стенда |

Номера строк относятся к исходному commit, при реализации ориентироваться на имена функций.

## Порядок выполнения и зависимости

`0` готовит тесты и сборку. `1` создаёт корреляцию, `2` хранение, `3` правила, `4` подключение Engine, `5` интерфейс, `6` сквозную проверку. Задача 4 начинается только после воспроизводимой полной сборки в задаче 0. Отсутствующие внешние артефакты фиксируются как препятствие, а не обходятся отключением голоса в пользовательской сборке.

Реализацию выполнять в отдельной рабочей ветке/worktree по using-git-worktrees. До начала проверить актуальные AGENTS.md. Поскольку запрос пользователя сейчас ограничен планом и memora, этот документ сам по себе не означает, что тесты или фича уже выполнены.

## Общие правила реализации

- Сначала тест, затем минимальная реализация, затем PASS и коммит соответствующей задачи. Каждый шаг с кодом выполняется на реальном production-компоненте, а не на его тестовой копии.
- Все новые Foundation-файлы лежат непосредственно в `Sources/Keyboop/`, существующий сборочный glob включит их автоматически.
- Локальное время интерфейса и отчёта – MSK. Сериализованные даты – ISO8601, монотонное uptime применяется только для связи событий в одном запуске.
- Нейтральные слова остаются в ограниченной оперативной памяти. Случаи, экспорт и глобальные правила имеют разные жизненные циклы.
- Проверочные JSON-значения ниже – конкретные входы будущих тестов, не доказательство существующих ошибок словаря.
- Секции Verify описывают команды, которые появятся и выполнятся в реализации. На момент подготовки плана этих новых скриптов нет.

## Task 0: Воспроизводимая база и стенды

**Goal:** Подготовить независимые от голосовых библиотек проверки и подтвердить возможность сборки собственного приложения до изменения Engine.

**Files:**
- `scripts/test-layout-diagnostics.sh`
- `Tests/LayoutDiagnostics/main.swift`
- `Tests/LayoutDiagnostics/TestSupport.swift`
- `scripts/test-layout-detector.sh`
- `Tests/LayoutDetector/main.swift`
- `Tests/LayoutDetector/baseline.json`
- `docs/development/layout-diagnostics-build.md`

**Acceptance Criteria:**
- [ ] Стенд детектора действительно компилирует LayoutDetector.swift, Keymap.swift, DynamicKeymap.swift, LayoutData.swift, ExtraWords.swift и ExceptionStore.swift из приложения.
- [ ] Baseline проверяет ghbdtn как convert(toCyrillic: true) и hello как keep с загруженными комплектными ресурсами.
- [ ] Пустой фильтр или неизвестное имя тестовой группы завершаются кодом 2, ошибка утверждения кодом 1, выполненные проверки кодом 0.
- [ ] Для whisper.cpp, FluidAudio и Sparkle записаны проверенные SHA/релизы, команды получения и сборки. Полная dev-сборка проходит либо задача остаётся pending с конкретным недостающим артефактом.
- [ ] Ни один скрипт не устанавливает приложение, не запускает event tap и не меняет системные настройки.

**Verify:** `bash scripts/test-layout-detector.sh baseline && bash scripts/test-layout-diagnostics.sh harness`

**Steps:**

- [ ] Создать CLI-стенд с `TestFailure: Error`, `expect(_ condition: @autoclosure () -> Bool, _ message: String) throws` и реестром `(suite, name, () throws -> Void)`. В `main.swift` фильтровать по первому аргументу, выполнять хотя бы один тест и печатать число PASS/FAIL. Весь код тестов и имена проверок – по-русски. Для теста самого стенда:

```swift
try expect(2 + 2 == 4, "Стенд выполняет утверждения")
```

- [ ] В `scripts/test-layout-diagnostics.sh` использовать `set -euo pipefail`, каталог через `mktemp -d`, `trap 'rm -rf "$build_dir"' EXIT`, корень через `cd` относительно скрипта. Компилировать только явно перечисленные Foundation-файлы `LayoutObservation.swift`, `LayoutFeedbackTracker.swift`, `LayoutJournalStore.swift`, `LayoutRuleService.swift`, добавляя их по мере появления задач. Тесты подбирать glob `Tests/LayoutDiagnostics/*Tests.swift`, `main.swift` перечислять отдельно. Не импортировать Engine/VoiceController и не создавать поддельные копии production-алгоритма.

- [ ] Стенд детектора компилировать этой командой с выводом в свой временный каталог:

```bash
swiftc -swift-version 5 \
  Sources/Keyboop/Keymap.swift \
  Sources/Keyboop/DynamicKeymap.swift \
  Sources/Keyboop/LayoutData.swift \
  Sources/Keyboop/ExtraWords.swift \
  Sources/Keyboop/ExceptionStore.swift \
  Sources/Keyboop/LayoutDetector.swift \
  Tests/LayoutDetector/main.swift \
  -framework Carbon -o "$build_dir/detector-tests"
KEYBOOP_DATA_DIR="$PWD/Sources/Keyboop/Resources" \
  "$build_dir/detector-tests" "${1:-all}"
```

- [ ] Сохранить baseline JSON и проверять `LayoutData.shared.isLoaded`, чтобы отсутствующие ресурсы не давали ложный PASS:

```json
[
  {"word":"ghbdtn","expected":"convert","toCyrillic":true},
  {"word":"hello","expected":"keep"}
]
```

- [ ] Для полных зависимостей использовать инструкции README, но не угадывать совместимые ревизии. Собрать whisper.cpp с deployment target macOS 14, получить FluidAudio static framework и Sparkle с доступных официальных источников. Зафиксировать реально использованные версии и команды в build-документе. Ожидаемые пути: `vendor/whisper.cpp/build-macos14`, `vendor/fluidaudio-prebuilt`, `vendor/sparkle/Sparkle.framework`. Если совместимого FluidAudio артефакта нет, остановить именно полную интеграцию и описать воспроизводимую причину.

- [ ] После подготовки vendor выполнить:

```bash
KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-baseline.app bash build-app.sh
codesign --verify --deep --strict /tmp/Keyboop-layout-baseline.app
```

Ожидается exit 0 у обеих команд. Результат не запускать и не копировать в `/Applications`. В этой задаче не использовать `install-local.sh`.

- [ ] Коммит: `test: add standalone layout diagnostic harnesses`.

```json:metadata
{
  "files": [
    "scripts/test-layout-diagnostics.sh",
    "Tests/LayoutDiagnostics/main.swift",
    "Tests/LayoutDiagnostics/TestSupport.swift",
    "scripts/test-layout-detector.sh",
    "Tests/LayoutDetector/main.swift",
    "Tests/LayoutDetector/baseline.json",
    "docs/development/layout-diagnostics-build.md"
  ],
  "acceptanceCriteria": [
    "Стенд детектора действительно компилирует LayoutDetector.swift, Keymap.swift, DynamicKeymap.swift, LayoutData.swift, ExtraWords.swift и ExceptionStore.swift из приложения.",
    "Baseline проверяет ghbdtn как convert(toCyrillic: true) и hello как keep с загруженными комплектными ресурсами.",
    "Пустой фильтр или неизвестное имя тестовой группы завершаются кодом 2, ошибка утверждения кодом 1, выполненные проверки кодом 0.",
    "Для whisper.cpp, FluidAudio и Sparkle записаны проверенные SHA/релизы, команды получения и сборки. Полная dev-сборка проходит либо задача остаётся pending с конкретным недостающим артефактом.",
    "Ни один скрипт не устанавливает приложение, не запускает event tap и не меняет системные настройки."
  ],
  "verifyCommand": "bash scripts/test-layout-detector.sh baseline && bash scripts/test-layout-diagnostics.sh harness",
  "userGate": false
}
```


## Task 1: Контракт наблюдений и независимый сбор обратной связи

**Goal:** Связать каждую ручную правку с конкретным решением на том же вхождении слова, без изменения поведения автопереключения.

**Files:**
- `Sources/Keyboop/LayoutObservation.swift`
- `Sources/Keyboop/LayoutFeedbackTracker.swift`
- `Tests/LayoutDiagnostics/TrackerTests.swift`

**Acceptance Criteria:**
- [ ] UUID вхождения, generation контекста, bundle id и монотонное время обязательны для корреляции.
- [ ] Ручная конверсия keep создаёт missedConversion, точный обратный флип отправленной замены создаёт unwantedConversion.
- [ ] Точное стирание и восстановление исходного слова в четыре секунды создаёт один unwantedConversion.
- [ ] Смена контекста, не тот occurrenceID, истёкшие четыре секунды, другое слово и неотправленная замена не создают ошибку.
- [ ] Сбор независим от learnOnUndoEnabled. Дубликат одного свидетельства не увеличивает число случаев.
- [ ] В памяти максимум 32 решения на десять секунд. Live-префикс помечен incomplete, без права на создание глобального правила.

**Verify:** `bash scripts/test-layout-diagnostics.sh tracker`

**Steps:**

- [ ] Ввести Codable/Equatable-типы `LayoutObservation`, `LayoutFeedback`, `LayoutCase`, `LayoutRuleReceipt` и enum для path, reason, action, submission, errorKind, reviewStatus. `submission` различает `notNeeded`, `pending`, `submitted`, `rejected`, `unknown`. Замену считать наблюдаемой только после submitted. Не называть это подтверждённым изменением текста на экране.

- [ ] Контракт Observation: `id: UUID`, `occurrenceID: UUID`, `contextID: UUID`, `bundleID: String`, `typed: String`, `proposed: String?`, `path: LayoutPath`, `reason: LayoutReason`, `action: LayoutAction`, `submission: LayoutSubmission`, `isCompleteWord: Bool`, `uptime: TimeInterval`, `recordedAt: Date`. UUID решения и UUID вхождения различаются: один токен может получить live- и boundary-решения. `LayoutFeedback` содержит id, observationID, observation, expected, kind, source (manualFlip/retype/explicit), createdAt. `LayoutCase` содержит id, typed, produced, expected, kind, bundleID, isCompleteWord, count, firstSeen, lastSeen, status (candidate/confirmed/rejected/resolved), evidence последних пяти feedback и связанные receipt IDs. `LayoutRuleReceipt` содержит before/written memberships для обеих сторон, status (pending/active/removed/conflict) и UUID. Все enum raw values фиксировать строками, не порядковыми Int.

- [ ] Контракт Tracker: `init(window: TimeInterval = 4, capacity: Int = 32, retention: TimeInterval = 10)`, `record(_:)`, `setSubmission(observationID: UUID, submitted: Bool)`, `manualConvert(occurrenceID: UUID, contextID: UUID, from: String, to: String, uptime: TimeInterval) -> LayoutFeedback?`, `observeRetyping(occurrenceID: UUID, contextID: UUID, current: String, uptime: TimeInterval) -> LayoutFeedback?`, `reset(contextID: UUID)`, `snapshot(uptime: TimeInterval) -> [LayoutObservation]`. Все аргументы времени передаются вызывающей стороной.

- [ ] Сначала написать и запустить таблицу тестов. Пример значений, которые должны пройти через реальные методы Tracker:

```json
[
  {"typed":"ghbdtn","action":"keep","manualFrom":"ghbdtn","manualTo":"привет","elapsed":1,"expected":"missedConversion"},
  {"typed":"hello","proposed":"руддщ","action":"replace","submission":"submitted","manualFrom":"руддщ","manualTo":"hello","elapsed":1,"expected":"unwantedConversion"},
  {"typed":"hello","proposed":"руддщ","action":"replace","submission":"rejected","manualFrom":"руддщ","manualTo":"hello","elapsed":1,"expected":null},
  {"typed":"ghbdtn","action":"keep","manualFrom":"ghbdtn","manualTo":"привет","elapsed":4.001,"expected":null}
]
```

Фиксированные UUID, contextID и монотонное время задаются тестом. При первом запуске ожидается ошибка компиляции из-за отсутствующих типов. После реализации – PASS.

- [ ] Реализовать U2 автоматом `fresh -> deleting -> retyping`: converted должен быть стёрт целиком, затем reconstructed должен точь-в-точь совпасть с original. Любое продолжение другим словом сбрасывает кандидата. Использовать сравнение lowercased для корреляции, сохраняя исходный регистр для интерфейса. Пробельные хвосты не входят в слово.

- [ ] После emitted feedback помечать observation consumed до callback в store. Поздний обратный флип после U2 и повторная доставка submission callback не создают второе свидетельство.

- [ ] Отдельно проверить 33 решения, очистку после десяти секунд, повтор одинакового слова с другим occurrenceID, `reset` между решением и исправлением, явное выключение сбора и live-кандидат. Молчание пользователя не генерирует ни success, ни error.

- [ ] Коммит: `feat: correlate layout decisions with user corrections`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutObservation.swift",
    "Sources/Keyboop/LayoutFeedbackTracker.swift",
    "Tests/LayoutDiagnostics/TrackerTests.swift"
  ],
  "acceptanceCriteria": [
    "UUID вхождения, generation контекста, bundle id и монотонное время обязательны для корреляции.",
    "Ручная конверсия keep создаёт missedConversion, точный обратный флип отправленной замены создаёт unwantedConversion.",
    "Точное стирание и восстановление исходного слова в четыре секунды создаёт один unwantedConversion.",
    "Смена контекста, не тот occurrenceID, истёкшие четыре секунды, другое слово и неотправленная замена не создают ошибку.",
    "Сбор независим от learnOnUndoEnabled. Дубликат одного свидетельства не увеличивает число случаев.",
    "В памяти максимум 32 решения на десять секунд. Live-префикс помечен incomplete, без права на создание глобального правила."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh tracker",
  "userGate": false
}
```


## Task 2: Локальное хранилище случаев

**Goal:** Сохранять только случаи с обратной связью, агрегировать повторы и переживать перезапуск и очистку без потери согласованности.

**Files:**
- `Sources/Keyboop/LayoutJournalStore.swift`
- `Tests/LayoutDiagnostics/JournalStoreTests.swift`

**Acceptance Criteria:**
- [ ] Нейтральные решения не попадают на диск. Ключ агрегации включает typed, expected, kind, bundleID и complete/incomplete.
- [ ] Повторное свидетельство с тем же observationID не увеличивает count. Разные expected остаются разными случаями.
- [ ] Сохраняются count, firstSeen, lastSeen, reviewStatus, последние пять свидетельств и версия схемы 1.
- [ ] После загрузки сохраняются лимиты 2000 случаев, 30 дней, 20 MiB, 128 символов на слово.
- [ ] Каталог имеет 0700, файл 0600. Повреждённый файл сохраняется как corrupt, ошибка доступна UI.
- [ ] Очистка не позволяет отложенной операции предыдущей эпохи восстановить удалённые данные.

**Verify:** `bash scripts/test-layout-diagnostics.sh store`

**Steps:**

- [ ] Определить API `LayoutJournalStore.init(directory: URL, now: @escaping () -> Date)`, `record(_ feedback: LayoutFeedback, completion: @escaping (Result<Void, Error>) -> Void)`, `snapshot(completion:)`, `prepareRule(_ receipt: LayoutRuleReceipt, completion:)`, `activateRule(id: UUID, completion:)`, `removeRule(id: UUID, completion:)`, `review(caseID: UUID, expected: String, status: LayoutReviewStatus, completion:)`, `clear(completion:)`, `export(to: URL, confirmedOnly: Bool, completion:)`. Все публичные callback возвращать на main, внутренние изменения выполнять на одной serial queue. Для тестов предоставить `flush(completion:)`, который идёт через ту же очередь. Для main-callback тестовый runner прокачивает RunLoop с ограниченным deadline, не блокирует main через semaphore/DispatchGroup.wait. Контракт snapshot возвращает cases, receipts, prunedCount и ошибку последней загрузки.

- [ ] Сначала написать тест с каталогом из `FileManager.default.temporaryDirectory`, фиксированным `now` и очисткой в defer. Последовательность: record двух feedback с разными observationID и одним ключом, flush, пересоздание store, snapshot. Ожидаются один case и count=2. Затем повторить один observationID: count остаётся 2.

- [ ] Хранить JSON-конверт следующей формы. Кодировать типы через JSONEncoder, даты ISO8601, писать атомарно. `observedDecisions` намеренно отсутствует:

```json
{
  "schemaVersion":1,
  "cases":[],
  "rules":[],
  "prunedCount":0
}
```

- [ ] Путь вычислять из bundle identifier в адаптере приложения, а не внутри тестируемого store. В тесте всегда передавать временный каталог. Не использовать UserDefaults или `Library/Logs` для содержимого слов.

- [ ] Перед каждой записью удалять просроченные случаи и обрезать по числу и сериализованному размеру. Приоритет удаления: старые resolved/rejected, затем остальные по lastSeen. Увеличивать `prunedCount`. Ограничения учитывать и при загрузке старого файла. Нельзя молча обрезать слово и создавать другое правило: слишком длинное слово отклонять с видимой причиной.

- [ ] Очередь захватывает generation операции. `clear` увеличивает generation, очищает in-memory snapshot и удаляет журнал. Любые старые callbacks/отложенные flush с предыдущей generation игнорируются. Новое событие после clear создаёт новый файл с текущей generation. Это проверить управляемым порядком операций, без `sleep`.

- [ ] Тесты отказов: truncated JSON, неизвестная версия схемы, каталог недоступен для записи, экспорт по отменённому выбору пути, превышение лимитов. Исходную ошибку показывать через Result. В стандартный лог писать только код ошибки и счётчик, без слов.

- [ ] Коммит: `feat: persist local layout correction cases`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutJournalStore.swift",
    "Tests/LayoutDiagnostics/JournalStoreTests.swift"
  ],
  "acceptanceCriteria": [
    "Нейтральные решения не попадают на диск. Ключ агрегации включает typed, expected, kind, bundleID и complete/incomplete.",
    "Повторное свидетельство с тем же observationID не увеличивает count. Разные expected остаются разными случаями.",
    "Сохраняются count, firstSeen, lastSeen, reviewStatus, последние пять свидетельств и версия схемы 1.",
    "После загрузки сохраняются лимиты 2000 случаев, 30 дней, 20 MiB, 128 символов на слово.",
    "Каталог имеет 0700, файл 0600. Повреждённый файл сохраняется как corrupt, ошибка доступна UI.",
    "Очистка не позволяет отложенной операции предыдущей эпохи восстановить удалённые данные."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh store",
  "userGate": false
}
```


## Task 3: Правила на основе подтверждённых случаев

**Goal:** Применять и обратимо удалять глобальные keep/force правила через существующие наборы ExceptionStore.

**Files:**
- `Sources/Keyboop/LayoutRuleService.swift`
- `Sources/Keyboop/LayoutRuleBackend.swift`
- `Sources/Keyboop/ExceptionStore.swift`
- `Tests/LayoutDiagnostics/RuleServiceTests.swift`
- `Tests/LayoutDetector/main.swift`
- `Tests/LayoutDetector/rules.json`

**Acceptance Criteria:**
- [ ] Неподтверждённый случай, незавершённый префикс и блокировка вне детектора не могут создать правило.
- [ ] Force хранит expected в forceSwap и очищает блокирующие наборы typed. Keep добавляет typed в ignored. Порядок детектора не меняется.
- [ ] Для повторного применения одного правила не теряется исходный снимок наборов обеих сторон пары typed/expected.
- [ ] Удаление восстанавливает исходные наборы только если текущее состояние совпадает с последним записанным сервисом.
- [ ] Реальный LayoutDetector демонстрирует изменение поведения и его возврат после удаления правила.
- [ ] Данные тестов пишутся только в уникальный UserDefaults suite.

**Verify:** `bash scripts/test-layout-diagnostics.sh rules && bash scripts/test-layout-detector.sh rules`

**Steps:**

- [ ] В ExceptionStore добавить внедрение UserDefaults без изменения singleton-контракта:

```swift
static let shared = ExceptionStore()
private let d: UserDefaults
```

Существующий инициализатор заменить на `init(defaults: UserDefaults = .standard)`, первой строкой присвоить `d = defaults`, остальные загрузки оставить. Добавить `removeIgnored(_:)` рядом с `removeForceSwap(_:)`. Для восстановления отдельного слова не использовать `setIgnored` всего массива. В интеграционном стенде сначала воспроизвести установленную семантику forceSwap на паре hello/руддщ и только затем проверять сервис.

- [ ] В Foundation-файле объявить `LayoutRuleBackend` с `membership(of: String) -> LayoutRuleMembership` и `setMembership(_ membership: LayoutRuleMembership, for word: String)`. Membership содержит три Bool: ignored, learned, forceSwap. В отдельном AppKit-независимом адаптере `ExceptionLayoutRuleBackend` работать с переданным ExceptionStore. Этот адаптер не включать в чистый harness.

- [ ] У сервиса API `apply(case: LayoutCase, action: LayoutRuleAction, backend: LayoutRuleBackend) throws -> LayoutRuleReceipt` и `remove(receipt: LayoutRuleReceipt, backend: LayoutRuleBackend) throws`. Receipt содержит UUID, sourceCaseID, typed, expected, before, written, createdAt. `before` и `written` – словари `[String: LayoutRuleMembership]` для обеих нормализованных сторон пары. Для keep у typed устанавливать ignored=true, forceSwap=false, сохраняя learned. Для force очистить ignored/learned/forceSwap у typed и записать expected в forceSwap, убрав у expected ignored/learned. Это соответствует реальному детектору: `forceSwap.contains(swapped)` даёт convert, `forceSwap.contains(w)` даёт keep. Нельзя записывать typed в forceSwap для принудительного переключения самого typed. Перед применением проверить, что `Keymap.convert(typed, toCyrillic:)` соответствует expected с учётом существующего smartConvert и регистрового контракта. Произвольная текстовая замена не является правилом раскладки.

- [ ] Тесты писать с in-memory backend, но интеграционный стенд обязан вызывать реальный ExceptionStore и LayoutDetector. Тестовые входы:

```json
[
  {"word":"ghbdtn","rule":"keep","expected":"keep"},
  {"word":"hello","target":"руддщ","rule":"force","expected":"convert","toCyrillic":true}
]
```

Не считать эти слова реальными пользовательскими ошибками. Это искусственные проверки влияния правил. Изолированный suite имеет имя `Keyboop.LayoutDiagnostics.Tests.<UUID>`, в defer вызывается `removePersistentDomain(forName:)`.

- [ ] Для каждого правила проверить baseline, применение, фактическое решение и возврат baseline после удаления. Отдельно learned=true + force: без снятия learned тест обязан краснеть. Добавить внешний конфликт: после apply изменить membership вручную, remove должен вернуть conflict и сохранить внешнее изменение.

- [ ] Согласовать запись receipt с изменением ExceptionStore: store сохраняет pending receipt до изменения backend и active receipt после него. На старте при pending receipt сравнить membership обеих сторон с before и written. При полном written завершить activation, при полном before отменить pending, при частичном или внешнем изменении показать конфликт. Перед remove сравнить все ключи, только затем менять любой из них. Не пытаться считать два независимых файла одной атомарной транзакцией.

- [ ] Проверить liveDecide для keep-префикса. Для force не добавлять принудительное исправление частичного слова на live-пути. Предоставить однозначную ошибку для попытки применить правило из incomplete-кандидата.

- [ ] Коммит: `feat: apply reviewed layout rules with rollback`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutRuleService.swift",
    "Sources/Keyboop/LayoutRuleBackend.swift",
    "Sources/Keyboop/ExceptionStore.swift",
    "Tests/LayoutDiagnostics/RuleServiceTests.swift",
    "Tests/LayoutDetector/main.swift",
    "Tests/LayoutDetector/rules.json"
  ],
  "acceptanceCriteria": [
    "Неподтверждённый случай, незавершённый префикс и блокировка вне детектора не могут создать правило.",
    "Force хранит expected в forceSwap и очищает блокирующие наборы typed. Keep добавляет typed в ignored. Порядок детектора не меняется.",
    "Для повторного применения одного правила не теряется исходный снимок наборов обеих сторон пары typed/expected.",
    "Удаление восстанавливает исходные наборы только если текущее состояние совпадает с последним записанным сервисом.",
    "Реальный LayoutDetector демонстрирует изменение поведения и его возврат после удаления правила.",
    "Данные тестов пишутся только в уникальный UserDefaults suite."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh rules && bash scripts/test-layout-detector.sh rules",
  "userGate": false
}
```


## Task 4: Подключение к реальному вводу

**Goal:** Снимать решения boundary, Enter и live-путей и доставлять обратную связь, сохраняя текущую обработку клавиатуры.

**Files:**
- `Sources/Keyboop/LayoutDiagnosticsController.swift`
- `Sources/Keyboop/Engine.swift`
- `Sources/Keyboop/KeystrokeBuffer.swift`
- `Sources/Keyboop/TextReplacer.swift`
- `Sources/Keyboop/AppSettings.swift`
- `Tests/LayoutDiagnostics/ControllerTests.swift`

**Acceptance Criteria:**
- [ ] Каждое вхождение получает UUID, который сохраняется при автоматической/ручной замене и меняется на новом слове.
- [ ] boundary, enter-pre, inline-live, pause-live и обычный live имеют отдельные path и используют одну схему событий.
- [ ] Генерация контекста меняется при реальной потере позиции ввода, включая запоздалый soft reset, смену приложения и Secure Input.
- [ ] Синтетические события и чужие/устаревшие callbacks не создают новый ввод или кандидата.
- [ ] Синхронно в event tap не выполняются JSON-кодирование, файловые операции, ожидание очереди, запросы Accessibility или обновление UI.
- [ ] Обычное completion TextReplacer не используется как доказательство отправки замены.
- [ ] При выключенном сборе правила продолжают работать через существующий детектор, журнал не принимает новые слова.

**Verify:** `bash scripts/test-layout-diagnostics.sh controller && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh`

**Steps:**

- [ ] В KeystrokeBuffer добавить `currentOccurrenceID` и `lastOccurrenceID`. Создавать новый ID только при начале нового токена. `boundary` переносит текущий ID к завершённому слову, `applyConversion` и `applyCompletedConversion` сохраняют ID. `clear` сбрасывает оба. При удалении до пустого слова держать ID до решения коррелятора U2, новый независимый ввод начинает новую occurrence после reset/потери кандидата. Нельзя выводить идентичность по строке или позиции в массиве.

- [ ] Controller владеет tracker и передаёт feedback в store. Инструментировать Engine после уже существующих safety guards. В `autoConversionProposal` записывать ровно то решение, которое уже вычислено, без повторного вызова LayoutDetector и без второго чтения `caretJumpedSinceClear`. Отмечать перечисленные причины на фактических выходах. Для общих guard вне proposal записывать blocked-решение только после существующей проверки безопасности ввода.

- [ ] В `convertFromBuffer(manual:)` после успешного планирования ручной замены вызвать manualConvert со снимком occurrenceID, contextID, word и converted. При авто keep зарегистрировать решение до `fixTwoLeadingCaps/fixTypo`, но отдельно инвалидировать кандидата, если эти функции изменили слово. Правки регистра и опечаток не считать ошибками раскладки.

- [ ] Ввести у `TextReplacer.replace` необязательный параметр `onSubmission: ((Bool) -> Void)? = nil` перед completion. Сигнатура существующих вызовов и trailing completion остаются совместимыми. В `replaceInOwnField` вернуть true после успешной замены, на отказе SecureInput/создания CGEvent вернуть false, после реальной отправки последовательности вернуть true. Гарантировать ровно один callback на каждую принятую операцию. Дополнительно проверить возвраты внутри тела replace, чтобы ранний выход не оставил pending навечно. Callback несёт захваченный observationID, completion по-прежнему отвечает за снятие muted.

- [ ] Inline-замена уже возвращает Bool: использовать именно её успешный результат. В `handlePauseFixMarker`, `tryInlineLiveFix` и `maybeLiveFix` собирать ограниченное событие в памяти на фактическом успешном пути. Не добавлять DispatchQueue.main.async на каждую букву. Не делать live-предположение полным словом: incomplete остаётся incomplete до доказанного завершения.

- [ ] Сбор U2 подключить в местах, где Engine сейчас вызывает `UndoLearner.observe`, но независимо от его return и enabled. Передавать буфер после обработки Backspace/печатного символа. U1 подключить рядом с `noteManualConvert`. Не использовать `UndoLearner` как единственный источник: при learnOnUndoEnabled=false и declined-словах он не выдаёт сигнал.

- [ ] Сохранять исходный UndoLearner, его баннеры и sessionProtected. Журнал не показывает новый баннер на каждый кандидат и не добавляет слово в learned сам. Если старый баннер уже создал исключение, UI показывает текущее membership и предлагает использовать существующее правило.

- [ ] При выключении сбора, Secure Input, pause, навигации, смене frontApp и полном/soft context reset сбрасывать tracker и contextID. Проверить все `buffer.clear` и `UndoLearner.resetContext` в Engine, а не только `applyPendingContextClear`. Callback предыдущего контекста не должен повторно привязать слово. Снимок для UI замораживать отдельно перед открытием собственного окна.

- [ ] Проверки Controller используют внедряемый sink и fake submission callback. Сценарии: ручная замена до позднего submission, rejected submission, двойной callback, смена contextID до callback, clear и выключение между record и callback, learning выключен. Сначала получить FAIL, затем PASS. Полная сборка обязательна после смены TextReplacer, так как стенд не компилирует весь AppKit-код.

- [ ] Коммит: `feat: capture layout feedback from engine paths`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutDiagnosticsController.swift",
    "Sources/Keyboop/Engine.swift",
    "Sources/Keyboop/KeystrokeBuffer.swift",
    "Sources/Keyboop/TextReplacer.swift",
    "Sources/Keyboop/AppSettings.swift",
    "Tests/LayoutDiagnostics/ControllerTests.swift"
  ],
  "acceptanceCriteria": [
    "Каждое вхождение получает UUID, который сохраняется при автоматической/ручной замене и меняется на новом слове.",
    "boundary, enter-pre, inline-live, pause-live и обычный live имеют отдельные path и используют одну схему событий.",
    "Генерация контекста меняется при реальной потере позиции ввода, включая запоздалый soft reset, смену приложения и Secure Input.",
    "Синтетические события и чужие/устаревшие callbacks не создают новый ввод или кандидата.",
    "Синхронно в event tap не выполняются JSON-кодирование, файловые операции, ожидание очереди, запросы Accessibility или обновление UI.",
    "Обычное completion TextReplacer не используется как доказательство отправки замены.",
    "При выключенном сборе правила продолжают работать через существующий детектор, журнал не принимает новые слова."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh controller && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh",
  "userGate": false
}
```


## Task 5: Окно журнала, ручная разметка и экспорт

**Goal:** Дать пользователю просмотреть кандидатов, подтвердить ожидаемый результат и осознанно применить правило.

**Files:**
- `Sources/Keyboop/LayoutJournalWindow.swift`
- `Sources/Keyboop/LayoutJournalPresenter.swift`
- `Sources/Keyboop/MenuBarController.swift`
- `Sources/Keyboop/AppDelegate.swift`
- `Sources/Keyboop/L10n.swift`
- `Tests/LayoutDiagnostics/PresenterTests.swift`

**Acceptance Criteria:**
- [ ] Меню «Журнал раскладки…» открывает отдельное окно и показывает состояние сбора.
- [ ] Есть фильтры по типу ошибки, приложению и статусу, сортировка по повторениям и времени.
- [ ] Ручная разметка использует замороженный снимок решений исходного приложения, а не ввод в самом журнале.
- [ ] Подтверждение случая не меняет детектор. Применение глобального правила – отдельное действие.
- [ ] Нельзя применить правило из incomplete или blocked-кандидата. При противоречии UI показывает оба случая.
- [ ] Экспорт JSON содержит schemaVersion и выбранные cases. Отмена NSSavePanel не создаёт файла.
- [ ] Очистка журнала сохраняет применённые правила. Удаление правила отдельно проверяет конфликт.

**Verify:** `bash scripts/test-layout-diagnostics.sh presenter && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh`

**Steps:**

- [ ] В Foundation Presenter вынести фильтрацию, сортировку и вычисление доступных действий, чтобы тестировать поведение без AppKit. API `rows(cases: [LayoutCase], filter: LayoutCaseFilter, sort: LayoutCaseSort) -> [LayoutCase]` и `allowedActions(for: LayoutCase) -> Set<LayoutJournalAction>`. Подтверждённый complete-кандидат с detectorKeep/Convert допускает правило, blocked и incomplete – только разметку/экспорт/отклонение.

- [ ] Написать тестовые примеры: одинаковый typed с двумя expected не схлопывается, сортировка count убывает с устойчивым lastSeen/id tie-breaker, фильтр не теряет applied-случай, candidate после review остаётся без активного receipt до отдельного apply. Ожидается FAIL до реализации Presenter и PASS после.

- [ ] Создать отдельное окно на AppKit по образцу жизненного цикла `VoiceHistoryWindowController`: один экземпляр, повторное открытие активирует существующее окно. Использовать простую таблицу и панель деталей. Колонки: исходное, результат Keyboop, ожидаемое, приложение, повторения, статус. В деталях – причина уровня Engine, путь и отправлена ли замена. Время показывать в MSK.

- [ ] Меню вызывает `onShowLayoutJournal`. В `menuNeedsUpdate` сохранить последние наблюдения до смены приложения. В AppDelegate связать callback с Controller snapshot и window controller. Во вкладке «Последние решения» позволить выбрать конкретное вхождение, задать expected и сохранить explicit feedback. После TTL не угадывать связь: создать отдельный manual case с введёнными пользователем typed/expected, без выдуманного пути выполнения.

- [ ] Отдельные действия: «Подтвердить случай», «Отклонить», «Всегда оставлять глобально», «Всегда переключать глобально», «Удалить правило», «Очистить журнал», «Экспортировать JSON», «Экспортировать подтверждённые примеры». Для глобального правила показать исходное слово и область «во всех приложениях, где включено автопереключение». После ошибки сохранения не показывать успешный тост.

- [ ] Переключатель сбора хранить в AppSettings под новым ключом `layoutJournalEnabled`, default=false. При его смене немедленно обновлять Controller. Добавить локализации ru/en в существующий L10n. Пояснения интерфейса описывают действия пользователя, не классы и не внутреннюю архитектуру.

- [ ] Экспорт через NSSavePanel не копирует содержимое в clipboard и не отправляет в FeedbackAttachmentCore. Сначала получить URL, только затем вызвать store.export. Ошибки доступа, corrupt-файл и `prunedCount` показывать в окне. Подтверждённый export не должен молча включать rejected и incomplete.

- [ ] Коммит: `feat: add layout journal review and export window`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutJournalWindow.swift",
    "Sources/Keyboop/LayoutJournalPresenter.swift",
    "Sources/Keyboop/MenuBarController.swift",
    "Sources/Keyboop/AppDelegate.swift",
    "Sources/Keyboop/L10n.swift",
    "Tests/LayoutDiagnostics/PresenterTests.swift"
  ],
  "acceptanceCriteria": [
    "Меню «Журнал раскладки…» открывает отдельное окно и показывает состояние сбора.",
    "Есть фильтры по типу ошибки, приложению и статусу, сортировка по повторениям и времени.",
    "Ручная разметка использует замороженный снимок решений исходного приложения, а не ввод в самом журнале.",
    "Подтверждение случая не меняет детектор. Применение глобального правила – отдельное действие.",
    "Нельзя применить правило из incomplete или blocked-кандидата. При противоречии UI показывает оба случая.",
    "Экспорт JSON содержит schemaVersion и выбранные cases. Отмена NSSavePanel не создаёт файла.",
    "Очистка журнала сохраняет применённые правила. Удаление правила отдельно проверяет конфликт."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh presenter && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh",
  "userGate": false
}
```


## Task 6: Регрессионные примеры и проверка собственной сборки

**Goal:** Подтвердить полный путь от намеренного промаха до сохранения случая и изменения поведения на воспроизводимых примерах.

**Files:**
- `Tests/LayoutDetector/reviewed-cases.json`
- `scripts/test-layout-detector.sh`
- `Tests/LayoutDetector/main.swift`
- `docs/development/layout-diagnostics-verification.md`
- `build-app.sh`

**Acceptance Criteria:**
- [ ] Все чистые стенды проходят с ненулевым числом проверок, кодом 0 и сохранённым stdout.
- [ ] На реальном детекторе проверены before/apply/remove с изолированным suite и комплектными ресурсами.
- [ ] Dev-сборка имеет отдельный bundle id, журнал и настройки, не устанавливается поверх официальной.
- [ ] Обновление собственной сборки не заменяет её официальным релизом: автоматические и ручные Sparkle-обновления отключены для этой dev-сборки.
- [ ] В документе отдельно указаны выполненные проверки, команда, код возврата и оставшиеся ограничения. Плановые команды не выдаются за выполненные.
- [ ] Ручной сценарий подтверждает сохранение после перезапуска, работу правил и отсутствие двойного event tap.

**Verify:** `bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh && codesign --verify --deep --strict /tmp/Keyboop-layout-diagnostics.app`

**Steps:**

- [ ] В runner добавить чтение `reviewed-cases.json`: каждый пример содержит typed, expectedAction, optional toCyrillic, previousWord и источник explicit/confirmed. Результат детектора проверять до и после применённого правила. Для неохваченной ошибки добавлять тест, исправление делать отдельным минимальным изменением и снова запускать baseline. Не добавлять все наблюдения в ExtraWords автоматически.

- [ ] Для собственной сборки сохранить штатный `.dev` bundle id либо отдельный `.layoutdev`, если `.dev` уже используется. Изменения Info.plist выполнять в сборочном скрипте до codesign. Отключить не только `SUEnableAutomaticChecks`, но и запуск Sparkle updater в AppDelegate/UpdaterController для этой сборки, чтобы ручная кнопка тоже не затирала доработку официальным релизом. Официальный release-путь не менять.

- [ ] Выполнить все команды Verify и сохранить результаты в verification-документе. Не запускать корневой `swift test` как замену полной сборке: публичный Package.swift не описывает все нативные зависимости. Не ссылаться на отсутствующие внутренние `Tools/run-*` или `stands/*`.

- [ ] Перед ручным тестом сверить запущенные процессы, остановить только явно выбранный официальный экземпляр штатным Quit, после чего запустить dev-сборку. Не выдавать права Accessibility автоматически. Если macOS запросит разрешение, пользователь включает его в системных настройках. До этого автоматические core/детектор-проверки и сборка должны быть закончены.

- [ ] В TextEdit на тестовых строках проверить Space/Enter/Tab и live. Для детерминированного missed-сценария временно добавить `ghbdtn` в ignored только dev-настроек, набрать его и вручную сконвертировать. Для unwanted временно добавить `руддщ` в forceSwap и сконвертировать `hello`, затем вернуть его хоткеем. Сохранить исходное membership и восстановить после теста.

- [ ] Проверить четыре состояния отдельно: появился candidate, review сохранил expected без изменения поведения, apply изменил детектор, remove вернул исходное поведение. Перезапустить dev и сверить count/status/receipt. Повторить U2, смену приложения в пределах окна и rejected submission. Cmd+Z отмечать вручную, не заявлять автоматическую поддержку.

- [ ] Очистить журнал при очереди записей, выключить и включить сбор, открыть защищённое поле и проверить, что новых слов оттуда нет. Проверить формат/права файлов и экспорт. Сравнить задержку ввода с диагностикой off/on на одинаковом локальном сценарии: в event tap нет дополнительного I/O, dropped events=0. Снять фактические median/p95, не назначать неподтверждённую цифру ускорения или задержки.

- [ ] Закрыть dev после проверки и вернуть официальный экземпляр, если он работал до теста. Постоянный переход на собственную сборку – отдельное решение пользователя после просмотра результата. Коммит: `test: verify layout journal and reviewed rule behavior`.

```json:metadata
{
  "files": [
    "Tests/LayoutDetector/reviewed-cases.json",
    "scripts/test-layout-detector.sh",
    "Tests/LayoutDetector/main.swift",
    "docs/development/layout-diagnostics-verification.md",
    "build-app.sh"
  ],
  "acceptanceCriteria": [
    "Все чистые стенды проходят с ненулевым числом проверок, кодом 0 и сохранённым stdout.",
    "На реальном детекторе проверены before/apply/remove с изолированным suite и комплектными ресурсами.",
    "Dev-сборка имеет отдельный bundle id, журнал и настройки, не устанавливается поверх официальной.",
    "Обновление собственной сборки не заменяет её официальным релизом: автоматические и ручные Sparkle-обновления отключены для этой dev-сборки.",
    "В документе отдельно указаны выполненные проверки, команда, код возврата и оставшиеся ограничения. Плановые команды не выдаются за выполненные.",
    "Ручной сценарий подтверждает сохранение после перезапуска, работу правил и отсутствие двойного event tap."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh && codesign --verify --deep --strict /tmp/Keyboop-layout-diagnostics.app",
  "userGate": false
}
```


## Самопроверка плана

- Сбор обоих типов ошибок: задачи 1 и 4.
- Независимость от существующего обучения и учёт live/Enter: задача 4.
- Восстановление после перезапуска и ограничение накопления: задача 2.
- Разметка, ручное добавление и экспорт: задача 5.
- Изменение поведения только по явному действию и откат правил: задача 3.
- Реальные регрессионные примеры: задачи 0, 3 и 6.
- Сборочные зависимости и собственная dev-сборка: задачи 0 и 6.
- В первой версии причины ограничены уровнем Engine. Подробный trace всех 58 выходов LayoutDetector не обещан.
- Противоречия, неполные слова и блокирующие режимы не превращаются в глобальные правила автоматически.
- Задачи не маркируются userGate: пользователь заказал план и память, отдельных обязательных приёмочных барьеров не задавал. Обычные проверки входят в критерии каждой задачи.

## Продолжение

Состояние задач хранится рядом в `2026-10-26-layout-diagnostics.md.tasks.json`. Для продолжения прочитать спецификацию и этот план, затем использовать `superpowers-extended-cc:executing-plans`. Перед исполнением пользователь выбирает запуск реализации. Если выбирается отдельная сессия, передать ей абсолютный путь плана и рабочий каталог.
