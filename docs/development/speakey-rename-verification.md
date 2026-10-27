# Переименование приложения в Speakey

Название Speakey установлено в шапке настроек, заголовках окон, меню, баннерах, текущих локализованных текстах и метаданных приложения. Обновлены имена пользовательских экспортов и диагностических отчётов. Пример словаря произношения использует «спики» и Speakey.

Обычная сборка создаёт Speakey.app. Локальный установочный скрипт использует то же имя. Внутренний bundle ID, домен настроек, пути данных и постоянный сертификат сохранены.

## Проверка

Полная сборка завершилась с кодом 0. В каждой из двух тем прошли 36 нативных проверок настроек и 29 проверок журнала, без ошибок. Проверка синтаксиса сборочных скриптов и git diff --check завершилась с кодом 0. Независимое ревью не оставило открытых замечаний.

```bash
KEYBOOP_BUILD_APP=/private/tmp/Speakey_renamed.app bash build-app.sh
bash scripts/test-compact-settings.sh /private/tmp/Speakey_renamed.app /private/tmp/speakey-final-name-verification
bash -n build-app.sh install-local.sh
codesign --verify --deep --strict /Applications/Speakey.app
```

## Установка

Переход на /Applications/Speakey.app выполнен 27 октября 2026 года в 19:26:31 MSK. Финальная сборка установлена в 19:30:52 MSK. Прежний /Applications/Keyboop_local.app убран из Applications и сохранён в резервной копии.

После установки NSRunningApplication возвращает имя Speakey, а оконный сервер – заголовок Speakey. Снимок сделан с настоящего окна установленного процесса 29646. Проверен запуск движка: engine STARTED ok, AX=true и InputMon=true. Разрешения сохранились после смены пути и имени.

Настройки и журнал до запуска сохранены побайтно. Все прежние ID журнала сохранены, режим observe и включённый сбор остались прежними. Финальная резервная копия находится в ~/Library/Application Support/KeyboopLocalBackups/speakey-rename-final-20261027-193052-MSK. Копия до смены пути – в ~/Library/Application Support/KeyboopLocalBackups/speakey-rename-20261027-192630-MSK. DMG не обновлялся.

[Снимок установленного приложения](artifacts/speakey-rename/installed-settings.png). [Протокол установки](artifacts/speakey-rename/installation.json).
