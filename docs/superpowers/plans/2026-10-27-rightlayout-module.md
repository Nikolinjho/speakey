# RightLayout Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в Keyboop локальную модель RightLayout с наблюдением по умолчанию и отдельно включаемой помощью при переключении раскладки.

**Architecture:** Core ML работает на фоновой serial-очереди, получает неизменяемые снимки ввода и возвращает оценки. Политика допуска сохраняет запреты Keyboop. Замены выполняются только из event tap через существующий TextReplacer после повторной проверки идентичности снимка.

**Tech Stack:** Swift 5 language mode, macOS 13+, Core ML, AppKit, CGEventTap, существующие CLI-наборы Swift. Новых runtime-фреймворков и Python-процесса в приложении нет.

---

## Согласованный объём

Дизайн `docs/superpowers/specs/2026-10-27-rightlayout-module-design.md` согласован Никой в текущем диалоге. Выбран предложенный режим: наблюдение по умолчанию и отдельно включаемая помощь после проверки качества. Адаптер персонального обучения и дообучение основных весов не входят в эту реализацию.

Рабочее дерево `/Users/itsnikoko/keybop local`, исходный код `bf72b73`, дизайн `2a6d57a`, ветка `feat/layout-diagnostics`. Перед выполнением проверить текущий HEAD и локальные изменения. При необходимости изоляции использовать using-git-worktrees во время начала реализации, а не переносить исходники вручную. Сборки направлять в `/private/tmp`. План не включает установку, обновление DMG или изменения /Applications.

Native TaskList/TaskCreate в этой среде отсутствуют. Источник задач и зависимостей: соседний `2026-10-27-rightlayout-module.md.tasks.json`. Все задачи pending. Доступ к субагентам выбирается при запуске выполнения, план сам по себе их не запускает.

## Порядок и проверяемые результаты

| Задача | Результат | Зависит от |
| --- | --- | --- |
| 1 | Ресурс с SHA, лицензией и bundle-доставкой | Нет |
| 2 | Проверенный Core ML backend | 1 |
| 3 | Ограниченная очередь и freshness | 2 |
| 4 | Чистая политика допуска | 2 |
| 5 | Журнал и позднее обогащение | 2, 4 |
| 6 | Наблюдение в Engine | 3, 4, 5 |
| 7 | Оценочный набор и профиль | 4, 6 |
| 8 | Управляемые автозамены | 3, 4, 6, 7 |
| 9 | Настройки и native UI | 5, 6, 7, 8 |
| 10 | Производительность, сборка и отчёт | 1–9 |

Если готовые веса не пройдут проверку качества, итоговый модуль всё равно поставляется в наблюдении. Нельзя ослаблять критерии или менять holdout для искусственного включения помощи. Отсутствие обучения в первой версии показывается честно.

## Общие правила исполнения

Для каждой задачи сначала добавить указанные содержательные тесты и сохранить RED, затем реализовать и сохранить GREEN. Комментарии и названия проверок русские, коммиты английские Conventional Commits. Модель и пользовательские тексты не печатать в обычный системный лог. Тесты работают с временными UserDefaults/store, не с установленным приложением.

Имена Swift-файлов непосредственно под Sources/Keyboop нужны из-за `swiftc Sources/Keyboop/*.swift`. Новые Tests используют существующий DiagnosticTests и DiagnosticSuite из Tests/LayoutDiagnostics/TestSupport.swift. Регистр пути `Tests` сохранять в Git даже на нечувствительной к регистру файловой системе.

Каждая задача заканчивается отдельным коммитом только своих файлов. Не добавлять AI trailers. Не объявлять физический ввод проверенным на основании одного unit-набора или preview.

## Task 1: Зафиксировать и доставлять модель

**Goal:** Подготовить воспроизводимый ресурс RightLayout с проверкой происхождения и контрольной суммы.

**Files:**
- `Resources/RightLayout/model.json`
- `Resources/RightLayout/LICENSE`
- `scripts/fetch-rightlayout-model.sh`
- `scripts/compile-rightlayout-model.swift`
- `scripts/test-rightlayout-resource.sh`
- `build-app.sh`
- `Package.swift`
- `THIRD_PARTY.md`
- `Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel`
- `Sources/Keyboop/Resources/RightLayout/model.json`
- `.gitignore`

**Acceptance Criteria:**
- [ ] Скачивание привязано к commit 58658d8d4c3b71ed4cfd6b20627196a8145f17f9 и SHA256 5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704.
- [ ] Повреждённый файл не попадает на место рабочего ресурса, загрузчик --check-only не обращается в сеть.
- [ ] Сборка включает LayoutClassifier.mlmodelc и model.json в Resources/RightLayout. Исходная модель не коммитится и воспроизводится загрузчиком.
- [ ] Отдельный тест изменяет байт временной копии и получает ненулевой exit. Настоящий файл остаётся неизменным.
- [ ] Сохранены Apache-2.0 и источник модели. Отсутствие NOTICE у указанной ревизии явно записано, новые уведомления не выдумываются.

**Verify:** `bash scripts/test-rightlayout-resource.sh`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] Написать `scripts/test-rightlayout-resource.sh`: загрузить ресурс штатным загрузчиком, проверить manifest, затем проверять копии в mktemp. До реализации загрузчика прогон должен завершиться с отсутствующим скриптом. Сохранить RED в `docs/development/artifacts/rightlayout/01-red.txt`.
- [ ] Зафиксировать manifest:
```json
{
  "modelID": "rightlayout-ensemble-20-v1",
  "sourceCommit": "58658d8d4c3b71ed4cfd6b20627196a8145f17f9",
  "sha256": "5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704",
  "sourceBytes": 13880886,
  "parameters": 3462292,
  "inputLength": 20,
  "classes": ["ru", "en", "he", "ru_from_en", "he_from_en", "en_from_ru", "en_from_he", "he_from_ru", "ru_from_he"]
}
```
- [ ] Реализовать загрузчик с `set -euo pipefail`, поддержкой только пустого аргумента и `--check-only`. Проверять существующий файл через `shasum -a 256`. Скачивать во временный файл рядом с целевым, сверять размер и SHA, затем `mv`. Не заменять несовместимый существующий ресурс автоматически. Точный URL:
```text
https://raw.githubusercontent.com/chernistry/RightLayout/58658d8d4c3b71ed4cfd6b20627196a8145f17f9/RightLayout/Sources/Resources/LayoutClassifier.mlmodel
```
- [ ] В `.gitignore` исключить только `Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel` и скомпилированный `*.mlmodelc` этого модуля. Manifest, лицензия и скрипты остаются в Git. Лицензию получать с того же commit, затем сохранять в `Resources/RightLayout/LICENSE`. В THIRD_PARTY добавить имя, путь, commit и лицензию модели.
- [ ] Добавить отдельный компилятор ресурса. Входы: исходный mlmodel и целевая директория. Отказ при отсутствии файла и ошибке компиляции. Основная операция:
```swift
import Foundation
import CoreML
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let compiled = try MLModel.compileModel(at: source)
try FileManager.default.copyItem(at: compiled, to: destination)
```
- [ ] В `build-app.sh` выполнить check-only и подготовить ресурс во временной build-директории до удаления целевого app. После создания Resources скопировать скомпилированный каталог и manifest в `Contents/Resources/RightLayout`. На ошибке не выпускать bundle с молча отсутствующей моделью. В Package.swift добавить `.process("Resources/RightLayout")` в executableTarget. Runtime-пути: Bundle.main для прямой сборки, Bundle.module под `#if SWIFT_PACKAGE`.
- [ ] GREEN: `bash scripts/test-rightlayout-resource.sh`. Отдельно проверить `swift package dump-package` и `bash -n build-app.sh`. Сохранить вывод. Commit: `build: bundle pinned RightLayout model`.

