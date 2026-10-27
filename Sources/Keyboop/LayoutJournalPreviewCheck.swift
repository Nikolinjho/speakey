import AppKit

// Вызывается только ранним изолированным preview, без AppDelegate и перехвата клавиатуры.
@MainActor
enum LayoutJournalPreviewCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func run(window: SettingsWindowController, runtime: LayoutDiagnosticsRuntime, directory: URL) async throws -> Int {
        var count = 0
        func check(_ name: String, _ value: Bool) throws {
            guard value else { throw Failure(description: name) }
            count += 1; print("PASS: \(name)")
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func allViews() -> [NSView] { window.window?.contentView.map(views) ?? [] }
        func control<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
            guard let view = allViews().first(where: { $0.accessibilityIdentifier() == id }) as? T else {
                throw Failure(description: "Не найден контрол \(id)")
            }
            return view
        }
        func click(_ id: String) throws {
            let button = try control(id, NSButton.self)
            guard button.isEnabled else { throw Failure(description: "Кнопка выключена: \(id)") }
            button.performClick(nil)
        }
        func select(_ id: String, _ index: Int) throws {
            let popup = try control(id, NSPopUpButton.self)
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        func snapshot() async -> LayoutJournalSnapshot {
            await withCheckedContinuation { continuation in runtime.store.snapshot { continuation.resume(returning: $0) } }
        }
        func settle() async {
            await withCheckedContinuation { continuation in runtime.store.flush { _ in continuation.resume() } }
            await withCheckedContinuation { continuation in window.whenLayoutJournalReady { continuation.resume() } }
        }
        func edit(_ text: String) throws {
            let field = try control("journal.expected", NSTextField.self)
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
        func rowCount() -> Int { allViews().filter { $0.accessibilityIdentifier().hasPrefix("journal.case.") == true }.count }
        await settle()
        try check("Локальная сборка запрещает апдейтер", !LocalBuildPolicy.updatesAllowed)
        UpdaterController.shared.start()
        UpdaterController.shared.checkNow()
        UpdaterController.shared.automaticChecks = true
        try check("Ручная проверка и KEYBOOP_UPDATER не включают обновления", !UpdaterController.shared.automaticChecks)
        let decisions = await snapshot()
        let stream = try control("journal.stream", NSSegmentedControl.self)
        func selectStream(_ index: Int) {
            stream.selectedSegment = index
            _ = stream.sendAction(stream.action, to: stream.target)
        }
        func observationRows() -> Int {
            allViews().filter { $0.accessibilityIdentifier().hasPrefix("journal.observation.") == true && $0 is NSButton }.count
        }
        try check("По умолчанию видны четыре сохранённых решения", stream.selectedSegment == 0 && decisions.observations.count == 4 && observationRows() == 4)
        try select("journal.filter.dictionary", LayoutDictionaryMatch.allCases.firstIndex(of: .neither)! + 1)
        try check("Настоящий фильтр словаря показывает жжжж без совпадений", observationRows() == 1 && decisions.observations.contains { $0.typed == "жжжж" && $0.alternative == ";;;;" && $0.dictionaryMatch == .neither })
        try select("journal.filter.dictionary", 0)
        try check("Пунктуация сохранена с подтверждённой заменой", decisions.observations.contains { $0.typed == "[kt," && $0.proposed == "хлеб" && $0.dictionaryMatch == .alternative && $0.submission == .submitted })
        let reopened = LayoutJournalStore(directory: directory)
        let disk = await withCheckedContinuation { continuation in reopened.snapshot { continuation.resume(returning: $0) } }
        guard let old = disk.observations.first(where: { $0.typed == "дд" }) else { throw Failure(description: "Нет решения на диске") }
        try check("Старое решение переживает открытие хранилища без временной связи", ProcessInfo.processInfo.systemUptime - old.uptime > 10 && !runtime.recent.contains { $0.id == old.id })
        try click("journal.observation.\(old.id)")
        let expectation = try control("journal.observation.expected", NSTextField.self)
        expectation.stringValue = "ll"
        try click("journal.observation.mark")
        await settle()
        let marked = await snapshot()
        try check("Нативная отметка старого решения создаёт один кейс", marked.cases.contains { $0.typed == "дд" && $0.expected == "ll" && $0.count == 1 } && marked.markedObservationIDs.contains(old.id))
        runtime.controller.mark(observation: old, expected: "ll", kind: .missedConversion)
        await settle()
        let duplicate = await snapshot()
        try check("Повторная отметка не увеличивает счётчик", duplicate.cases.first { $0.typed == "дд" }?.count == 1)
        let buffer = KeystrokeBuffer()
        buffer.append("дд")
        let sourceID = buffer.currentOccurrenceID!
        let converted = Keymap.convert("дд", toCyrillic: false)
        guard let retyped = runtime.controller.record(occurrenceID: sourceID, bundleID: "com.apple.TextEdit", typed: "дд", proposed: nil, alternative: converted, path: .editing, reason: .editingObserved, action: .keep, complete: false) else { throw Failure(description: "Не записан пропуск") }
        for _ in 0..<2 {
            buffer.backspace()
            runtime.controller.observeRetyping(occurrenceID: buffer.retypingOccurrenceID ?? buffer.currentOccurrenceID, current: buffer.currentWord)
        }
        for letter in converted {
            buffer.append(String(letter))
            runtime.controller.observeRetyping(occurrenceID: buffer.retypingOccurrenceID ?? buffer.currentOccurrenceID, current: buffer.currentWord)
        }
        await settle()
        let corrected = await snapshot()
        try check("Буфер и Keymap сохраняют пропуск дд в ll после удаления и перепечатывания", converted == "ll" && Keymap.convert(converted, toCyrillic: true) == "дд" && corrected.observations.contains { $0.id == retyped.id } && corrected.cases.contains { $0.evidence.contains { $0.observationID == retyped.id && $0.source == .retype } })
        selectStream(1)
        let initial = await snapshot()
        guard let item = initial.cases.first(where: { $0.typed == "ghbdtn" && $0.expected == "привет" }) else {
            throw Failure(description: "Нет исходного кандидата")
        }
        try check("Исходные пять кандидатов без активных правил", initial.cases.count == 5 && initial.rules.isEmpty && initial.cases.allSatisfy { $0.status == .candidate })
        try check("Видны пять настоящих строк", rowCount() == 5)
        try select("journal.filter.kind", 2)
        try check("Фильтр вида оставляет одну строку", rowCount() == 1)
        try select("journal.filter.kind", 0)
        try select("journal.filter.app", 1)
        try check("Фильтр приложения оставляет Safari", rowCount() == 1)
        try select("journal.filter.app", 0)
        try select("journal.filter.sort", 1)
        try check("Сортировка сохраняет пять строк", rowCount() == 5)
        try click("journal.case.\(item.id)")
        try check("Кандидат нельзя применить", !(try control("journal.apply.keep", NSButton.self)).isEnabled && !(try control("journal.apply.force", NSButton.self)).isEnabled)
        try edit("ghbdtn")
        try click("journal.confirm")
        await settle()
        let confirmed = await snapshot()
        try check("Кнопка подтверждает отредактированное ожидание", confirmed.cases.contains { $0.id == item.id && $0.status == .confirmed && $0.expected == "ghbdtn" })
        try check("Подтверждение не меняет детектор", LayoutDetector.decide(word: "ghbdtn", exceptions: .shared) == .convert(toCyrillic: true))
        try edit("ghbdt")
        try check("Несохранённое ожидание выключает применение", !(try control("journal.apply.keep", NSButton.self)).isEnabled)
        try edit("ghbdtn")
        try click("journal.confirm")
        await settle()
        try click("journal.apply.keep")
        await settle()
        let applied = await snapshot()
        try check("Отдельная кнопка создаёт активную квитанцию", applied.rules.contains { $0.sourceCaseID == item.id && $0.status == .active })
        try check("Настоящий детектор сохраняет ghbdtn", LayoutDetector.decide(word: "ghbdtn", exceptions: .shared) == .keep)
        try check("Активное правило блокирует правку", !(try control("journal.expected", NSTextField.self)).isEnabled && !(try control("journal.confirm", NSButton.self)).isEnabled)
        try click("journal.remove")
        await settle()
        try check("Удаление возвращает настоящий детектор", LayoutDetector.decide(word: "ghbdtn", exceptions: .shared) == .convert(toCyrillic: true))
        try click("journal.confirm")
        await settle()
        try click("journal.apply.keep")
        await settle()
        let toggle = try control("journal.collection", NSSwitch.self)
        toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
        await settle()
        let captured = runtime.controller.record(occurrenceID: UUID(), bundleID: "test.app", typed: "hello", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)
        try check("Выключенный сбор не записывает наблюдения", !runtime.enabled && captured == nil && runtime.recent.isEmpty)
        try check("Выключенный сбор отключает ручное добавление", !(try control("journal.add", NSButton.self)).isEnabled)
        toggle.state = .on; _ = toggle.sendAction(toggle.action, to: toggle.target)
        await settle()
        _ = runtime.controller.record(occurrenceID: UUID(), bundleID: "test.app", typed: "hello", proposed: nil, path: .boundary, reason: .detectorKeep, action: .keep, complete: true)
        runtime.freezeRecent()
        try check("Перед очисткой есть временный и замороженный след", !runtime.recent.isEmpty && !runtime.frozenRecent.isEmpty)
        var clickedModal = false
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
            if let modal = NSApp.modalWindow, let root = modal.contentView,
               let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.journal("clear") }) {
                clickedModal = true; timer.invalidate(); button.performClick(nil)
            } else if Date() > deadline { timer.invalidate(); NSApp.abortModal() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        try click("journal.clear")
        timer.invalidate()
        await settle()
        let cleared = await snapshot()
        try check("Подтверждена настоящая модальная очистка", clickedModal)
        try check("Очистка убирает кейсы и временные следы", cleared.cases.isEmpty && cleared.observations.isEmpty && runtime.recent.isEmpty && runtime.frozenRecent.isEmpty)
        try check("После очистки правило остаётся видимым", cleared.rules.contains { $0.status == .active } && (try control("journal.remove", NSButton.self)).isEnabled && rowCount() == 0)
        try click("journal.remove")
        await settle()
        try check("После очистки правило можно удалить", LayoutDetector.decide(word: "ghbdtn", exceptions: .shared) == .convert(toCyrillic: true))
        print("\(count) нативных проверок, 0 ошибок")
        return count
    }
}

