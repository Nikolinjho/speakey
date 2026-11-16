import AppKit

/// Просмотр локального корпуса. На диске остаётся только зашифрованный файл.
final class PersonalCorpusWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PersonalCorpusWindowController()
    private let corpus: PersonalCorpus
    private let beforeDelete: () -> Void
    private let source = NSPopUpButton()
    private let table = NSTableView()
    private let detail = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let deleteSelected = NSButton()
    private let deleteSource = NSButton()
    private let deleteAll = NSButton()
    private var sourceIDs: [String?] = [nil]
    private var selectedSource: String?
    private var snapshot = PersonalCorpus.Snapshot(records: [], sourceCounts: [:], available: true)
    private var records: [PersonalCorpus.Record] = []
    private var observer: NSObjectProtocol?
    private var loading = false
    private var requestGeneration = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = "dd.MM.yyyy HH:mm 'MSK'"; return f
    }()

    init(corpus: PersonalCorpus = .shared, beforeDelete: @escaping () -> Void = { AutocompletePrefs.invalidateRecording() }) {
        self.corpus = corpus; self.beforeDelete = beforeDelete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.corpusWindowWidth, height: DS.corpusWindowHeight),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.autocomplete("corpusWindowTitle")
        window.minSize = NSSize(width: DS.minWindowWidth, height: DS.defaultWindowHeight)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        observer = NotificationCenter.default.addObserver(forName: PersonalCorpus.changed, object: corpus, queue: .main) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func show(bundleID: String? = nil) {
        selectedSource = bundleID
        window?.center(); showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = DS.sectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DS.contentMargin),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DS.contentMargin),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: DS.contentMargin),
                                     stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DS.contentMargin)])
        source.target = self; source.action = #selector(sourceChanged)
        source.setAccessibilityIdentifier("corpus.source")
        source.setAccessibilityLabel(L10n.autocomplete("corpusSource"))
        let sourceRow = NSStackView(views: [source, NSView()])
        sourceRow.orientation = .horizontal; sourceRow.alignment = .centerY
        stack.addArrangedSubview(sourceRow)
        status.font = .systemFont(ofSize: DS.detailFontSize); status.textColor = .secondaryLabelColor
        status.alignment = .left
        status.setAccessibilityIdentifier("corpus.status"); stack.addArrangedSubview(status)
        for (id, title, width) in [("date", "corpusDate", DS.corpusDateWidth), ("source", "corpusSource", DS.corpusSourceWidth),
                                    ("text", "corpusText", DS.corpusPreviewWidth)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = L10n.autocomplete(title); column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = DS.rowHeight; table.delegate = self; table.dataSource = self
        table.setAccessibilityIdentifier("corpus.records")
        let tableScroll = NSScrollView(); tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = false
        tableScroll.documentView = table
        tableScroll.heightAnchor.constraint(equalToConstant: DS.corpusListHeight).isActive = true
        stack.addArrangedSubview(tableScroll)
        detail.isEditable = false; detail.isRichText = false; detail.isSelectable = true
        detail.font = .systemFont(ofSize: DS.detailFontSize); detail.isHorizontallyResizable = false
        detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.textContainerInset = NSSize(width: DS.itemGap, height: DS.itemGap)
        detail.setAccessibilityIdentifier("corpus.detail")
        detail.setAccessibilityLabel(L10n.autocomplete("corpusText"))
        let detailScroll = NSScrollView(); detailScroll.hasVerticalScroller = true; detailScroll.documentView = detail
        detailScroll.borderType = .bezelBorder
        stack.addArrangedSubview(detailScroll)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = DS.itemGap
        for (button, key, action) in [(deleteSelected, "corpusDeleteSelected", #selector(confirmSelected)),
                                      (deleteSource, "corpusDeleteSource", #selector(confirmSource)),
                                      (deleteAll, "deleteAll", #selector(confirmAll))] {
            button.title = L10n.autocomplete(key); button.bezelStyle = .rounded
            button.controlSize = .small; button.target = self; button.action = action
            button.setAccessibilityIdentifier("corpus.\(key)"); buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateControls()
    }

    func refresh() {
        requestGeneration &+= 1
        let generation = requestGeneration
        loading = true; status.stringValue = L10n.autocomplete("corpusLoading"); updateControls()
        PersonalCorpus.workQueue.async { [weak self] in
            guard let self else { return }
            let value = self.corpus.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.requestGeneration else { return }
                self.snapshot = value; self.loading = false
                self.rebuildSources(); self.applyFilter()
            }
        }
    }
    private func appName(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    private func rebuildSources() {
        let bids = Set(snapshot.sourceCounts.keys).union(selectedSource.map { [$0] } ?? []).sorted()
        sourceIDs = [nil] + bids.map(Optional.some)
        source.removeAllItems(); source.addItem(withTitle: L10n.autocomplete("corpusAllSources"))
        for bid in bids { source.addItem(withTitle: "\(appName(bid)) (\(snapshot.sourceCounts[bid] ?? 0))") }
        source.selectItem(at: sourceIDs.firstIndex { $0 == selectedSource } ?? 0)
    }
    private func applyFilter() {
        let selected = selectedRecord?.id
        records = snapshot.records.filter { selectedSource == nil || $0.bundleID == selectedSource }
        table.reloadData()
        if let selected, let index = records.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        detail.string = selectedRecord?.text ?? ""
        status.stringValue = !snapshot.available ? L10n.autocomplete("corpusUnavailable")
            : records.isEmpty ? L10n.autocomplete("corpusEmpty")
            : String(format: L10n.autocomplete("corpusCount"), records.count)
        updateControls()
    }
    private var selectedRecord: PersonalCorpus.Record? {
        records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
    }
    private func updateControls() {
        let ready = !loading && snapshot.available
        source.isEnabled = !loading
        deleteSelected.isEnabled = ready && selectedRecord != nil
        deleteSource.isEnabled = ready && selectedSource != nil && !records.isEmpty
        deleteAll.isEnabled = ready && !snapshot.records.isEmpty
    }
    @objc private func sourceChanged() {
        guard sourceIDs.indices.contains(source.indexOfSelectedItem) else { return }
        selectedSource = sourceIDs[source.indexOfSelectedItem]; applyFilter()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = formatter.string(from: Date(timeIntervalSince1970: record.date))
        case "source": text = appName(record.bundleID)
        default: text = String(record.text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: DS.detailFontSize); label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        detail.string = selectedRecord?.text ?? ""; updateControls()
    }
    @objc private func confirmSelected() {
        guard let id = selectedRecord?.id else { return }
        confirm("corpusDeleteSelected") { $0.remove(id: id) }
    }
    @objc private func confirmSource() {
        guard let bid = selectedSource else { return }
        confirm("corpusDeleteSource") { $0.remove(bundleID: bid) }
    }
    @objc private func confirmAll() { confirm("deleteAll") { $0.removeAll() } }

    private func confirm(_ title: String, operation: @escaping (PersonalCorpus) -> Bool) {
        guard let window, !loading, snapshot.available else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.autocomplete(title)
        alert.informativeText = L10n.autocomplete(title == "deleteAll" ? "deleteAllText" : "corpusDeleteWarning")
        alert.addButton(withTitle: L10n.autocomplete("deleteAllOk"))
        alert.addButton(withTitle: L10n.autocomplete("cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.beforeDelete()
            self.loading = true; self.updateControls()
            PersonalCorpus.workQueue.async {
                let ok = operation(self.corpus)
                DispatchQueue.main.async {
                    self.loading = false
                    if ok { self.refresh() }
                    else { self.status.stringValue = L10n.autocomplete("corpusWriteFailed"); self.updateControls() }
                }
            }
        }
    }
}
