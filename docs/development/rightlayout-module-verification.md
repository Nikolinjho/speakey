# Проверка модуля RightLayout

27.10.2026, MSK. Mac: Apple M5 Pro, arm64, macOS Version 27.0 (Build 26A428). Модель `rightlayout-ensemble-20-v1`, CPU only, SHA256 `5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704`.

Помощь остаётся недоступной: поставляемый профиль содержит `enabled=false`, причина `recall-gain-below-0.05`. Сохранённый режим assist эффективно работает как observe. Проверка качества на 86 601 уникальном префиксе подтвердила early recall 91,81996% и FP 0 у базового и дополненного движков. Сырая модель без ограничений дала 635 FP. [Журнал оценки](artifacts/rightlayout/10-quality.log).

## CPU и память

Используется production `RightLayoutModel`, 50 прогревов и 1000 измерений на шести фиксированных словах. Перцентиль: индекс `ceil(p*n)-1` в отсортированном массиве. Первый экземпляр модели в процессе загружался 17,183 мс, первый prediction занял 21,516 мс, сумма 38,699 мс. Состояние файлового кеша не контролировалось.

| Метрика prediction | мс |
| --- | ---: |
| p50 | 0,545 |
| p95 | 0,576 |
| p99 | 0,608 |
| Максимум | 0,721 |

Порог CPU p95 5 мс выполнен. Он не отменяет отказ профиля по качеству.

RSS процесса до модели: 21 053 440 байт. После прогрева: 42 434 560 байт. MaxRSS процесса в этой точке: 42 582 016 байт. Это память всего процесса, а не размер модели. RSS читается через `mach_task_basic_info`, maxRSS – через `getrusage` в байтах на macOS. [Полный benchmark](artifacts/rightlayout/10-benchmark.log), [SHA исходников](artifacts/rightlayout/10-benchmark-sources.log), [SHA runner](artifacts/rightlayout/10-benchmark-binary.log).

## Ограничение очереди

Проверка использует настоящий `NeuralLayoutCoordinator`, сначала dummy, затем production CPU backend. На каждый backend подаются 30 000 запросов по 100 в секунду за пять минут. Измеряются занятый слот, единственный pending и фактическая параллельность вызовов backend. Последний отдельный запрос сразу инвалидируется, worker дожидается завершения. Callback после инвалидирования считается ошибкой.

Полный повтор завершился с кодом 0. [Журнал](artifacts/rightlayout/10-benchmark.log), [общий протокол команд и результатов](artifacts/rightlayout/10-results.json).

| Backend | Отправок | Длительность, мс | Worker max | Active max | Pending max | Callback после invalidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Dummy | 30 000 | 300 000,901 | 1 | 1 | 1 | 0 |
| RightLayoutModel CPU | 30 000 | 300 000,730 | 1 | 1 | 0 | 0 |

Оба backend вернули по 30 000 callbacks без ошибок. Отдельный stop-probe в эти числа не включён. RSS перед dummy: 43 827 200 байт, после: 44 040 192 байт, максимум выборки: 44 072 960 байт. Для CPU: 44 040 192, 44 957 696 и 44 957 696 байт соответственно. RSS процесса во время нагрузки измерялся раз в 100 отправок, поэтому максимум выборки не называется maxRSS процесса. Короткий [smoke](artifacts/rightlayout/10-benchmark-smoke.log) проверяет тот же цикл по 100 запросов на backend. Счётчики worker и pending не превышают одного, callbacks после инвалидирования отсутствуют. Память очереди ограничена активным и последним ожидающим запросами, строки только фиксированные синтетические.

Первый запуск прошёл dummy-фазу, затем завершился с кодом 133 из-за underflow в измерительном цикле. Неполная CPU-фаза не учитывается. [Неуспешный запуск](artifacts/rightlayout/10-benchmark-first-attempt.log) сохранён отдельно.

## Что измерено на пути ввода

Отдельный [benchmark Runtime](artifacts/rightlayout/10-input.log) вызывает настоящий `NeuralLayoutRuntime.changed/observe` для off, observe и assist по 1000 раз. Каждый Runtime создаёт собственную модель в worker factory. Локальные CGEvent не публикуются, их timestamp задан явно в наносекундах `mach_absolute_time`. Возраст показывает только интервал между назначением этого синтетического штампа и локальным вызовом, а не ожидание в WindowServer.

| Режим | Эффективный режим | p50, мс | p95, мс | p99, мс |
| --- | --- | ---: | ---: | ---: |
| off | off | 0,000541 | 0,001209 | 0,001542 |
| observe | observe | 0,001042 | 0,001625 | 0,001959 |
| assist | observe | 0,003875 | 0,006541 | 0,008209 |

