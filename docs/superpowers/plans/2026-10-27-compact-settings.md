# Compact settings implementation plan

**Goal:** реализовать выбранный первый макет в нативном AppKit-окне.

**Architecture:** изменить размеры и общие строки в SettingsWindow.swift, компактно оформить NeuralLayoutSettingsView, уплотнить журнал. Сохранить существующие контроллеры, действия и локализацию.

**Tech stack:** Swift, AppKit, существующий изолированный preview.

## Задачи

- [x] Проверить исходный размер отдельным нативным прогоном. Расширить LayoutJournalPreviewCheck проверкой компактного окна.
- [x] Настроить окно 760 × 560, меню 172, колонку 528, поля 20. Отдельно сохранять высоту новой компоновки. Сохранить простой экран и доступность всех разделов.
- [x] Уплотнить подробные строки до 35 пунктов, перенести обычные пояснения в справку, оставить причины недоступности видимыми.
- [x] Перенести модель под основные настройки. Заменить радио-кнопки списком с недоступным assist, добавить раскрываемые пояснения. Адаптировать существующие проверки выбора режима.
- [x] Уплотнить журнал и проверить фильтры, формы и полный цикл существующего нативного теста.
- [x] Выполнить полную сборку в /private/tmp/Keyboop_compact_settings.app. Запустить KEYBOOP_NEURAL_PREVIEW_CHECK и KEYBOOP_JOURNAL_PREVIEW_CHECK в обеих темах, проверить строгую подпись и git diff --check.
- [x] Сохранить снимки реального окна и протокол проверки. Передать готовый результат без замены установленной версии, если установка отдельно не запрошена.

## Команды проверки

```bash
KEYBOOP_BUILD_APP=/private/tmp/Keyboop_compact_settings.app bash build-app.sh
KEYBOOP_NEURAL_PREVIEW_CHECK=1 KEYBOOP_PRO=1 /private/tmp/Keyboop_compact_settings.app/Contents/MacOS/Keyboop
KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_JOURNAL_PREVIEW_CHECK=1 KEYBOOP_PRO=1 /private/tmp/Keyboop_compact_settings.app/Contents/MacOS/Keyboop
codesign --verify --deep --strict /private/tmp/Keyboop_compact_settings.app
git diff --check
```

Повторить preview со значением KEYBOOP_JOURNAL_PREVIEW_LIGHT=1. Все тестовые данные и defaults изолированы от установленного приложения. Размер и размещение проверять по рамке настоящего окна, а не только по составному снимку всей страницы.
