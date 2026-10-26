# Локальная сборка диагностики раскладки

Исходная версия приложения: `v0.4.10`, коммит `fb9bdde4`.
Проверено на Apple Silicon, Xcode с Apple Swift 6.4, CMake 4.4.3.
Скрипты не запускают приложение и не устанавливают его в `/Applications`.

## Отдельные проверки

```bash
bash scripts/test-layout-detector.sh baseline
bash scripts/test-layout-diagnostics.sh harness
```

Первый стенд компилирует настоящие `Keymap`, `DynamicKeymap`, `LayoutData`,
`ExtraWords`, `ExceptionStore`, `LayoutDetector` через `swiftc` с Carbon.
`KEYBOOP_DATA_DIR` указывает на ресурсы репозитория. Проверяются оба
словаря и обе таблицы триграмм, исправление `ghbdtn` в русскую раскладку
и сохранение `hello`.
Динамическая таблица не перестраивается, используется штатный статический fallback.
`ExceptionStore` читает пустые исключения из аргументного домена UserDefaults
в памяти. Флаги миграций заданы там же, поэтому стенд не записывает настройки.

В диагностический стенд добавляются файлы `Tests/LayoutDiagnostics/*Tests.swift`.
Каждый файл объявляет одноимённый тип, реализующий `DiagnosticSuite`:

```swift
enum TrackerTests: DiagnosticSuite {
    static let name = "tracker"
    static func run(_ tests: DiagnosticTests) {
        tests.check("Событие записано", true)
    }
}
```

Скрипт автоматически регистрирует типы. Новые файлы ядра перечисляются явно
в `scripts/test-layout-diagnostics.sh`. SwiftPM всего приложения не нужен.
Коды завершения: 0 – все проверки прошли и число проверок положительно,
1 – есть ошибка утверждения, 2 – неизвестный или пустой набор/неверный fixture.
Ошибки компиляции также возвращают ненулевой код.

## Зависимости полной сборки

```bash
bash scripts/setup-layout-diagnostics-build.sh
bash scripts/test-fluidaudio-offline.sh
KEYBOOP_SIGN_ID=- KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-baseline.app bash build-app.sh
codesign --verify --deep --strict /tmp/Keyboop-layout-baseline.app
```

Нужны Xcode с backend SwiftPM `swiftbuild`, Git, CMake, curl, tar и Apple libtool.
Скрипт скачивает только исходники и Sparkle, без голосовых моделей.
Все артефакты находятся в игнорируемом `vendor/`:

| Зависимость | Версия/исходник | Артефакт |
| --- | --- | --- |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/v1.8.3) | `2eeeba56e9edd762b4b38467bab96c2517163158` | `vendor/whisper.cpp/build-macos14` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/v0.14.8) | `56607d90b97de7d95a731200563bf49aa5beef20` + патч ниже | `vendor/fluidaudio-prebuilt/{libFluidAudio.a,Modules,include}` |
| [Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.3) | `2.9.3` | `vendor/sparkle/Sparkle.framework` |

SHA-256 архива `Sparkle-2.9.3.tar.xz`:
`74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6`.

whisper.cpp собирается статически с `CMAKE_OSX_DEPLOYMENT_TARGET=14.0`.
FluidAudio собирается с `--triple arm64-apple-macosx14.0`, затем три объектных
файла FluidAudio/FastClusterWrapper/MachTaskSelfWrapper объединяются в архив.
Swift-модуль и заголовки копируются рядом. `--disable-sandbox` нужен для SwiftPM
в среде с уже действующим sandbox, где вложенный `sandbox-exec` не разрешён.

В ограниченном окружении проверка процессов в `build-app.sh` может вернуть `?`
и остановить сборку. Нужен запуск того же скрипта с доступом к чтению метаданных
процессов. Защитные проверки скрипта отключать нельзя.

## Недостающий офлайн-патч FluidAudio

Публичный исходник Keyboop использует `DownloadUtils.enforceOffline`, которого
нет в upstream FluidAudio. Без патча полная сборка останавливается на
`type 'DownloadUtils' has no member 'enforceOffline'`.

`vendor-patches/fluidaudio-offline.patch` восстанавливает этот контракт:
флаг по умолчанию включён, доступ защищён NSLock. Каждый прямой вызов
URLSession проверяет актуальный флаг. Публичные методы скачивания проверяют
его до создания каталогов. При ошибке загрузки в офлайне `loadModels`
возвращает исходную ошибку до удаления кэша и повторного скачивания.
Явные кнопки скачивания приложения уже временно выключают этот флаг.

Стенд `test-fluidaudio-offline.sh` не скачивает модели. Он проверяет отказы
четырёх публичных сетевых методов, сохранение файла-маркера в кэше при ошибке
загрузки и возможность разрешить явное скачивание. Распознавание с настоящей
моделью этим стендом не проверяется.

Повторный запуск setup проверяет исходные SHA и применённость патча,
не сбрасывает существующие checkout. Без `KEYBOOP_SIGN_ID=-` сборка ожидает локальный сертификат `Keyboop Dev`.
Для изолированного bundle используется ad-hoc подпись.
Подпись и сборочный bundle проверяются
отдельной командой выше. Запуск и установка приложения не входят в проверку.
