# Постоянный журнал решений раскладки

Продолжение локальной доработки по уточнению пользователя 27.10.2026. Выполнение в текущем рабочем дереве `/Users/itsnikoko/keybop local`, ветка `feat/layout-diagnostics`. Используется последовательная реализация с независимым spec и quality review.

## Постоянное хранение наблюдений

**Goal:** Сохранить наблюдения с вариантами раскладки и фактическим словарным статусом без потери старого журнала.

**Files:**
- `Sources/Keyboop/LayoutObservation.swift`
- `Sources/Keyboop/LayoutJournalStore.swift`
- `Tests/LayoutDiagnostics/JournalStoreTests.swift`

**Acceptance Criteria:**
- [ ] JSON прежней версии читается без потери cases/rules, новые поля наблюдения необязательны.
- [ ] Snapshot и полный экспорт содержат сохранённые наблюдения, confirmed-only не экспортирует неподтверждённые решения.
- [ ] Повторная запись id обновляет submission без дубля, terminal acknowledgment не откатывается в pending.
- [ ] Лимиты и права0700/0600 действуют на наблюдения. Clear удаляет наблюдения и случаи, сохраняет receipts.
- [ ] Все новые сценарии показаны RED до реализации и GREEN после.

**Verify:** `bash scripts/test-layout-diagnostics.sh all`

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutObservation.swift",
    "Sources/Keyboop/LayoutJournalStore.swift",
    "Tests/LayoutDiagnostics/JournalStoreTests.swift"
  ],
  "acceptanceCriteria": [
    "JSON прежней версии читается без потери cases/rules, новые поля наблюдения необязательны.",
    "Snapshot и полный экспорт содержат сохранённые наблюдения, confirmed-only не экспортирует неподтверждённые решения.",
    "Повторная запись id обновляет submission без дубля, terminal acknowledgment не откатывается в pending.",
    "Лимиты и права0700/0600 действуют на наблюдения. Clear удаляет наблюдения и случаи, сохраняет receipts.",
    "Все новые сценарии показаны RED до реализации и GREEN после."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh all",
  "userGate": false
}
```

## Сбор решений, перенабор и интерфейс

**Goal:** Показать все оставленные решения и связать дд→ll через полное стирание с пропущенной заменой.

**Files:**
- `Sources/Keyboop/LayoutFeedbackTracker.swift`
- `Sources/Keyboop/LayoutDiagnosticsController.swift`
- `Sources/Keyboop/LayoutDiagnosticsRuntime.swift`
- `Sources/Keyboop/Engine.swift`
- `Sources/Keyboop/LayoutJournalView.swift`
- `Sources/Keyboop/L10n.swift`
- `Tests/LayoutDiagnostics/TrackerTests.swift`
- `Tests/LayoutDiagnostics/ControllerTests.swift`
- `Tests/LayoutDetector/RuleDetectorTests.swift`

**Acceptance Criteria:**
- [ ] Сбор сохраняет keep/blocked/replace решения по завершённым словам и реальные live-попытки, submission обновляет тот же id.
- [ ] Дд→ll и обратная пара после полного стирания фиксируются с пробелом и без него, единожды в том же occurrence/context за четыре секунды.
- [ ] Другая правка, неполное стирание, просрочка, навигация, пауза, Secure Input и выключенный сбор не создают ложный случай.
- [ ] Наличие исходной и альтернативной формы в словарях проверяется настоящими данными, не выдаётся за причину каскада.
- [ ] Постоянные решения доступны в настройках, имеют причину/словарный статус и ручную разметку без TTL. Случаи и решения различимы.
- [ ] Нет JSON/диска/UI и повторного вызова детектора синхронно в event tap. Изменение детектора только через отдельное подтверждённое правило.

**Verify:** `bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all`

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutFeedbackTracker.swift",
    "Sources/Keyboop/LayoutDiagnosticsController.swift",
    "Sources/Keyboop/LayoutDiagnosticsRuntime.swift",
    "Sources/Keyboop/Engine.swift",
    "Sources/Keyboop/LayoutJournalView.swift",
    "Sources/Keyboop/L10n.swift",
    "Tests/LayoutDiagnostics/TrackerTests.swift",
    "Tests/LayoutDiagnostics/ControllerTests.swift",
    "Tests/LayoutDetector/RuleDetectorTests.swift"
  ],
  "acceptanceCriteria": [
    "Сбор сохраняет keep/blocked/replace решения по завершённым словам и реальные live-попытки, submission обновляет тот же id.",
    "Дд→ll и обратная пара после полного стирания фиксируются с пробелом и без него, единожды в том же occurrence/context за четыре секунды.",
    "Другая правка, неполное стирание, просрочка, навигация, пауза, Secure Input и выключенный сбор не создают ложный случай.",
    "Наличие исходной и альтернативной формы в словарях проверяется настоящими данными, не выдаётся за причину каскада.",
    "Постоянные решения доступны в настройках, имеют причину/словарный статус и ручную разметку без TTL. Случаи и решения различимы.",
    "Нет JSON/диска/UI и повторного вызова детектора синхронно в event tap. Изменение детектора только через отдельное подтверждённое правило."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all",
  "userGate": false
}
```

## Проверка и доставка обновления

**Goal:** Проверить нативный интерфейс и доставить исправленную локальную сборку с сохранением пользовательских данных.

**Files:**
- `Sources/Keyboop/LayoutJournalPreviewCheck.swift`
- `Sources/Keyboop/main.swift`
- `docs/development/layout-observability-verification.md`

**Acceptance Criteria:**
- [ ] Нативный preview проверяет сохранённые решения и разметку, missed-перенабор и старые действия с правилами.
- [ ] Полная сборка и codesign --verify --deep --strict проходят, приложение называется Keyboop_local, bundle ID остаётся dev, обновления отключены.
- [ ] Установочный DMG проверен read-only монтированием и подписью вложенного приложения.
- [ ] Только после проверки обновляется /Applications/Keyboop_local.app с резервной копией, сохраняя prefs и журнал. Новая версия запускается.
- [ ] Документ и memora содержат фактические команды и ограничения, непроведённые физические сценарии не называются пройденными.

**Verify:** `bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && codesign --verify --deep --strict Keyboop_local.app`

```json:metadata
{
  "files": [
    "Sources/Keyboop/LayoutJournalPreviewCheck.swift",
    "Sources/Keyboop/main.swift",
    "docs/development/layout-observability-verification.md"
  ],
  "acceptanceCriteria": [
    "Нативный preview проверяет сохранённые решения и разметку, missed-перенабор и старые действия с правилами.",
    "Полная сборка и codesign --verify --deep --strict проходят, приложение называется Keyboop_local, bundle ID остаётся dev, обновления отключены.",
    "Установочный DMG проверен read-only монтированием и подписью вложенного приложения.",
    "Только после проверки обновляется /Applications/Keyboop_local.app с резервной копией, сохраняя prefs и журнал. Новая версия запускается.",
    "Документ и memora содержат фактические команды и ограничения, непроведённые физические сценарии не называются пройденными."
  ],
  "verifyCommand": "bash scripts/test-layout-diagnostics.sh all && bash scripts/test-layout-detector.sh all && codesign --verify --deep --strict Keyboop_local.app",
  "userGate": false
}
```

