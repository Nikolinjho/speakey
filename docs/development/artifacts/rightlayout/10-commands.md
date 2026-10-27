# Команды проверки

Рабочий каталог: `/Users/itsnikoko/keybop local`. Дата: 27.10.2026, MSK.

```bash
bash scripts/test-neural-layout.sh all
# Включает четыре проверки production factory во временном bundle.
bash scripts/test-layout-diagnostics.sh all
bash scripts/test-layout-detector.sh all
bash scripts/test-layout-baseline-contracts.sh
bash scripts/test-rightlayout-resource.sh
bash scripts/evaluate-neural-layout.sh --verify
bash scripts/benchmark-neural-layout.sh
bash scripts/benchmark-neural-layout.sh --smoke
bash scripts/benchmark-neural-input.sh
KEYBOOP_RELEASE=0 KEYBOOP_SIGN_ID=- KEYBOOP_BUILD_APP=/private/tmp/Keyboop_rightlayout.app bash build-app.sh
python3 docs/development/artifacts/rightlayout/10-verify-bundle.py
```

Проверка модели непосредственно из bundle:

```bash
swiftc -O -swift-version 5 -framework CoreML -framework ApplicationServices \
  Sources/Keyboop/NeuralLayoutTypes.swift Sources/Keyboop/RightLayoutModel.swift \
  Sources/Keyboop/NeuralLayoutCoordinator.swift Tools/NeuralLayoutBenchmark/main.swift \
  -o /tmp/keyboop-task10-bundle-benchmark
/tmp/keyboop-task10-bundle-benchmark \
  /private/tmp/Keyboop_rightlayout.app/Contents/Resources/RightLayout/LayoutClassifier.mlmodelc \
  Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel --smoke
```

Нативная проверка выполняется до AppDelegate и Engine. Для светлой темы дополнительно задаётся `KEYBOOP_JOURNAL_PREVIEW_LIGHT=1`.

```bash
KEYBOOP_NEURAL_PREVIEW_CHECK=1 \
KEYBOOP_NEURAL_PREVIEW_SETTINGS_PNG="$PWD/docs/development/artifacts/rightlayout/10-settings-dark.png" \
KEYBOOP_NEURAL_PREVIEW_JOURNAL_PNG="$PWD/docs/development/artifacts/rightlayout/10-journal-dark.png" \
/private/tmp/Keyboop_rightlayout.app/Contents/MacOS/Keyboop

KEYBOOP_NEURAL_PREVIEW_CHECK=1 KEYBOOP_JOURNAL_PREVIEW_LIGHT=1 \
KEYBOOP_NEURAL_PREVIEW_SETTINGS_PNG="$PWD/docs/development/artifacts/rightlayout/10-settings-light.png" \
KEYBOOP_NEURAL_PREVIEW_JOURNAL_PNG="$PWD/docs/development/artifacts/rightlayout/10-journal-light.png" \
/private/tmp/Keyboop_rightlayout.app/Contents/MacOS/Keyboop

KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_JOURNAL_PREVIEW_CHECK=1 \
/private/tmp/Keyboop_rightlayout.app/Contents/MacOS/Keyboop

powermetrics --samplers cpu_power -n 1 -i 1000
```

`powermetrics` завершился с кодом 1: требуется superuser. Энергопотребление не измерено.

CoreML compiler потребовал запуск вне файлового sandbox: не смог создать рабочий каталог в системном temp. Повторные разрешённые запуски использовали тот же скрипт без изменения TCC.

Первый полный benchmark завершился кодом 133: dummy прошёл пять минут, во время CPU-фазы сработал underflow при повторном чтении часов. Его незавершённая CPU-фаза не считается проверкой. Текущий цикл вычитает единственный сохранённый timestamp после проверки границы. Короткий smoke проверил исправленный цикл, полный повтор имеет отдельный журнал `10-benchmark.log`. SHA исходников и исполняемого файла полного повтора сохранены отдельно.