```json:metadata
{
  "files": [
    "Resources/RightLayout/model.json",
    "Resources/RightLayout/LICENSE",
    "scripts/fetch-rightlayout-model.sh",
    "scripts/compile-rightlayout-model.swift",
    "scripts/test-rightlayout-resource.sh",
    "build-app.sh",
    "Package.swift",
    "THIRD_PARTY.md",
    "Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel",
    "Sources/Keyboop/Resources/RightLayout/model.json",
    ".gitignore"
  ],
  "verifyCommand": "bash scripts/test-rightlayout-resource.sh",
  "acceptanceCriteria": [
    "Скачивание привязано к commit 58658d8d4c3b71ed4cfd6b20627196a8145f17f9 и SHA256 5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704.",
    "Повреждённый файл не попадает на место рабочего ресурса, загрузчик --check-only не обращается в сеть.",
    "Сборка включает LayoutClassifier.mlmodelc и model.json в Resources/RightLayout. Исходная модель не коммитится и воспроизводится загрузчиком.",
    "Отдельный тест изменяет байт временной копии и получает ненулевой exit. Настоящий файл остаётся неизменным.",
    "Сохранены Apache-2.0 и источник модели. Отсутствие NOTICE у указанной ревизии явно записано, новые уведомления не выдумываются."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 2: Контракт модели и Core ML backend

**Goal:** Реализовать проверяемую обёртку настоящей модели без зависимости от Engine и UI.

**Files:**
- `Sources/Keyboop/NeuralLayoutTypes.swift`
- `Sources/Keyboop/RightLayoutModel.swift`
- `Tests/NeuralLayout/ModelTests.swift`
- `Tests/NeuralLayout/main.swift`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Алфавит, порядок девяти классов, объявленный вход Float32 [1,20], фактический массив int32 [1,20] и выход classLogits согласованы с настоящей моделью.
- [ ] Пустой ввод, длина более 20, неизвестный shape, нечисловые значения и отсутствующий ресурс возвращают типизированную ошибку.
- [ ] Softmax стабилен при больших логитах. Сумма оценок близка к 1, ни один класс не теряется.
- [ ] Никаких singleton, AppKit, defaults и event tap в backend. CPU используется явно.
- [ ] Настоящая модель выдаёт ru_from_en для ghbdtn и en_from_ru для руддщ. Неверные прогнозы реьд сохраняются как факты в оценке, а не превращаются в ложный тест успеха.

**Verify:** `bash scripts/test-neural-layout.sh model`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] Создать отдельный CLI-набор по образцу `scripts/test-layout-diagnostics.sh`: источники перечисляются явно, framework CoreML подключается только для model-набора. В `Tests/NeuralLayout/main.swift` регистрировать каждый DiagnosticSuite. Первый тест использует существующий `DiagnosticTests`:
```swift
let scores = try NeuralLayoutScores(logits: [10000, 9999, 0, 0, 0, 0, 0, 0, 0])
t.check("Softmax конечен", scores.values.allSatisfy { $0.isFinite })
t.check("Сумма оценок равна единице", abs(scores.values.reduce(0, +) - 1) < 0.000001)
t.check("Длинное слово отклонено", (try? RightLayoutTokenizer.encode(String(repeating: "a", count: 21))) == nil)
```
- [ ] Прогнать RED. Объявить в `NeuralLayoutTypes.swift` общий контракт:
```swift
import Foundation

