# Speakey

Локальное приложение для macOS: исправление раскладки, голосовой набор,
сниппеты и история ввода. Замены печатаются напрямую, без подмены буфера обмена.
Распознавание речи работает на Mac через Whisper или Parakeet.

## Сборка

Apple Silicon: macOS 14+. Intel: macOS 13+, только Whisper.
Нужны Xcode Command Line Tools, CMake и зависимости в `vendor/`.

```bash
bash scripts/setup-layout-diagnostics-build.sh
bash scripts/fetch-rightlayout-model.sh
bash build-app.sh
```

Сборка использует постоянный сертификат из Keychain по отпечатку
`749281C2A0E19FC82DA85918A28F5BCC195C5597`.
На другой машине выбери свой постоянный сертификат через `SPEAKEY_SIGN_ID`.
Ad-hoc подпись запрещена: она нарушает стабильность разрешений macOS.

```bash
SPEAKEY_SIGN_ID='имя или SHA-1 сертификата' bash build-app.sh
SPEAKEY_BUILD_APP=/private/tmp/Speakey_check.app bash build-app.sh
bash install-local.sh
```

Установленное приложение: `/Applications/Speakey.app`, executable `Speakey`.
Bundle ID локальной сборки: `dev.speakey.app.dev`, релизной: `dev.speakey.app`.
После первой установки разреши универсальный доступ, мониторинг ввода и микрофон.
Локальная сборка не содержит механизма автообновления.

Whisper скачивается по явному действию из pinned HuggingFace с проверкой SHA-256.
Parakeet использует официальный загрузчик FluidAudio. Аудио, текст и журнал
раскладки не отправляются на сервер. Формы отправки отзывов и пожертвований нет.

## Данные

Настройки хранятся в домене bundle ID, история и голосовые модели –
`~/Library/Application Support/Speakey`. Журнал раскладки находится в
`~/Library/Application Support/dev.speakey.app.dev/LayoutDiagnostics`.
История и аудиозаписи шифруются. Перед переносом сохраняй вместе зашифрованные
данные и ключ, иначе восстановить историю не получится.

Нейромодель раскладки работает в режиме наблюдения. Подтверждение ошибки
сохраняет ожидаемое слово, применение глобального правила выполняется отдельно.
Автоматического дообучения весов нет.

## Проверки

```bash
bash scripts/test-layout-diagnostics.sh all
bash scripts/test-layout-detector.sh all
bash scripts/test-neural-layout.sh all
python3 Tests/NeuralLayout/SigningPipelineTests.py
bash scripts/test-compact-settings.sh /private/tmp/Speakey_check.app
```

## Лицензии

MIT, полный текст и обязательные уведомления об авторстве – в `LICENSE`.
Лицензии используемых библиотек, моделей и словарей – в `THIRD_PARTY.md`.
Оба файла включаются в собранное приложение.
