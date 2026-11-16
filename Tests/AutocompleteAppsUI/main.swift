import AppKit
import CryptoKit

struct Failure: Error { let message: String }
var checks = 0
func check(_ name: String, _ value: @autoclosure () -> Bool) throws {
    checks += 1
    guard value() else { throw Failure(message: name) }
    print("PASS: \(name)")
}
func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
func find<T: NSView>(_ root: NSView, _ id: String, _ type: T.Type) throws -> T {
    guard let view = allViews(root).first(where: { $0.accessibilityIdentifier() == id }) as? T else { throw Failure(message: "Нет контрола \(id)") }
    return view
}
@MainActor func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw Failure(message: "Истекло ожидание") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
@MainActor func run() async throws {
    let theme = CommandLine.arguments[1]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speakey-apps-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "speakey-apps-ui-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AutocompleteAppStore(defaults: defaults)
    for bid in ["com.apple.TextEdit", "com.microsoft.VSCode", "com.apple.Terminal"] { store.register(bid) }
    let key = SymmetricKey(data: Data(repeating: 5, count: 32))
    let corpus = PersonalCorpus(directory: directory, keyProvider: { key })
    corpus.add("Тестовая запись для первого приложения, личных данных здесь нет", bundleID: "com.apple.TextEdit")
    corpus.add("Другая тестовая запись для второго приложения с отдельным источником", bundleID: "com.microsoft.VSCode")
    let apps = AutocompleteAppsView(store: store, corpus: corpus, openCorpus: { _ in })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.simpleWindowWidth, height: DS.defaultWindowHeight),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true
    window.contentView = scroll
    apps.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = apps
    apps.widthAnchor.constraint(equalToConstant: DS.contentWidth).isActive = true
    window.makeKeyAndOrderFront(nil); window.layoutIfNeeded(); apps.layoutSubtreeIfNeeded()
    let enabled = try find(apps, "ac.app.com.apple.TextEdit.enabled", NSPopUpButton.self)
    try check("Приложение начинает с наследования", enabled.indexOfSelectedItem == 0 && enabled.itemTitle(at: 0).contains(L10n.autocomplete("setting.on")))
    enabled.selectItem(at: 2); _ = enabled.sendAction(enabled.action, to: enabled.target)
    try check("Явный запрет применяется", !store.isEnabled("com.apple.TextEdit"))
    enabled.selectItem(at: 0); _ = enabled.sendAction(enabled.action, to: enabled.target)
    try check("Наследование возвращается", store.enabledOverride("com.apple.TextEdit") == nil && store.isEnabled("com.apple.TextEdit"))
    let recording = try find(apps, "ac.app.com.apple.TextEdit.record", NSPopUpButton.self)
    recording.selectItem(at: 2); _ = recording.sendAction(recording.action, to: recording.target)
    try check("Запись запрещается отдельно", !store.recordAllowed("com.apple.TextEdit"))
    recording.selectItem(at: 1); _ = recording.sendAction(recording.action, to: recording.target)
    try check("Разрешение не отменяет общий запрет", !store.shouldRecord("com.apple.TextEdit", mode: .off, accepted: true))
    let previousTab = AutocompletePrefs.tabEnabled
    defer { AutocompletePrefs.tabEnabled = previousTab }
    AutocompletePrefs.tabEnabled = false
    let inheritedTab = try find(apps, "ac.app.com.apple.TextEdit.tab", NSPopUpButton.self)
    try check("Наследуемая подпись Tab обновляется при общем изменении", inheritedTab.itemTitle(at: 0).contains(L10n.autocomplete("setting.off")))
    let terminal = try find(apps, "ac.app.com.apple.Terminal.enabled", NSPopUpButton.self)
    try check("Терминал нельзя включить", !terminal.isEnabled)
    let editor = try find(apps, "ac.app.com.microsoft.VSCode.enabled", NSPopUpButton.self)
    try check("Редактор наследует выключенное состояние", editor.indexOfSelectedItem == 0 && editor.itemTitle(at: 0).contains(L10n.autocomplete("setting.off")))
    let search = try find(apps, "ac.apps.search", NSSearchField.self)
    search.stringValue = "no-app-matches-this"
    apps.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    let empty = try find(apps, "ac.apps.empty", NSTextField.self)
    try check("Поиск показывает отсутствие совпадений", empty.stringValue == L10n.autocomplete("appsNoMatches"))
    search.stringValue = ""; apps.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    apps.layoutSubtreeIfNeeded()
    let geometry = allViews(apps).filter { $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }.filter {
        let r = apps.convert($0.bounds, from: $0); return r.minX < -1 || r.maxX > apps.bounds.width + 1
    }
    let cards = allViews(apps).filter { $0 is CardView }
    try check("Карточки приложений занимают всю колонку", cards.allSatisfy { abs($0.bounds.width - apps.bounds.width) <= 1 })
    try check("Настройки приложений помещаются по ширине", geometry.isEmpty)

    let viewer = PersonalCorpusWindowController(corpus: corpus, beforeDelete: {})
    viewer.show()
    guard let root = viewer.window?.contentView else { throw Failure(message: "Нет окна корпуса") }
    let table = try find(root, "corpus.records", NSTableView.self)
    try await waitUntil { table.numberOfRows == 2 }
    try check("Корпус показывает две тестовые записи", table.numberOfRows == 2)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let detail = try find(root, "corpus.detail", NSTextView.self)
    try check("Выбор показывает полный текст", detail.string.contains("тестовая запись"))
    let filter = try find(root, "corpus.source", NSPopUpButton.self)
    filter.selectItem(at: 1); _ = filter.sendAction(filter.action, to: filter.target)
    try check("Фильтр оставляет одну запись приложения", table.numberOfRows == 1)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let remove = try find(root, "corpus.corpusDeleteSelected", NSButton.self)
    remove.performClick(nil)
    try await waitUntil { viewer.window?.attachedSheet != nil }
    let sheet = viewer.window!.attachedSheet!
    let cancel = allViews(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == L10n.autocomplete("cancel") }!
    cancel.performClick(nil)
    try await waitUntil { viewer.window?.attachedSheet == nil }
    try check("Отмена удаления сохраняет обе записи", corpus.count == 2)
    remove.performClick(nil)
    try await waitUntil { viewer.window?.attachedSheet != nil }
    let confirm = allViews(viewer.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == L10n.autocomplete("deleteAllOk") }!
    confirm.performClick(nil)
    try await waitUntil { table.numberOfRows == 0 }
    try check("Выбранная запись удалена, другой источник сохранён", corpus.count == 1)
    let status = try find(root, "corpus.status", NSTextField.self)
    try check("Пустой источник объяснён", status.stringValue == L10n.autocomplete("corpusEmpty"))
    filter.selectItem(at: 0); _ = filter.sendAction(filter.action, to: filter.target)
    try check("Общий список показывает оставшийся источник", table.numberOfRows == 1)

    let artifacts = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(theme)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    func capture(_ target: NSWindow, name: String) throws {
        target.makeKeyAndOrderFront(nil)
        target.displayIfNeeded()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(target.windowNumber), artifacts.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit()
        try check("Снимок \(name) сохранён", process.terminationStatus == 0)
    }
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    viewer.window!.layoutIfNeeded()
    try capture(viewer.window!, name: "corpus")
    window.layoutIfNeeded(); apps.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, apps.bounds.height - scroll.contentView.bounds.height)))
    try capture(window, name: "apps")

    // Удаление по источнику и полной истории работают через настоящие подтверждения.
    filter.selectItem(at: filter.numberOfItems - 1); _ = filter.sendAction(filter.action, to: filter.target)
    let sourceDelete = try find(root, "corpus.corpusDeleteSource", NSButton.self)
    sourceDelete.performClick(nil)
    try await waitUntil { viewer.window?.attachedSheet != nil }
    allViews(viewer.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == L10n.autocomplete("deleteAllOk") }!.performClick(nil)
    try await waitUntil { corpus.count == 0 && table.numberOfRows == 0 }
    try check("Удаление источника очищает только его записи", corpus.count == 0)
    corpus.add("Новая тестовая запись после удаления для проверки полной очистки", bundleID: "com.apple.TextEdit")
    corpus.add("Вторая запись после удаления из другого тестового приложения", bundleID: "com.microsoft.VSCode")
    filter.selectItem(at: 0); _ = filter.sendAction(filter.action, to: filter.target)
    try await waitUntil { table.numberOfRows == 2 }
    let allDelete = try find(root, "corpus.deleteAll", NSButton.self)
    allDelete.performClick(nil)
    try await waitUntil { viewer.window?.attachedSheet != nil }
    allViews(viewer.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == L10n.autocomplete("deleteAllOk") }!.performClick(nil)
    try await waitUntil { table.numberOfRows == 0 && corpus.count == 0 }
    try check("Пустой корпус отключает полную очистку", !allDelete.isEnabled)

    // Недоступный ключ не показывается как пустая доступная история.
    let unavailable = PersonalCorpus(directory: directory.appendingPathComponent("no-key"), keyProvider: { nil })
    let unavailableViewer = PersonalCorpusWindowController(corpus: unavailable, beforeDelete: {})
    unavailableViewer.show()
    let unavailableRoot = unavailableViewer.window!.contentView!
    let unavailableStatus = try find(unavailableRoot, "corpus.status", NSTextField.self)
    try await waitUntil { unavailableStatus.stringValue == L10n.autocomplete("corpusUnavailable") }
    let unavailableDelete = try find(unavailableRoot, "corpus.deleteAll", NSButton.self)
    try check("Недоступное хранилище объяснено", !unavailableDelete.isEnabled)
    unavailableViewer.close()

    // Отказ диска сохраняет запись в таблице и показывает ошибку.
    var refuse = false
    let failing = PersonalCorpus(directory: directory.appendingPathComponent("write-error"), keyProvider: { key }, writer: { data, url in
        if refuse { throw CocoaError(.fileWriteNoPermission) }
        try PersonalCorpus.atomicWrite(data, to: url)
    })
    failing.add("Тестовая запись для проверки ошибки записи зашифрованного корпуса", bundleID: "com.apple.TextEdit")
    let failureViewer = PersonalCorpusWindowController(corpus: failing, beforeDelete: {})
    failureViewer.show()
    let failureRoot = failureViewer.window!.contentView!
    let failureTable = try find(failureRoot, "corpus.records", NSTableView.self)
    try await waitUntil { failureTable.numberOfRows == 1 }
    refuse = true
    let failureDelete = try find(failureRoot, "corpus.deleteAll", NSButton.self)
    failureDelete.performClick(nil)
    try await waitUntil { failureViewer.window?.attachedSheet != nil }
    allViews(failureViewer.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == L10n.autocomplete("deleteAllOk") }!.performClick(nil)
    let failureStatus = try find(failureRoot, "corpus.status", NSTextField.self)
    try await waitUntil { failureStatus.stringValue == L10n.autocomplete("corpusWriteFailed") }
    try check("Ошибка удаления сохраняет таблицу", failureTable.numberOfRows == 1 && failing.count == 1)
    failureViewer.close()
    viewer.close(); window.close()
    print("autocomplete apps UI (\(theme)): \(checks) checks, 0 failures")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: CommandLine.arguments[1] == "light" ? .aqua : .darkAqua)
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("FAIL: \(error)"); exit(1) }
}
app.run()