enum NeuralLayoutMode: String, Codable, CaseIterable { case off, observe, assist }
enum NeuralLayoutError: Error { case invalidToken, invalidOutput, unavailable, invalidManifest }
enum NeuralLayoutClass: Int, Codable, CaseIterable {
    case ru, en, he, ruFromEn, heFromEn, enFromRu, enFromHe, heFromRu, ruFromHe
}
struct NeuralLayoutScores: Equatable {
    let values: [Double]
    init(logits: [Double]) throws {
        guard logits.count == 9, logits.allSatisfy({ $0.isFinite }), let maximum = logits.max() else {
            throw NeuralLayoutError.invalidOutput
        }
        let exponentials = logits.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total.isFinite, total > 0 else { throw NeuralLayoutError.invalidOutput }
        values = exponentials.map { $0 / total }
    }
    subscript(_ label: NeuralLayoutClass) -> Double { values[label.rawValue] }
}
protocol NeuralLayoutBackend {
    func predict(_ word: String) throws -> NeuralLayoutScores
}
```
- [ ] `RightLayoutTokenizer.encode(_:) throws -> [Int32]` переносит алфавит дословно из `CoreMLLayoutClassifier.swift` источника. Регистр не меняет. Неизвестные символы и padding используют 0. Ввод ограничивает 1...20 символами и одним токеном без whitespace/control. Неподдерживаемые эмодзи не могут сами по себе разрешать замену.
- [ ] `RightLayoutModel.init(modelURL: URL)` создаёт `MLModelConfiguration` с `.cpuOnly`, загружает заранее скомпилированную модель и проверяет input_ids (объявленный Float32 [1,20]) и classLogits (MultiArray Float32) через modelDescription. У закреплённых весов output shape объявлен пустым, поэтому разрешён динамический output с обязательной runtime-проверкой [9] или [1,9]. Иной статический shape отклоняется. `predict` создаёт MLMultiArray int32 [1,20], вызывает prediction и после проверки фактического shape [9]/[1,9] передаёт ровно девять конечных Double в NeuralLayoutScores. Никаких `try!` и принудительных unwrap для внешнего файла.
- [ ] Добавить тесты алфавита, нулей, регистра, двадцатого символа, 21-го символа, пустого массива и NaN. Настоящие веса проверять отдельно от unit-заглушек. GREEN: `bash scripts/test-neural-layout.sh model`. Commit: `feat: add RightLayout Core ML backend`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutTypes.swift",
    "Sources/Keyboop/RightLayoutModel.swift",
    "Tests/NeuralLayout/ModelTests.swift",
    "Tests/NeuralLayout/main.swift",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh model",
  "acceptanceCriteria": [
    "Алфавит, порядок девяти классов, объявленный вход Float32 [1,20], фактический массив int32 [1,20] и выход classLogits согласованы с настоящей моделью.",
    "Пустой ввод, длина более 20, неизвестный shape, нечисловые значения и отсутствующий ресурс возвращают типизированную ошибку.",
    "Softmax стабилен при больших логитах. Сумма оценок близка к 1, ни один класс не теряется.",
    "Никаких singleton, AppKit, defaults и event tap в backend. CPU используется явно.",
    "Настоящая модель выдаёт ru_from_en для ghbdtn и en_from_ru для руддщ. Неверные прогнозы реьд сохраняются как факты в оценке, а не превращаются в ложный тест успеха."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 3: Координатор и идентичность ввода

**Goal:** Ограничить вычисления одним активным и одним последним ожидающим запросом и исключить устаревшие результаты.

**Files:**
- `Sources/Keyboop/NeuralLayoutTypes.swift`
- `Sources/Keyboop/NeuralLayoutCoordinator.swift`
- `Tests/NeuralLayout/CoordinatorTests.swift`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Снимок содержит epoch, revision, occurrenceID, bundleID, layoutCode и точное word.
- [ ] При запросах A, B, C во время A backend выполняет только A и C.
- [ ] Другая буква, удаление, boundary, Enter, навигация, режим и новая сессия делают предыдущий снимок непригодным для замены.
- [ ] Одинаковый текст в другом occurrence не считается тем же вводом.
- [ ] Backend работает вне main/event tap. Состояние координатора меняется только на main. Ошибка освобождает активный слот.

**Verify:** `bash scripts/test-neural-layout.sh coordinator`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] Написать CoordinatorTests с управляемыми work/delivery очередями из массивов closure. Запросы A, B, C подавать до запуска work. Ожидать последовательность backend-вызовов `[A,C]`. До реализации получить RED.
- [ ] Добавить типы:
```swift
struct NeuralLayoutRequest: Equatable {
    let epoch: UUID
    let revision: UInt64
    let occurrenceID: UUID
    let bundleID: String
    let layoutCode: String
    let word: String
}
struct NeuralLayoutResult {
    let request: NeuralLayoutRequest
    let scores: NeuralLayoutScores
    let durationMs: Double
}
struct NeuralLayoutSession {
    private(set) var epoch = UUID()
    private(set) var revision: UInt64 = 0
    mutating func changed() { revision &+= 1 }
    mutating func invalidate() { epoch = UUID(); revision &+= 1 }
    func matches(_ request: NeuralLayoutRequest, occurrenceID: UUID?, bundleID: String,
                 layoutCode: String, word: String) -> Bool {
        request.epoch == epoch && request.revision == revision
            && request.occurrenceID == occurrenceID && request.bundleID == bundleID
            && request.layoutCode == layoutCode && request.word == word
    }
}
```
- [ ] `NeuralLayoutCoordinator` получает backend, `work: (@escaping () -> Void) -> Void`, `deliver: (@escaping () -> Void) -> Void` и callback с Result. Production work использует отдельную serial DispatchQueue, deliver использует DispatchQueue.main.async. Backend сохраняется и используется только этой work-очередью.
- [ ] Методы `submit(_:)`, `invalidate()` и завершение запроса вызываются на main. При занятом слоте `pending=request` заменяет прежний pending. Завершение возвращает результат callback, снимает busy и запускает единственный pending. `invalidate` увеличивает generation и очищает pending. Ошибки идут callback и не запускают бесконечных retry.
- [ ] Захватывать generation до запуска work. На delivery отбрасывать результат прежнего generation. Различие revision внутри одной сессии проверяет потребитель: результат может обогатить уже существующее решение журнала, но не поменять новый ввод.
- [ ] Проверить ошибки, инвалидирование во время работы и отсутствие удержания Engine после stop. GREEN: `bash scripts/test-neural-layout.sh coordinator`. Commit: `feat: schedule bounded neural layout inference`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutTypes.swift",
    "Sources/Keyboop/NeuralLayoutCoordinator.swift",
    "Tests/NeuralLayout/CoordinatorTests.swift",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh coordinator",
  "acceptanceCriteria": [
    "Снимок содержит epoch, revision, occurrenceID, bundleID, layoutCode и точное word.",
    "При запросах A, B, C во время A backend выполняет только A и C.",
    "Другая буква, удаление, boundary, Enter, навигация, режим и новая сессия делают предыдущий снимок непригодным для замены.",
    "Одинаковый текст в другом occurrence не считается тем же вводом.",
    "Backend работает вне main/event tap. Состояние координатора меняется только на main. Ошибка освобождает активный слот."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 4: Политика допуска предложений

**Goal:** Отделить решение модели от запретов движка и реализовать чистую проверку допуска автозамены.

**Files:**
- `Sources/Keyboop/NeuralLayoutPolicy.swift`
- `Sources/Keyboop/NeuralLayoutTypes.swift`
- `Sources/Keyboop/LayoutDetector.swift`
- `Tests/NeuralLayout/PolicyTests.swift`
- `Tests/LayoutDetector/RuleDetectorTests.swift`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Без профиля с enabled=true и SHA текущей модели ответ только observe, даже при сохранённом assist.
- [ ] Иврит, короткие слова, слово длиннее live-предела и недостаточный отрыв классов не дают замену.
- [ ] Все keep/force исключения, UndoLearner, developerMode, Chromium, Secure Input, модификаторы и antiResonance сохраняют приоритет.
- [ ] Обычный keep детектора различается с явным запрещающим правилом. Модель не переопределяет пользовательское force.
- [ ] Никакой фиксированной уверенности 0,99 и никакого текста, называющего softmax вероятностью правильности.

**Verify:** `bash scripts/test-neural-layout.sh policy && bash scripts/test-layout-detector.sh all`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: одна таблица тестов по всем запретам. Для каждого запрета один высокий корректный ruFromEn результат должен возвращать blocked с этим запретом. Отдельные тесты для двух запретов фиксируют приоритет.
- [ ] Ввести чистый профиль и оценку:
```swift
struct NeuralLayoutProfile: Codable {
    let modelSHA256: String
    let enabled: Bool
    let minimumScore: Double
    let minimumMargin: Double
}
enum NeuralLayoutBlock: String, Codable {
    case disabled, unavailable, profile, stale, length, unsupported, confidence
    case app, developer, secureInput, modifiers, editing, syntheticFlight, undo, rule, resonance, keymap
}
enum NeuralLayoutPolicyResult: Equatable {
    case observe
    case blocked(NeuralLayoutBlock)
    case propose(toCyrillic: Bool)
}
```
- [ ] `NeuralLayoutAdmission` содержит mode, modelSHA256, optional profile, fresh Bool, optional block, wordLength и sourceCyrillic. Функция `NeuralLayoutPolicy.evaluate(scores:admission:)` сначала проверяет mode и hard-block. Для sourceLatin выбирает только ruFromEn, для sourceCyrillic только enFromRu. Margin считать относительно максимума остальных восьми классов. Для любого выигрывающего неподдерживаемого класса возвращать blocked(.unsupported).
- [ ] Проверки по порядку: выключено, observe, hard-block, профиль/SHA, свежесть, длина 4...16, поддержка класса, score и margin. На успехе возвращать только направление, не текст. Профиль с нечисловыми, отрицательными либо >1 порогами отклоняется при загрузке.
- [ ] В LayoutDetector добавить чистую функцию `neuralRuleBlock(word:exceptions:) -> Bool`, использующую существующие `isExceptionOrPrefix` и фактические keep/force наборы ExceptionStore. Прежде изучить порядок force в текущем decide и покрыть его настоящими RuleDetectorTests. Не копировать логику триграмм в policy и не вызывать повторно decide из горячего callback.
- [ ] Engine впоследствии передаёт остальные запреты из своих кэшей и UndoLearner. Keymap и antiResonance проверяются непосредственно перед действием, их нельзя объявлять успешными при подготовке снимка.
- [ ] GREEN: обе команды Verify. Commit: `feat: gate neural layout proposals with existing rules`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutPolicy.swift",
    "Sources/Keyboop/NeuralLayoutTypes.swift",
    "Sources/Keyboop/LayoutDetector.swift",
    "Tests/NeuralLayout/PolicyTests.swift",
    "Tests/LayoutDetector/RuleDetectorTests.swift",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh policy && bash scripts/test-layout-detector.sh all",
  "acceptanceCriteria": [
    "Без профиля с enabled=true и SHA текущей модели ответ только observe, даже при сохранённом assist.",
    "Иврит, короткие слова, слово длиннее live-предела и недостаточный отрыв классов не дают замену.",
    "Все keep/force исключения, UndoLearner, developerMode, Chromium, Secure Input, модификаторы и antiResonance сохраняют приоритет.",
    "Обычный keep детектора различается с явным запрещающим правилом. Модель не переопределяет пользовательское force.",
    "Никакой фиксированной уверенности 0,99 и никакого текста, называющего softmax вероятностью правильности."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 5: Нейросведения в постоянном журнале

**Goal:** Сохранять предложение модели отдельно от фактической замены и поддержать безопасное позднее обогащение записи.

**Files:**
- `Sources/Keyboop/NeuralLayoutEvidence.swift`
- `Sources/Keyboop/LayoutObservation.swift`
- `Sources/Keyboop/LayoutJournalStore.swift`
- `Sources/Keyboop/LayoutDiagnosticsController.swift`
- `Sources/Keyboop/LayoutDiagnosticsRuntime.swift`
- `Tests/LayoutDiagnostics/NeuralEvidenceTests.swift`
- `scripts/test-layout-diagnostics.sh`

**Acceptance Criteria:**
- [ ] Старый JSON schemaVersion 1 читается с neural=nil и сохраняет случаи, правила, submission и словарные сведения.
- [ ] Обогащение существующего id изменяет только neural. Состояние keep не превращается в replace.
- [ ] Очистка увеличивает generation на FIFO-очереди. Поздний результат старого generation не восстанавливает запись.
- [ ] Выключение сбора запрещает новые сведения и поздние прикрепления. Работа самой модели от этого не зависит.
- [ ] Отсутствующие сведения опускаются при кодировании, чтобы выключенный модуль сохранял прежнюю форму записи.

**Verify:** `bash scripts/test-layout-diagnostics.sh all`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: декодировать сохранённый JSON без нового поля, записать observation с keep, прикрепить neural и проверить неизменность action/submission/proposed. Отдельный тест clear и позднего результата проверяет ноль observations.
- [ ] Ввести сериализуемую структуру и добавить `var neural: NeuralLayoutEvidence? = nil` в LayoutObservation:
```swift
struct NeuralLayoutEvidence: Codable, Equatable {
    let modelID: String
    let modelSHA256: String
    let mode: NeuralLayoutMode
    let ru: Double
    let en: Double
    let ruFromEn: Double
    let enFromRu: Double
    let unsupported: Double
    let durationMs: Double
    let proposedCyrillic: Bool?
    let block: NeuralLayoutBlock?
    let disagreesWithDetector: Bool
}
```
- [ ] Добавить `NeuralLayoutTypes`, `NeuralLayoutPolicy` и `NeuralLayoutEvidence` в явный список sources diagnostics-скрипта. Не подключать CoreML к Foundation-набору.
- [ ] В LayoutJournalStore добавить queue-owned `private var neuralGeneration: UInt64 = 0`. API `neuralWriteGeneration(completion:)` возвращает generation на main из FIFO. API `attachNeural(observationID:generation:evidence:completion:)` на той же очереди проверяет generation и наличие id. Для отсутствующего id или несовпадения generation завершает успешно без записи. При изменении использует обычный атомарный путь store и прежние ограничения размера.
- [ ] В операции clear увеличивать generation на той же queue до удаления observations. Метод `invalidateNeuralWrites(completion:)` увеличивает generation без очистки истории при выключении сбора. Runtime вызывает его при enabled=false. Запрос generation и последующее record идут в определённом FIFO-порядке, иначе результат до создания observation должен временно оставаться в памяти Runtime.
- [ ] Runtime держит ограниченный словарь не более 64 результатов по NeuralLayoutRequest. Ключ включает epoch, occurrenceID, word и revision. Очистка и выключение сбора очищают его. При записи решения прикрепляет точное совпадение. При получении поздней оценки прикрепляет её к сохранённому id только с captured generation. Не сохранять каждый префикс.
- [ ] GREEN: `bash scripts/test-layout-diagnostics.sh all`, подтвердить старый snapshot и лимиты. Commit: `feat: persist neural layout evidence in journal`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutEvidence.swift",
    "Sources/Keyboop/LayoutObservation.swift",
    "Sources/Keyboop/LayoutJournalStore.swift",
    "Sources/Keyboop/LayoutDiagnosticsController.swift",
    "Sources/Keyboop/LayoutDiagnosticsRuntime.swift",
    "Tests/LayoutDiagnostics/NeuralEvidenceTests.swift",
    "scripts/test-layout-diagnostics.sh"
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh all",
  "acceptanceCriteria": [
    "Старый JSON schemaVersion 1 читается с neural=nil и сохраняет случаи, правила, submission и словарные сведения.",
    "Обогащение существующего id изменяет только neural. Состояние keep не превращается в replace.",
    "Очистка увеличивает generation на FIFO-очереди. Поздний результат старого generation не восстанавливает запись.",
    "Выключение сбора запрещает новые сведения и поздние прикрепления. Работа самой модели от этого не зависит.",
    "Отсутствующие сведения опускаются при кодировании, чтобы выключенный модуль сохранял прежнюю форму записи."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 6: Подключить наблюдение к Engine

**Goal:** Собирать оценки RightLayout в фоне без изменения фактических решений текущего движка.

**Files:**
- `Sources/Keyboop/Engine.swift`
- `Sources/Keyboop/NeuralLayoutRuntime.swift`
- `Sources/Keyboop/NeuralLayoutCoordinator.swift`
- `Sources/Keyboop/AppSettings.swift`
- `Tests/NeuralLayout/ObservationIntegrationTests.swift`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Режим по умолчанию observe, неизвестное сохранённое значение трактуется как off. Off не загружает модель.
- [ ] Снимок формируется после изменения буфера на обычной букве. Ввод никогда не ждёт Core ML. Выполняющийся запрос после boundary может дополнить существующую запись журнала, но уже не может менять текст.
- [ ] Boundary, Enter, backspace, навигация при arrowsCancel=false, клик, смена окна, раскладки и режима инвалидируют право на замену.
- [ ] Режим observe даёт тот же поток фактических преобразований и подавленных keyDown/keyUp, что и off.
- [ ] Сбор выключен: оценки остаются только в оперативной памяти, observations не создаются и тексты в системный лог не попадают.

**Verify:** `bash scripts/test-neural-layout.sh integration && bash scripts/test-layout-baseline-contracts.sh && bash scripts/test-layout-detector.sh all`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: добавить тестируемый `NeuralLayoutRuntime` с injected coordinator и callback журналирования. В управляемом сценарии off и observe должны вернуть одинаковый массив действий текущего детектора. Тест observe не имеет callback записи клавиатуры.
- [ ] AppSettings получает свойство с существующим injected UserDefaults:
```swift
var neuralLayoutMode: NeuralLayoutMode {
    get {
        guard let raw = d.string(forKey: "neuralLayoutMode") else { return .observe }
        return NeuralLayoutMode(rawValue: raw) ?? .off
    }
    set {
        guard newValue != neuralLayoutMode else { return }
        d.set(newValue.rawValue, forKey: "neuralLayoutMode")
        NotificationCenter.default.post(name: .neuralLayoutModeChanged, object: nil)
    }
}
extension Notification.Name {
    static let neuralLayoutModeChanged = Notification.Name("neuralLayoutModeChanged")
}
```
- [ ] Runtime на main владеет session и координатором. Инициализация модели выполняется worker-очередью. До ready новые запросы заменяются последним, не копятся. Если загрузка провалилась, status=unavailable с причиной, текущий движок не меняется. Смена off очищает pending и инвалидирует callbacks. Модель освобождается на worker-очереди после завершения текущего prediction. При повторном включении создаётся новый backend в той же очереди.
- [ ] В Engine расширить существующий buffer.onContextReset: оставить diagnostics.resetContext и дополнительно invalidate neural session. Все вызовы diagnostics.resetContext без buffer.clear также явно инвалидируют neural session. Boundary и Enter увеличивают только revision и снимают право замены, сохраняя возможность закончить уже запущенное вычисление для журнала. Полный reset контекста меняет epoch и инвалидирует coordinator generation. Через отдельную функцию `invalidateNeuralContext()` объединить только эти операции, без переписывания остальных механизмов.
- [ ] На каждой реальной изменяющей ввод операции increment revision до действий. Связь запроса с записью журнала сохранять до инвалидирования на boundary: завершённое слово имеет lastOccurrenceID, тот же исходный текст и предыдущую revision. Runtime передаёт этот correlation key напрямую, а не ищет совпадение по одному typed. После `buffer.append` вызвать Runtime.observe с точным currentOccurrenceID, word, frontAppBID и cached layout. После обычной автоматической/ручной конверсии очистить ожидающие права нейросети. Backspace и boundary инвалидируют до нового запроса. Смена AX-контекста и окна должна обнулить epoch даже при том же bundleID.
- [ ] Runtime возвращает NeuralLayoutResult, Engine вычисляет policy для наблюдения и связывает optional evidence с `recordDecision`. В этом task обработчик результата не вызывает TextReplacer и не постит marker. Для слов 2...20 допускается наблюдение, 1 и >20 пропускаются.
- [ ] Перед копированием снимка проверить Secure Input, Pause, off, журнал редактируется, приложения off/soft и developerMode. Никакого AX IPC или синхронного запроса defaults из worker.
- [ ] GREEN: три Verify-команды. Commit: `feat: observe RightLayout decisions inside Keyboop`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/Engine.swift",
    "Sources/Keyboop/NeuralLayoutRuntime.swift",
    "Sources/Keyboop/NeuralLayoutCoordinator.swift",
    "Sources/Keyboop/AppSettings.swift",
    "Tests/NeuralLayout/ObservationIntegrationTests.swift",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh integration && bash scripts/test-layout-baseline-contracts.sh && bash scripts/test-layout-detector.sh all",
  "acceptanceCriteria": [
    "Режим по умолчанию observe, неизвестное сохранённое значение трактуется как off. Off не загружает модель.",
    "Снимок формируется после изменения буфера на обычной букве. Ввод никогда не ждёт Core ML. Выполняющийся запрос после boundary может дополнить существующую запись журнала, но уже не может менять текст.",
    "Boundary, Enter, backspace, навигация при arrowsCancel=false, клик, смена окна, раскладки и режима инвалидируют право на замену.",
    "Режим observe даёт тот же поток фактических преобразований и подавленных keyDown/keyUp, что и off.",
    "Сбор выключен: оценки остаются только в оперативной памяти, observations не создаются и тексты в системный лог не попадают."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 7: Оценить модель и построить профиль допуска

**Goal:** Получить воспроизводимое сравнение с текущим детектором и разрешать помощь только при выполнении критериев качества.

**Files:**
- `Tests/NeuralLayout/quality-source.jsonl`
- `Tests/NeuralLayout/quality-splits.json`
- `Tests/NeuralLayout/QualityTests.swift`
- `Tools/NeuralLayoutEvaluation/main.swift`
- `scripts/evaluate-neural-layout.sh`
- `Resources/RightLayout/profile.json`
- `docs/development/rightlayout-quality.md`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Calibration и holdout разделены по исходному семейству до получения префиксов и ошибочных раскладок.
- [ ] Holdout содержит не менее 2000 корректных токенов и 200 ошибочных RU/EN с лицензией/происхождением. Нет отправки живого журнала в сеть.
- [ ] Отчёт считает исходные ответы модели и итоговые действия policy отдельно: false positives, recall, abstention и ранний момент решения.
- [ ] Профиль enabled=true выпускается только при нуле дополнительных ложных замен относительно baseline на holdout и росте recall минимум на 5 процентных пунктов.
- [ ] Если ни один профиль не проходит, команда успешно выпускает enabled=false и причину. Нельзя менять holdout для прохождения.
- [ ] Модель/SHA, версия policy, digest fixtures и выбранные пороги записаны в профиль и отчёт.

**Verify:** `bash scripts/test-neural-layout.sh quality && bash scripts/evaluate-neural-layout.sh --verify`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: QualityTests подают искусственные confusion matrices. Матрица с дополнительным FP возвращает enabled=false. Матрица без новых FP и с приростом recall 0.05 возвращает enabled=true. Отдельный тест исключает семейство одновременно из calibration и holdout.
- [ ] Формат исходника, без передачи личного текста наружу:
```json
{"family":"en-command-npm","text":"npm","expected":"keep","kind":"technical","source":"curated","license":"project"}
{"family":"ru-greeting","text":"ghbdtn","expected":"ru","kind":"layout-error","source":"curated","license":"project"}
```
- [ ] Пополнить фиксированными корректными словами из имеющихся Resources/words_ru.json и words_en.json. Учитывать лицензию keyswitcher из THIRD_PARTY. Ошибочные варианты генерировать Keymap из заранее отделённых семейств. Добавить имена, аббревиатуры, npm, kubectl, Nuxt, реьд, дд/ll, пунктуационные клавиши, смешанные токены и отрицательные примеры с правильной латиницей внутри русской фразы. Не считать семантически неоднозначные короткие слова однозначными ошибками.
- [ ] Семейства делить стабильно по SHA256: первые семь из десяти bucket в calibration, остальные в holdout. Из одного семейства получать все префиксы только после разделения. При недостаточном размере holdout команда завершается с ошибкой и не пишет enabled=true.
- [ ] Перебрать на calibration minimumScore от 0.50 до 0.95 с шагом 0.01 и minimumMargin от 0.05 до 0.50 с шагом 0.01. Для каждой комбинации создать временный in-memory профиль enabled=true только внутри оценочного CLI и сравнить baseline и baseline+policy на одной последовательности префиксов. Этот профиль никогда не загружается приложением и не записывается в live defaults. Выбирать максимум recall при ограничении нулевого дополнительного FP, затем более высокий score, затем margin. Порог 0.99 не навязывается.
- [ ] Один выбранный профиль проверить на неизменённом holdout. Для сравнения использовать тот же admission и Keymap, что у runtime. Проверка family split и минимального объёма обязательна. Никакого обучения весов модели этой задачей не выполняется.
- [ ] Пример результата проверки готовности:
```python
def assistance_ready(baseline_fp, assisted_fp, baseline_recall, assisted_recall):
    return assisted_fp <= baseline_fp and assisted_recall - baseline_recall >= 0.05
