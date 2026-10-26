# Просмотр журнала раскладки

Сборка отдельного приложения:

```sh
KEYBOOP_SIGN_ID=- KEYBOOP_BUILD_APP=/tmp/Keyboop-layout-diagnostics.app bash build-app.sh
```

Снимок настоящего раздела настроек:

```sh
KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_WINSHOT=1 \
KEYBOOP_JOURNAL_PREVIEW_PNG=/tmp/keyboop-journal-dark.png \
/tmp/Keyboop-layout-diagnostics.app/Contents/MacOS/Keyboop
```

Для светлой темы добавь `KEYBOOP_JOURNAL_PREVIEW_LIGHT=1`. Для проверки действий в окне добавь `KEYBOOP_JOURNAL_PREVIEW_INTERACTIVE=1`.

Просмотр входит до AppDelegate, системных guard и движка. Он создаёт временный журнал с тремя случаями и отдельный UserDefaults. Настройки слов изолированы. Обычные настройки и установленное приложение не меняются. После выхода временные файлы и настройки удаляются. Принудительное завершение процесса может оставить временный каталог `keyboop-journal-preview-*`.

В журнале сначала подтверждается ожидаемое слово. Глобальное правило применяется отдельной кнопкой. Оно действует во всех приложениях с автокоррекцией. Очистка случаев сохраняет правила. JSON сохраняется только через диалог выбора файла.
