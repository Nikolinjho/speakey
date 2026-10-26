import AppKit

// Вызывается только ранним изолированным preview, без AppDelegate и перехвата клавиатуры.
@MainActor
enum LayoutJournalPreviewCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func run(window: SettingsWindowController, runtime: LayoutDiagnosticsRuntime) async throws -> Int {
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
        let initial = await snapshot()
        guard let item = initial.cases.first(where: { $0.typed == "ghbdtn" && $0.expected == "привет" }) else {
            throw Failure(description: "Нет исходного кандидата")
        }
        try check("Исходные три кандидата без активных правил", initial.cases.count == 3 && initial.rules.isEmpty && initial.cases.allSatisfy { $0.status == .candidate })
        try check("Видны три настоящие строки", rowCount() == 3)
        try select("journal.filter.kind", 2)
        try check("Фильтр вида оставляет одну строку", rowCount() == 1)
        try select("journal.filter.kind", 0)
        try select("journal.filter.app", 1)
        try check("Фильтр приложения оставляет Safari", rowCount() == 1)
        try select("journal.filter.app", 0)
        try select("journal.filter.sort", 1)
        try check("Сортировка сохраняет три строки", rowCount() == 3)
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
        try check("Очистка убирает кейсы и временные следы", cleared.cases.isEmpty && runtime.recent.isEmpty && runtime.frozenRecent.isEmpty)
        try check("После очистки правило остаётся видимым", cleared.rules.contains { $0.status == .active } && (try control("journal.remove", NSButton.self)).isEnabled && rowCount() == 0)
        try click("journal.remove")
        await settle()
        try check("После очистки правило можно удалить", LayoutDetector.decide(word: "ghbdtn", exceptions: .shared) == .convert(toCyrillic: true))
        print("\(count) нативных проверок, 0 ошибок")
        return count
    }
}