```
- [ ] `--verify` проверяет SHA модели, digest fixtures, версию policy и все условия существующего профиля. Для enabled=false подтверждает причину и оставляет наблюдение доступным. Отчёт не обещает обобщение нулевого FP за пределы holdout.
- [ ] GREEN: Verify. Commit: `test: evaluate RightLayout assistance quality`.

```json:metadata
{
  "files": [
    "Tests/NeuralLayout/quality-source.jsonl",
    "Tests/NeuralLayout/quality-splits.json",
    "Tests/NeuralLayout/QualityTests.swift",
    "Tools/NeuralLayoutEvaluation/main.swift",
    "scripts/evaluate-neural-layout.sh",
    "Resources/RightLayout/profile.json",
    "docs/development/rightlayout-quality.md",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh quality && bash scripts/evaluate-neural-layout.sh --verify",
  "acceptanceCriteria": [
    "Calibration и holdout разделены по исходному семейству до получения префиксов и ошибочных раскладок.",
    "Holdout содержит не менее 2000 корректных токенов и 200 ошибочных RU/EN с лицензией/происхождением. Нет отправки живого журнала в сеть.",
    "Отчёт считает исходные ответы модели и итоговые действия policy отдельно: false positives, recall, abstention и ранний момент решения.",
    "Профиль enabled=true выпускается только при нуле дополнительных ложных замен относительно baseline на holdout и росте recall минимум на 5 процентных пунктов.",
    "Если ни один профиль не проходит, команда успешно выпускает enabled=false и причину. Нельзя менять holdout для прохождения.",
    "Модель/SHA, версия policy, digest fixtures и выбранные пороги записаны в профиль и отчёт."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 8: Включаемая помощь через event tap

**Goal:** Применять только свежие разрешённые предложения модели через существующий атомарный TextReplacer.

**Files:**
- `Sources/Keyboop/NeuralLayoutTypes.swift`
- `Sources/Keyboop/NeuralLayoutMarker.swift`
- `Sources/Keyboop/Engine.swift`
- `Sources/Keyboop/EventTap.swift`
- `Sources/Keyboop/InputLatency.swift`
- `Sources/Keyboop/NeuralLayoutRuntime.swift`
- `Tests/NeuralLayout/MarkerTests.swift`
- `Tests/NeuralLayout/AssistanceTests.swift`
- `scripts/test-neural-layout.sh`
- `scripts/test-layout-baseline-contracts.sh`

**Acceptance Criteria:**
- [ ] Новый marker содержит случайный per-launch prefix и монотонный token. Prefix исключает 0 и prefix прежних synthetic/pause marker. Тип keyDown, код 255, доставка cghidEventTap.
- [ ] EventTap поглощает только нейромаркер, до обычной синтетики и клавиш. Никакой Core ML, диска, UI или AX IPC в callback.
- [ ] Повторный marker не применяет другую заявку. Старый token не может забрать более новое предложение из mailbox.
- [ ] После изменения revision, occurrence, epoch, раскладки, окна и любого runtime-запрета замен нет.
- [ ] На успехе actual submission записывается один раз. На rejected буфер, счётчик и раскладка не считаются изменёнными.
- [ ] Порог 140 мс существующей паузной правки не применяется к нейромаркеру. Настройки inlineLiveFix и liveFixEnabled сохраняют приоритет.

**Verify:** `bash scripts/test-neural-layout.sh assistance && bash scripts/test-layout-baseline-contracts.sh && bash scripts/test-layout-detector.sh all`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: управляемая доставка A-marker после нового pending B не применяет B. Повторная доставка marker A даёт no-op. В тесте пришедшая перед marker буква увеличивает revision, а число вызовов write остаётся нулевым.
- [ ] Добавить чистую mailbox-структуру с `offer(result:) -> UInt32?`, `take(token:) -> NeuralLayoutResult?` и `invalidate()`. Token монотонно увеличивается от 1, хранится с конкретным pending и не переиспользуется при invalidate. При UInt32.max новые предложения блокируются до следующего запуска процесса. Несовпадающий token не извлекает mailbox. Повторный take возвращает nil. Доступ только main/event tap той же runloop.
- [ ] Тип события и token кодировать вместе в sourceUserData, не использовать булевы или системные поля CGEvent для хранения счётчика. Чистый кодек объявить в `NeuralLayoutTypes.swift`, а production-константу neuralLayoutMarkerCodec в `NeuralLayoutMarker.swift`:
```swift
import Foundation
struct NeuralLayoutMarkerCodec {
    let prefix: UInt32
    func encode(token: UInt32) -> Int64 {
        Int64(bitPattern: (UInt64(prefix) << 32) | UInt64(token))
    }
    func token(from marker: Int64) -> UInt32? {
        let bits = UInt64(bitPattern: marker)
        let token = UInt32(truncatingIfNeeded: bits)
        guard UInt32(truncatingIfNeeded: bits >> 32) == prefix, token != 0 else { return nil }
        return token
    }
}
let neuralLayoutMarkerCodec: NeuralLayoutMarkerCodec = {
    let forbidden = Set([UInt32(0), UInt32(truncatingIfNeeded: UInt64(bitPattern: kbSyntheticMarker) >> 32),
                         UInt32(truncatingIfNeeded: UInt64(bitPattern: kbPauseFixMarker) >> 32)])
    var prefix: UInt32 = 0
    repeat { prefix = UInt32.random(in: 1...UInt32.max) } while forbidden.contains(prefix)
    return NeuralLayoutMarkerCodec(prefix: prefix)
}()
```
Unit-тесты кодека компилируют NeuralLayoutTypes.swift и не включают NeuralLayoutMarker.swift с зависимостями TextReplacer. Проверить token 1, Int32.max, UInt32.max, чужой prefix и нулевой token. Отдельный CGEvent roundtrip обязан сохранить sourceUserData побитно.
- [ ] В InputEventOrigin добавить case neuralMarker и аргумент `isNeuralMarker: Bool = false` в classify, сохранив старые вызовы. Новый case имеет приоритет, затем прежние pause/synthetic/real. В EventTap.handle вычислить `let neuralToken = neuralLayoutMarkerCodec.token(from: sourceUserData)` и передать `isNeuralMarker: neuralToken != nil` в classify. До паузного и синтетического фильтра добавить:
```swift
if type == .keyDown, let token = neuralToken {
    (handler as? Engine)?.handleNeuralFixMarker(token: token, post: { $0.tapPostEvent(proxy) })
    return nil
}
```
Старые нейромаркеры с прежним token также поглощаются, но mailbox их отклоняет.
- [ ] Публиковать marker только при engineRunning, assist и разрешённом профиле. Сначала записать mailbox, затем создать CGEvent(keyboardEventSource:nil, virtualKey:255, keyDown:true), flags=[], sourceUserData=neuralLayoutMarkerCodec.encode(token:token). Post только cghidEventTap. После failed CGEvent creation отозвать конкретный token. Время жизни pending не больше 0.5 с, проверка monotonic clock при take, без таймера polling.
- [ ] Engine.handleNeuralFixMarker на main выполняет `take(token:)`, проверяет session.matches, все admission guards, существующие settings.inlineLiveFix и inlineHealthy, текущие физические модификаторы. Не использовать handlePauseFixMarker: там другой смысл и паузный порог.
- [ ] На допуске получить `converted` исключительно через Keymap.liveConvert с настоящим ruWordValidator. Проверить antiResonance и UndoLearner. Record path neuralLive и reason neuralConvert, затем replaceInline(deleteCount: buffer.currentWord.count, with: converted, post: post). Только submitted=true разрешает applyConversion, liveFixLast и отложенные на main выбор раскладки, UndoLearner.noteConversion, rescuedCount, звук и уведомление. PendingChar не существует, реальную пользовательскую клавишу не глотать.
- [ ] Добавить `.neuralLive` в LayoutPath и `.neuralConvert` в LayoutReason вместе с локализацией. Сравнить switch по всем case и Presenter.allowedActions: частичную neuralLive-замену нельзя выдавать за полное слово для глобального force.
- [ ] GREEN: Verify. Commit: `feat: apply validated neural layout proposals safely`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutTypes.swift",
    "Sources/Keyboop/NeuralLayoutMarker.swift",
    "Sources/Keyboop/Engine.swift",
    "Sources/Keyboop/EventTap.swift",
    "Sources/Keyboop/InputLatency.swift",
    "Sources/Keyboop/NeuralLayoutRuntime.swift",
    "Tests/NeuralLayout/MarkerTests.swift",
    "Tests/NeuralLayout/AssistanceTests.swift",
    "scripts/test-neural-layout.sh",
    "scripts/test-layout-baseline-contracts.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh assistance && bash scripts/test-layout-baseline-contracts.sh && bash scripts/test-layout-detector.sh all",
  "acceptanceCriteria": [
    "Новый marker содержит случайный per-launch prefix и монотонный token. Prefix исключает 0 и prefix прежних synthetic/pause marker. Тип keyDown, код 255, доставка cghidEventTap.",
    "EventTap поглощает только нейромаркер, до обычной синтетики и клавиш. Никакой Core ML, диска, UI или AX IPC в callback.",
    "Повторный marker не применяет другую заявку. Старый token не может забрать более новое предложение из mailbox.",
    "После изменения revision, occurrence, epoch, раскладки, окна и любого runtime-запрета замен нет.",
    "На успехе actual submission записывается один раз. На rejected буфер, счётчик и раскладка не считаются изменёнными.",
    "Порог 140 мс существующей паузной правки не применяется к нейромаркеру. Настройки inlineLiveFix и liveFixEnabled сохраняют приоритет."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 9: Настройки и объяснение решений

**Goal:** Дать пользователю выбор режима и показать предложение модели отдельно от действия Keyboop.

**Files:**
- `Sources/Keyboop/NeuralLayoutSettingsView.swift`
- `Sources/Keyboop/SettingsWindow.swift`
- `Sources/Keyboop/LayoutJournalView.swift`
- `Sources/Keyboop/LayoutJournalPresenter.swift`
- `Sources/Keyboop/L10n.swift`
- `Sources/Keyboop/NeuralLayoutRuntime.swift`
- `Tests/NeuralLayout/SettingsTests.swift`
- `Sources/Keyboop/LayoutJournalPreviewCheck.swift`
- `scripts/test-neural-layout.sh`

**Acceptance Criteria:**
- [ ] Режимы: Выключено, Наблюдение, Помощь при переключении. Наблюдение выбрано при отсутствии настройки.
- [ ] При enabled=false профиля помощь недоступна с объяснением, сохранённый assist эффективно работает как observe.
- [ ] В карточке различаются предложение модели, фактическое действие и причина отказа. Softmax не подписан как точность.
- [ ] Показаны загрузка и ошибка модели. Никаких обещаний автоматического обучения в первой версии.
- [ ] Режим сохраняется после перезапуска, смена режима инвалидирует pending и не меняет включение сбора.

**Verify:** `bash scripts/test-neural-layout.sh settings && bash scripts/test-layout-diagnostics.sh all`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] RED: SettingsTests используют UserDefaults(suiteName: UUID), очищаемый defer. Проверить absent, unknown, observe, off, assist и уведомление смены. Runtime-status tests проверяют недоступность помощи при SHA mismatch.
- [ ] Создать отдельный AppKit NSView для трёх radio/menu-опций и статуса. Встроить его в текущий раздел настроек раскладки через SettingsWindow, не раздувая существующий экран деталями обучения. Идентификаторы для native-проверки:
```text
neural.mode.off
neural.mode.observe
neural.mode.assist
neural.status
journal.neural.proposal
journal.neural.actual
journal.neural.reason
```
- [ ] Добавить локализованные RU/EN строки в L10n.swift. Минимальные русские формулировки:
```text
Наблюдение: модель предлагает решения в журнале, раскладку меняет текущий движок.
Помощь при переключении: модель участвует в замене после проверки качества.
Помощь недоступна: модель пока не прошла проверку качества.
Предложение модели
Действие Keyboop
Оценка модели
```
- [ ] Presenter получает `neuralDetails(for:)`, который возвращает display-данные без загрузки модели. View показывает nil evidence без пустых заголовков. Время остаётся MSK. SHA и сырые оценки всех классов доступны в JSON-экспорте.
- [ ] Расширить существующий изолированный preview check: вставить observation с keep и противоположным neural proposal, убедиться, что actual отображается как keep. Отключение сбора не выключает модель и наоборот. Все preview defaults/store/backend временные, event tap не запускается.
- [ ] GREEN: Verify и native check в финальной задаче. Commit: `feat: expose neural layout modes and journal evidence`.

```json:metadata
{
  "files": [
    "Sources/Keyboop/NeuralLayoutSettingsView.swift",
    "Sources/Keyboop/SettingsWindow.swift",
    "Sources/Keyboop/LayoutJournalView.swift",
    "Sources/Keyboop/LayoutJournalPresenter.swift",
    "Sources/Keyboop/L10n.swift",
    "Sources/Keyboop/NeuralLayoutRuntime.swift",
    "Tests/NeuralLayout/SettingsTests.swift",
    "Sources/Keyboop/LayoutJournalPreviewCheck.swift",
    "scripts/test-neural-layout.sh"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh settings && bash scripts/test-layout-diagnostics.sh all",
  "acceptanceCriteria": [
    "Режимы: Выключено, Наблюдение, Помощь при переключении. Наблюдение выбрано при отсутствии настройки.",
    "При enabled=false профиля помощь недоступна с объяснением, сохранённый assist эффективно работает как observe.",
    "В карточке различаются предложение модели, фактическое действие и причина отказа. Softmax не подписан как точность.",
    "Показаны загрузка и ошибка модели. Никаких обещаний автоматического обучения в первой версии.",
    "Режим сохраняется после перезапуска, смена режима инвалидирует pending и не меняет включение сбора."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Task 10: Проверить производительность и доставку

**Goal:** Зафиксировать задержки, native-поведение и содержимое собранного bundle без замены установленного приложения.

**Files:**
- `Tools/NeuralLayoutBenchmark/main.swift`
- `scripts/benchmark-neural-layout.sh`
- `scripts/test-neural-layout.sh`
- `docs/development/rightlayout-module-verification.md`
- `docs/development/artifacts/rightlayout/`

**Acceptance Criteria:**
- [ ] Настоящая модель прогревается, затем выполняется не менее 1000 prediction. Считаются p50/p95/p99/max и холодный запуск.
- [ ] На этом Mac CPU p95 не превышает 5 мс. Если превышает, помощь недоступна до исправления, наблюдение продолжает работать.
- [ ] Очередь ограничена двумя запросами, пяти минут быстрой подачи не дают роста backlog и неограниченного хранения текста.
- [ ] Native-проверка использует изолированные defaults/store, подтверждает режимы, status и отдельное отображение proposal/actual.
- [ ] Bundle в /private/tmp содержит настоящую модель и manifest, strict codesign проходит. /Applications не меняется.
- [ ] Отчёт различает автоматические тесты, синтетическую доставку и физический ввод. Непроверенный физический ввод явно остаётся непроверенным.

**Verify:** `bash scripts/test-neural-layout.sh all && bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && bash scripts/test-layout-baseline-contracts.sh && bash scripts/benchmark-neural-layout.sh`. Ожидается exit 0 и непустой набор без ошибок.

**Steps:**

- [ ] Написать benchmark runner с тем же RightLayoutModel, не копируя обёртку из исследования. Входы только фиксированные тестовые строки, никаких чтений активного пользовательского ввода. Вывод JSON с моделью/SHA, macOS/arch, режимом computeUnits, числом замеров и метриками.
- [ ] Прогреть 50 вызовами, затем минимум 1000. Перцентили считать на отсортированном массиве через индекс ceil(p*n)-1. Отдельно измерить создание модели и первый prediction. Для памяти замерять RSS процесса до загрузки и после прогрева, дополнительно maxRSS. Не называть всю память процесса размером модели.
- [ ] Пять минут подавать запросы с частотой 100/с через coordinator и быстрый dummy backend, затем с настоящим backend. Счётчик inFlight<=1, pending<=1 во всех измерениях. После stop callbacks с правом замены не поступают. Процесс не читает и не меняет реальные defaults.
- [ ] Измерить input callback spans off/observe/assist в изолированном сценарии, сохранить median/p95/p99 и возраст событий, а не только время тела callback. Проверить, что sleep/await CoreML не появился внутри EventTap.handle. Энергопотребление измерять отдельным доступным инструментом и сохранять методику. Если инструмента нет, прямо написать «не измерялось», не подменять wall time процентом CPU.
- [ ] Выполнить все Verify-команды. Новые тесты должны быть непустыми, все прежние baseline-сценарии сохранены. Отдельно проверить выключенный backend, испорченный manifest и enabled=false profile.
- [ ] Собрать только временный bundle:
```bash
KEYBOOP_SIGN_ID=- KEYBOOP_BUILD_APP=/private/tmp/Keyboop_rightlayout.app bash build-app.sh
codesign --verify --deep --strict /private/tmp/Keyboop_rightlayout.app
```
Перед сборкой посмотреть существующие local/dev флаги build-app.sh и задать их так же, как при прошлой локальной доставке, чтобы LocalBuildPolicy запрещал updates. Не запускать installer и не заменять установленное приложение.
- [ ] В изолированном preview запустить настоящий AppKit-контроль журнала и режима через явные preview env флаги. Если существующий LayoutJournalPreviewCheck требует дополнения, добавить новый путь `KEYBOOP_NEURAL_PREVIEW_CHECK=1`, который выполняется до AppDelegate/event tap. Проверить, что обычный production-запуск флагом не затронут. Сохранить native-check exit и светлый/тёмный снимки.
- [ ] Физическую проверку ghbdtn, продолжения набора, backspace, переключения окна, кодового редактора и Chromium выполнять только после проверки доступов AX/InputMon и в отдельном тестовом поле. Если разрешений нет, обозначить физический сценарий непроверенным и не объявлять всю интеграцию проверенной на реальном вводе.
- [ ] Commit: `test: verify neural layout module performance and delivery`. Зафиксировать команды, результаты, SHA bundle и итоговый доступный режим в отчёте.

```json:metadata
{
  "files": [
    "Tools/NeuralLayoutBenchmark/main.swift",
    "scripts/benchmark-neural-layout.sh",
    "scripts/test-neural-layout.sh",
    "docs/development/rightlayout-module-verification.md",
    "docs/development/artifacts/rightlayout/"
  ],
  "verifyCommand": "bash scripts/test-neural-layout.sh all && bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && bash scripts/test-layout-baseline-contracts.sh && bash scripts/benchmark-neural-layout.sh",
  "acceptanceCriteria": [
    "Настоящая модель прогревается, затем выполняется не менее 1000 prediction. Считаются p50/p95/p99/max и холодный запуск.",
    "На этом Mac CPU p95 не превышает 5 мс. Если превышает, помощь недоступна до исправления, наблюдение продолжает работать.",
    "Очередь ограничена двумя запросами, пяти минут быстрой подачи не дают роста backlog и неограниченного хранения текста.",
    "Native-проверка использует изолированные defaults/store, подтверждает режимы, status и отдельное отображение proposal/actual.",
    "Bundle в /private/tmp содержит настоящую модель и manifest, strict codesign проходит. /Applications не меняется.",
    "Отчёт различает автоматические тесты, синтетическую доставку и физический ввод. Непроверенный физический ввод явно остаётся непроверенным."
  ],
  "userGate": false,
  "requiresUserSpecification": false
}
```

## Карта покрытия дизайна

| Требование дизайна | Задачи |
| --- | --- |
| Источник, лицензия, SHA, bundle и SwiftPM | 1 |
| Токенизация, все классы, CPU и ошибки | 2 |
| Один running и один pending, независимая сессия | 3, 6 |
| Существующие запреты и безопасное преобразование | 4, 8 |
| Старый JSON, отдельный proposal, clear и выключенный сбор | 5, 6 |
| Работа во время набора, atomic marker и stale replies | 3, 6, 8 |
| Наблюдение по умолчанию и включаемая помощь | 6, 7, 9 |
| Оценка, holdout, abstention и профиль с SHA | 7 |
| Native UI, fallback и явная недоступность модели | 6, 9, 10 |
| Задержки, память, backlog и ограничения физической проверки | 10 |
| Отдельное последующее обучение | Явно исключено из текущего объёма |

## Передача на реализацию

После выбора способа исполнения открыть этот план и соседний tasks.json, убедиться в чистоте нужного рабочего дерева и начать с Task 1. При продолжении после паузы читать status/blockedBy из tasks.json. Запрошена подготовка плана, поэтому на момент его сдачи production-код, веса приложения и установленная копия не изменены.