Это длительность вызова Runtime, без EventTap.handle и системной доставки. Настоящие callback spans off/observe/assist и возраст событий ОС не измерены: обычный Engine и event tap по условиям изоляции не запускались. Статическая проверка `EventTap.handle` подтверждает отсутствие sleep/await и синхронной загрузки CoreML в новом нейропути. Модель загружается и выполняется worker-очередью.

Проверка AX и Input Monitoring без запроса разрешений вернула true для benchmark-процесса. Физические ghbdtn, продолжение набора, backspace, смена окна, редактор кода и Chromium не проверялись: физический ввод в изолированное поле в этой сессии не выполнялся. Разрешения сами по себе не подтверждают доставку. Системная доставка нейромаркера также не проверена. Нативные set/get и copy CGEvent проверены тестами на все 64 бита. Сериализация event.data теряет userData и в production не используется.

Энергопотребление не измерялось. Доступный `powermetrics` требует superuser, [попытка запуска](artifacts/rightlayout/10-energy.log) завершилась кодом 1. Проценты CPU и расход батареи из wall time не выводились.

## Автоматические и нативные проверки

| Проверка | Результат | Журнал |
| --- | --- | --- |
| Neural all | 513 проверок, 0 ошибок | [neural](artifacts/rightlayout/10-neural.log) |
| Production factory | 4 проверки, 0 ошибок | [factory](artifacts/rightlayout/10-neural.log) |
| Diagnostics all | 295 проверок, 0 ошибок | [diagnostics](artifacts/rightlayout/10-diagnostics.log) |
| Detector all | 101 проверка, 0 ошибок | [detector](artifacts/rightlayout/10-detector.log) |
| Baseline contracts | exit 0 | [baseline](artifacts/rightlayout/10-baseline.log) |
| Model resource | exit 0 | [resource](artifacts/rightlayout/10-resource.log) |
| Quality verify | exit 0, 86 601 CPU prediction | [quality](artifacts/rightlayout/10-quality.log) |
| Native neural dark | 11 проверок, 0 ошибок | [dark](artifacts/rightlayout/10-native-dark.log) |
| Native neural light | 11 проверок, 0 ошибок | [light](artifacts/rightlayout/10-native-light.log) |
| Прежний native journal preview | 29 проверок, 0 ошибок | [journal](artifacts/rightlayout/10-native-journal.log) |

Наборы включают off без backend, повреждённый manifest, `enabled=false`, устаревшие результаты и независимость сбора. Тест формы входа использует корректный float32 с неверной формой, чтобы отказ проверял именно форму.

Нативные проверки запускаются ранним preview-флагом до AppDelegate/Engine. Используются отдельные временные defaults, store и presentation. Runtime и policy настоящие, backend для UI подставной. Проверяются сохранение режима, loading/error/ready, недоступный assist с effective observe, независимость сбора и отдельные предложение модели, фактический keep и отказ профиля. Все четыре снимка просмотрены: [настройки dark](artifacts/rightlayout/10-settings-dark.png), [журнал dark](artifacts/rightlayout/10-journal-dark.png), [настройки light](artifacts/rightlayout/10-settings-light.png), [журнал light](artifacts/rightlayout/10-journal-light.png).

## Временная сборка

Сборка выполнена только в `/private/tmp/Keyboop_rightlayout.app` с `KEYBOOP_RELEASE=0`, `KEYBOOP_SIGN_ID=-`. Bundle ID: `ru.keyboop.app.dev`, `SUFeedURL` отсутствует. Настоящий compiled model загружается production-обёрткой непосредственно из bundle, smoke завершился кодом 0. Manifest, profile и лицензия побайтно совпадают с исходниками. `codesign --verify --deep --strict` прошёл. [Сборка](artifacts/rightlayout/10-build.log), [проверка содержимого и SHA](artifacts/rightlayout/10-bundle.log), [bundle model](artifacts/rightlayout/10-bundle-model.log).

SHA256 executable: `cb192143bd49c00f4c4d506338c44baee615edda8fda35b4f6f2ded3705abe51`.

SHA256 дерева обычных файлов bundle: `82c857258abf0f01ff67fa68da9173c77106c99a7efa4ee18bd5e2d33917b5e8`. Метод: отсортированные относительные UTF8-пути, NUL, байты файла, NUL. Символьные ссылки не включены, подпись проверяется отдельно.

Установленное приложение, реальные defaults и TCC не менялись. Установка, публикация и обновление DMG не выполнялись. [Команды воспроизведения](artifacts/rightlayout/10-commands.md).
