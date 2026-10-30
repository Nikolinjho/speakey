import AppKit
import AVFoundation

private final class SpeechReviewForm: NSStackView {
    override var isFlipped: Bool { true }
}

/// Окно открывает приватные данные только по явному действию пользователя.
final class SpeechReviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let store: SpeechReviewStore
    private let worker = DispatchQueue(label: "dev.speakey.speech-review", qos: .userInitiated)
    private let table = NSTableView()
    private let raw = NSTextView()
    private let reference = NSTextView()
    private let edited = NSTextView()
    private let session = NSTextField(string: "")
    private let split = NSPopUpButton()
    private let silence = NSButton(checkboxWithTitle: L10n.t("review.silence"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var playButton: NSButton!
    private var saveButton: NSButton!
    private var deleteButton: NSButton!
    private var exportButton: NSButton!
    private var refreshButton: NSButton!
    private var cleanupButton: NSButton!
    private var items: [SpeechReviewItem] = []
    private var selectedID: UUID?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var busy = false
    private var hasDocument = false
    private var hasCorrection = false

    init(store: SpeechReviewStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.t("review.title")
        window.minSize = NSSize(width: 860, height: 680)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: L10n.t(key), target: self, action: action)
    }

    private func buildContent() {
        let content = NSStackView()
        content.orientation = .vertical
        content.distribution = .fill
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        window?.contentView = content
        let help = NSTextField(wrappingLabelWithString: L10n.t("review.help"))
        help.textColor = .secondaryLabelColor
        content.addArrangedSubview(help)
        refreshButton = button("review.refresh", #selector(refresh))
        exportButton = button("review.export", #selector(exportConfirmed))
        cleanupButton = button("review.cleanup", #selector(cleanupOrphans))
        let tools = NSStackView(views: [refreshButton, exportButton, cleanupButton])
        tools.spacing = 8
        content.addArrangedSubview(tools)

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16
        content.addArrangedSubview(body)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("example"))
        column.title = L10n.t("review.examples")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        body.addArrangedSubview(list)
        let form = SpeechReviewForm()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        let formScroll = NSScrollView()
        formScroll.hasVerticalScroller = true
        formScroll.documentView = form
        form.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(formScroll)
        playButton = button("review.play", #selector(playAudio))
        form.addArrangedSubview(playButton)
        addEditor(raw, key: "review.raw", height: 95, editable: false, to: form)
        addEditor(reference, key: "review.reference", height: 110, editable: true, to: form)
        addEditor(edited, key: "review.edited", height: 75, editable: true, to: form)
        session.delegate = self
        split.target = self
        split.action = #selector(markEdited)
        silence.target = self
        silence.action = #selector(markEdited)
        session.placeholderString = L10n.t("review.sessionPlaceholder")
        form.addArrangedSubview(NSTextField(labelWithString: L10n.t("review.session")))
        form.addArrangedSubview(session)
        split.addItem(withTitle: L10n.t("review.chooseSplit"))
        for value in ["train", "dev", "test"] {
            split.addItem(withTitle: L10n.t("review.split." + value))
            split.lastItem?.representedObject = value
        }
        form.addArrangedSubview(split)
        form.addArrangedSubview(silence)
        saveButton = button("review.save", #selector(saveConfirmed))
        deleteButton = button("review.delete", #selector(deleteCorrection))
        let actions = NSStackView(views: [saveButton, deleteButton])
        actions.spacing = 8
        form.addArrangedSubview(actions)
        content.addArrangedSubview(status)
        [help, tools, body, status].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        [list, formScroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            help.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            body.widthAnchor.constraint(equalTo: help.widthAnchor),
            list.widthAnchor.constraint(equalToConstant: 230),
            list.heightAnchor.constraint(equalTo: body.heightAnchor),
            formScroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -246),
            formScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            form.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            form.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            status.widthAnchor.constraint(equalTo: help.widthAnchor),
            session.widthAnchor.constraint(equalTo: form.widthAnchor)
        ])
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        updateControls()
    }

    private func addEditor(_ editor: NSTextView, key: String, height: CGFloat, editable: Bool, to stack: NSStackView) {
        stack.addArrangedSubview(NSTextField(labelWithString: L10n.t(key)))
        if editable { editor.delegate = self }
        editor.isEditable = editable
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        stack.addArrangedSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let date = DateFormatter()
        date.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
        date.dateStyle = .short
        date.timeStyle = .short
        let label = NSTextField(wrappingLabelWithString: "\(item.id.uuidString)\n\(date.string(from: item.modified))")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        player?.stop()
        player = nil
        generation = UUID()
        clearDocument()
        guard items.indices.contains(table.selectedRow) else { selectedID = nil; return }
        let id = items[table.selectedRow].id
        selectedID = id
        let token = generation
        status.stringValue = L10n.t("review.loading")
        worker.async { [weak self, store] in
            let result = Result { try store.load(id: id) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.selectedID == id else { return }
                switch result {
                case .success(let document): self.display(document)
                case .failure: self.status.stringValue = L10n.t("review.loadFailed")
                }
            }
        }
    }

    private func clearDocument() {
        hasDocument = false
        hasCorrection = false
        raw.string = ""
        reference.string = ""
        edited.string = ""
        session.stringValue = ""
        split.selectItem(at: 0)
        silence.state = .off
        updateControls()
    }

    private func display(_ document: SpeechReviewDocument) {
        hasDocument = true
        let events = document.snapshot.events.filter { $0.stage == "whisper_raw" || $0.stage == "parakeet_raw" }
        raw.string = events.map { event in
            let engine = event.stage == "whisper_raw" ? "Whisper" : "Parakeet"
            return "\(engine)\n\(event.text ?? "")"
        }.joined(separator: "\n\n")
        if events.isEmpty { raw.string = L10n.t("review.noRaw") }
        if let correction = document.correction {
            hasCorrection = true
            reference.string = correction.reference
            edited.string = correction.editedText
            session.stringValue = correction.sessionID
            if let item = split.itemArray.first(where: { $0.representedObject as? String == correction.split }) {
                split.select(item)
            }
            silence.state = correction.silence ? .on : .off
        }
        status.stringValue = L10n.t(hasCorrection ? "review.saved" : "review.unconfirmed")
        updateControls()
    }

    func textDidChange(_ notification: Notification) { markEdited() }

    func controlTextDidChange(_ notification: Notification) { markEdited() }

    @objc private func markEdited() {
        guard hasDocument, !busy else { return }
        status.stringValue = L10n.t("review.unsaved")
    }

    private func updateControls() {
        playButton?.isEnabled = hasDocument && !busy
        saveButton?.isEnabled = hasDocument && !busy
        deleteButton?.isEnabled = hasCorrection && !busy
        exportButton?.isEnabled = !busy
        refreshButton?.isEnabled = !busy
        cleanupButton?.isEnabled = !busy
        table.isEnabled = !busy
        reference.isEditable = hasDocument && !busy
        edited.isEditable = hasDocument && !busy
        session.isEnabled = hasDocument && !busy
        split.isEnabled = hasDocument && !busy
        silence.isEnabled = hasDocument && !busy
    }

    @objc private func refresh() {
        guard !busy else { return }
        player?.stop()
        player = nil
        generation = UUID()
        selectedID = nil
        clearDocument()
        table.deselectAll(nil)
        let token = generation
        busy = true
        updateControls()
        status.stringValue = L10n.t("review.loading")
        worker.async { [weak self, store] in
            let result = Result { try store.list() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                switch result {
                case .success(let items):
                    self.items = items
                    self.status.stringValue = L10n.t(items.isEmpty ? "review.empty" : "review.select")
                case .failure:
                    self.items = []
                    self.status.stringValue = L10n.t("review.loadFailed")
                }
                self.table.reloadData()
                self.updateControls()
            }
        }
    }

    @objc private func playAudio() {
        guard let id = selectedID, hasDocument, !busy else { return }
        if player?.isPlaying == true { player?.stop(); return }
        let token = generation
        worker.async { [weak self, store] in
            let result = Result { try store.audio(id: id) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.selectedID == id else { return }
                do {
                    self.player = try AVAudioPlayer(data: result.get())
                    guard self.player?.play() == true else { throw CocoaError(.fileReadUnknown) }
                } catch { self.status.stringValue = L10n.t("review.playFailed") }
            }
        }
    }

    @objc private func saveConfirmed() {
        guard let id = selectedID, hasDocument, !busy else { return }
        let sessionID = session.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = reference.string
        let isSilence = silence.state == .on
        guard !sessionID.isEmpty, split.indexOfSelectedItem > 0,
              isSilence ? text.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status.stringValue = L10n.t("review.validation")
            return
        }
        let correction = SpeechReviewCorrection(id: id, reference: text, editedText: edited.string,
                                               sessionID: sessionID, split: split.selectedItem!.representedObject as! String, silence: isSilence)
        performMutation(successKey: "review.saved") { [store] in try store.save(correction) } completion: { [weak self] in
            self?.hasCorrection = true
        }
    }

    @objc private func deleteCorrection() {
        guard let id = selectedID, hasCorrection, !busy else { return }
        performMutation(successKey: "review.deleted") { [store] in try store.removeCorrection(id: id) } completion: { [weak self] in
            self?.hasCorrection = false
            self?.reference.string = ""
            self?.edited.string = ""
            self?.session.stringValue = ""
            self?.split.selectItem(at: 0)
            self?.silence.state = .off
        }
    }

    private func performMutation(successKey: String, operation: @escaping () throws -> Void, completion: @escaping () -> Void) {
        let token = generation
        busy = true
        updateControls()
        worker.async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                switch result {
                case .success:
                    completion()
                    self.status.stringValue = L10n.t(successKey)
                case .failure(let error): self.status.stringValue = self.errorMessage(error, fallback: "review.saveFailed")
                }
                self.updateControls()
            }
        }
    }

    @objc private func cleanupOrphans() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("review.cleanup")
        alert.informativeText = L10n.t("review.cleanupWarning")
        alert.addButton(withTitle: L10n.t("review.cleanupConfirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performMutation(successKey: "review.cleaned") { [store] in
            _ = try store.removeOrphanCorrections()
        } completion: {}
    }

    @objc private func exportConfirmed() {
        guard !busy, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("review.export")
        panel.message = L10n.t("review.exportWarning")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            let output = directory.appendingPathComponent("speech-corpus-" + UUID().uuidString, isDirectory: true)
            let token = self.generation
            self.busy = true
            self.updateControls()
            self.worker.async { [weak self, store = self.store] in
                let result = Result { try store.exportConfirmed(to: output) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false
                    switch result {
                    case .success(let count): self.status.stringValue = String(format: L10n.t("review.exported"), count)
                    case .failure(let error): self.status.stringValue = self.errorMessage(error, fallback: "review.exportFailed")
                    }
                    self.updateControls()
                }
            }
        }
    }

    private func errorMessage(_ error: Error, fallback: String) -> String {
        guard let failure = error as? SpeechReviewStore.Failure else { return L10n.t(fallback) }
        switch failure {
        case .conflictingSplit: return L10n.t("review.conflictingSplit")
        case .missingTrace: return L10n.t("review.missingTrace")
        case .emptyExport: return L10n.t("review.emptyExport")
        case .outputInsideProject: return L10n.t("review.outputInsideProject")
        default: return L10n.t(fallback)
        }
    }

    func windowWillClose(_ notification: Notification) {
        generation = UUID()
        player?.stop()
        player = nil
        busy = false
        selectedID = nil
        clearDocument()
        items = []
        table.reloadData()
    }
}

extension SpeechDiagnostics {
    static func reviewStore() -> SpeechReviewStore {
        SpeechReviewStore(diagnosticsDirectory: reviewDirectory,
                          correctionsDirectory: reviewDirectory.deletingLastPathComponent().appendingPathComponent("speech-corrections", isDirectory: true),
                          keyProvider: existingKeyForExport)
    }
}
