# Проверка локального журнала раскладки

Дата: 26 октября 2026, MSK. Ветка `feat/layout-diagnostics`. Проверки задач 0–5 зафиксированы в `0814b1c`.

## Локальная сборка

Готовое приложение: `Keyboop_local.app` в корне этого рабочего дерева. Bundle ID –
`ru.keyboop.app.dev`, имя приложения в macOS – `Keyboop_local`. Настройки изолированы от `ru.keyboop.app`, журнал находится в
`~/Library/Application Support/ru.keyboop.app.dev/LayoutDiagnostics/`.

Обновления локальной сборки отключены: `SUEnableAutomaticChecks=false`,
`KeyboopLocalBuild=true`, `SUFeedURL` отсутствует. `UpdaterController.start()`,
`checkNow()` и включение автоматических проверок прекращаются до обращения к
Sparkle, в том числе с `KEYBOOP_UPDATER=1`. Раздел обновлений объясняет причину.
Релизная сборка сохраняет прежнее поведение.

```bash
KEYBOOP_SIGN_ID=- KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh
codesign --verify --deep --strict /tmp/Keyboop-layout-diagnostics.app
ditto /tmp/Keyboop-layout-diagnostics.app Keyboop_local.app
codesign --verify --deep --strict Keyboop_local.app
```

Финальная сборка завершилась с exit 0, обе проверки подписи – с exit 0.
Лог сборки: `logs/layout-build.log`. SHA-256 исполняемого файла:
`7d50b56c15f28b0724da1b6d4c747510a302044f2683f813de47564eafc1bb57`.

После проверок имя bundle и оба поля `CFBundleName`/`CFBundleDisplayName`
изменены на `Keyboop_local`. Исполняемый файл и Bundle ID сохранены.
Внешняя подпись обновлена той же командой с `Keyboop-dev.entitlements`:

```bash
codesign --force --sign - --entitlements Keyboop-dev.entitlements --timestamp=none Keyboop_local.app
codesign --verify --deep --strict Keyboop_local.app
```

Проверка подписи переименованного приложения завершилась с exit 0.

Сборка содержит прежние предупреждения Swift в остальных модулях. В ограниченной
среде проверка процессов требует запуска build-app.sh с доступом к метаданным
процессов. Защитные проверки сборочного скрипта сохранены.

## Воспроизводимые проверки

```bash
bash scripts/test-layout-diagnostics.sh all
bash scripts/test-layout-detector.sh all
bash scripts/test-layout-baseline-contracts.sh
bash scripts/test-fluidaudio-offline.sh
```

| Проверка | Результат | Локальный лог |
| --- | --- | --- |
| Контроллер, журнал, правила, presenter, политика обновлений | 168 проверок, 0 ошибок, exit 0 | `logs/layout-diagnostics.log` |
| Настоящий LayoutDetector с реальными словарями | 42 проверки, 0 ошибок, exit 0 | `logs/layout-detector.log` |
| Нативные действия AppKit | 22 проверки, 0 ошибок, exit 0 | `logs/layout-native-actions.log` |
| Контракты словарей и офлайн-зависимостей | 6 проверок, exit 0 | `logs/layout-baseline-contracts.log` |
| Отказ FluidAudio от загрузок в офлайне | 6 проверок, 0 ошибок, exit 0 | `logs/fluidaudio-offline.log` |
| Пустой/неизвестный набор, ошибочное утверждение | 5 проверок, exit 0 | `logs/harness-contracts.log` |

`reviewed-cases.json` прогоняется на настоящем детекторе: до применения, после
применения keep/force, после пересоздания ExceptionStore, после удаления.
Для каждой пары используются отдельные UserDefaults. Ошибочное утверждение
возвращает 1, пустой и неизвестный наборы возвращают 2, успешный набор возвращает 0.
Логи в `logs/` исключены из git и сохраняются в рабочем дереве.

## Безопасный просмотр и нативные действия

Preview входит до AppDelegate и системных guard, использует временный каталог,
отдельные AppSettings/ExceptionStore и три демонстрационных кейса. Он не запускает
Engine или event tap, не занимает блокировку обычного приложения и удаляет свои
временные настройки при завершении.

```bash
KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_JOURNAL_PREVIEW_INTERACTIVE=1 \
  ./Keyboop_local.app/Contents/MacOS/Keyboop

KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_JOURNAL_PREVIEW_CHECK=1 KEYBOOP_UPDATER=1 \
  ./Keyboop_local.app/Contents/MacOS/Keyboop > logs/layout-native-actions.log 2>&1

KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_WINSHOT=1 KEYBOOP_JOURNAL_PREVIEW_PNG=/tmp/keyboop-journal-dark.png \
  ./Keyboop_local.app/Contents/MacOS/Keyboop
KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_WINSHOT=1 KEYBOOP_JOURNAL_PREVIEW_LIGHT=1 \
  KEYBOOP_JOURNAL_PREVIEW_PNG=/tmp/keyboop-journal-light.png \
  ./Keyboop_local.app/Contents/MacOS/Keyboop
```

Нативная проверка нажимает настоящие NSButton, меняет NSPopUpButton через target/action
и редактирует NSTextField с уведомлением делегату. Состояние проверяется в настоящем
хранилище и детекторе. Проверяются подтверждение, отдельное применение, удаление,
блокировка редактирования, фильтры, выключение сбора и подтверждение NSAlert очистки.
Ожидание изменений идёт через callbacks хранилища и готовности представления,
ожидание модального окна ограничено по времени. Пустой прогон не считается успехом.

Снимки демонстрационного окна:
[светлая тема](artifacts/keyboop-journal-light.png),
[тёмная тема](artifacts/keyboop-journal-dark.png).
Это окно настроек приложения, а кейсы в нём демонстрационные.

## Границы проверки и включение на машине

Официальное приложение в `/Applications` не заменялось и не завершалось.
Обычный запуск dev-сборки не выполнялся. Физический набор в TextEdit,
Accessibility, Secure Input и взаимодействие с другими приложениями в этом
прогоне не проверены. Реальные median/p95 задержки и потерянные события не измерены:
event tap не запускался. Cmd+Z отмечается только явно, автоматическое определение
отмены не заявляется.

Для реального использования нужно выдать dev-сборке доступ macOS Accessibility,
затем обычным способом завершить официальный Keyboop и запустить локальный.
Сборки используют общую защиту от одновременного запуска. После запуска открыть
«Журнал раскладки», включить локальный сбор, отметить ошибку, проверить ожидаемое
слово и подтвердить кейс. Для изменения поведения отдельно применить защиту или
принудительную конверсию. Активное правило можно удалить, в том числе после
очистки кейсов. Правила действуют глобально для слова.