final class PreviewNeuralLayoutBackend: NeuralLayoutBackend {
    func predict(_ word: String) throws -> NeuralLayoutScores {
        try NeuralLayoutScores(logits: word == "дд" ? [0, 0, 0, 0, 0, 10, 0, 0, 0] : [0, 0, 0, 10, 0, 0, 0, 0, 0])
    }
}

extension LayoutJournalPreviewCheck {
    static func runNeural(window: SettingsWindowController, diagnostics: LayoutDiagnosticsRuntime,
                          neural: NeuralLayoutRuntime, presentation: NeuralLayoutPresentationStore,
                          defaults: UserDefaults, appearance: NSAppearance.Name) async throws -> Int {
        var count = 0
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw Failure(description: name) }
            count += 1; print("PASS: \(name)")
        }
        let defaultWindow = SettingsWindowController()
        try check("Обычный конструктор настроек создаёт окно", defaultWindow.window?.contentViewController != nil)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func control<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
            guard let root = window.window?.contentView,
                  let value = views(root).first(where: { $0.accessibilityIdentifier() == id }) as? T else {
                throw Failure(description: "Не найден контрол \(id)")
            }
            return value
        }
        func waitReady() async throws {
            let deadline = Date().addingTimeInterval(5)
            while neural.status == .loading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try check("Временный backend загружен", neural.status == .ready)
        }
        func screenshot(_ section: SettingsSection, _ key: String) {
            if let path = ProcessInfo.processInfo.environment[key], let index = SettingsSection.sidebarCases.firstIndex(of: section) {
                window.dumpFullWindow(section: index, to: path, appearance: appearance, selectSection: false)
            }
        }
        try await waitReady()
        let initial = await withCheckedContinuation { continuation in diagnostics.store.snapshot { continuation.resume(returning: $0) } }
        guard let original = initial.observations.first(where: { $0.typed == "дд" }) else {
            throw Failure(description: "Нет исходного решения для модели")
        }
        neural.observe(occurrenceID: original.occurrenceID, word: original.typed, bundleID: original.bundleID, layoutCode: "preview.ru", collecting: true)
        let request = neural.request(occurrenceID: original.occurrenceID, word: original.typed, bundleID: original.bundleID, layoutCode: "preview.ru")
        diagnostics.bindNeuralObservation(original, to: request)
        neural.bind(request, detectorCyrillic: nil)
        var emitted: NeuralLayoutEvidence?
        let deadline = Date().addingTimeInterval(5)
        while emitted == nil && Date() < deadline {
            let snapshot = await withCheckedContinuation { continuation in diagnostics.store.snapshot { continuation.resume(returning: $0) } }
            emitted = snapshot.observations.first(where: { $0.id == original.id })?.neural
            if emitted == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        try check("Настоящие runtime и policy сохраняют отказ профиля и независимое предложение", emitted?.block == .profile && emitted?.mode == .assist && emitted?.proposedCyrillic == false && emitted?.classScores?.count == 9)
        window.show(section: .switching)
        let assist = try control("neural.mode.assist", NSButton.self)
        let status = try control("neural.status", NSTextField.self)
        try check("Нативный статус показывает готовую модель", status.stringValue.contains(L10n.neural("ready")))
        try check("Сохранённый assist виден, но недоступен без качества", assist.state == .on && !assist.isEnabled && status.stringValue.contains(L10n.neural("quality")) && status.stringValue.contains(L10n.neural("effective") + L10n.neural("observe")))
        screenshot(.switching, "KEYBOOP_NEURAL_PREVIEW_SETTINGS_PNG")
        for mode in [NeuralLayoutMode.off, .observe] {
            let button = try control("neural.mode." + mode.rawValue, NSButton.self)
            button.performClick(nil)
            try check("Нативный выбор \(mode.rawValue) сохраняется отдельно от сбора", NeuralLayoutModeSettings.read(defaults) == mode && neural.mode == mode && diagnostics.enabled)
        }
        try await waitReady()
        diagnostics.setEnabled(false)
        try check("Отключение сбора сохраняет работающую модель", neural.mode == .observe && neural.status == .ready)
        diagnostics.setEnabled(true)
        presentation.publish(NeuralLayoutPresentation(mode: .observe, status: .loading, error: nil, assistanceAvailable: false))
        try check("Нативный статус показывает загрузку", status.stringValue.contains(L10n.neural("loading")))
        presentation.publish(NeuralLayoutPresentation(mode: .observe, status: .unavailable, error: "preview-error", assistanceAvailable: false))
        try check("Нативный статус показывает ошибку", status.stringValue.contains("preview-error"))
        window.show(section: .layoutJournal)
        await withCheckedContinuation { continuation in window.whenLayoutJournalReady { continuation.resume() } }
        let proposal = try control("journal.neural.proposal", NSTextField.self)
        let actual = try control("journal.neural.actual", NSTextField.self)
        let reason = try control("journal.neural.reason", NSTextField.self)
        try check("Противоположное предложение модели показано отдельно от keep", proposal.stringValue.contains(L10n.neural("en")) && actual.stringValue.contains(L10n.journal("action.keep")) && reason.stringValue.contains(L10n.neural("quality")))
        screenshot(.layoutJournal, "KEYBOOP_NEURAL_PREVIEW_JOURNAL_PNG")
        print("\(count) нативных проверок модели, 0 ошибок")
        return count
    }
}
