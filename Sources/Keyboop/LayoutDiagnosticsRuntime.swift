import Foundation

extension Notification.Name {
    static let layoutDiagnosticsChanged = Notification.Name("layoutDiagnosticsChanged")
}

final class LayoutDiagnosticsRuntime {
    static let shared = LayoutDiagnosticsRuntime()
    let store: LayoutJournalStore
    let rules: LayoutRuleService
    let controller: LayoutDiagnosticsController
    private(set) var rulesReady = false
    private(set) var lastError: Error?
    private var changeScheduled = false
    var journalEditing = false {
        didSet { if journalEditing != oldValue { controller.resetContext() } }
    }
    let ownBundleID: String

    private init() {
        ownBundleID = Bundle.main.bundleIdentifier ?? "com.keyboop.app"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = LayoutJournalStore(directory: support.appendingPathComponent(ownBundleID).appendingPathComponent("LayoutDiagnostics"))
        self.store = store
        rules = LayoutRuleService(store: store, backend: ExceptionLayoutRuleBackend())
        controller = LayoutDiagnosticsController(enabled: AppSettings.shared.layoutDiagnosticsEnabled, sink: { feedback in
            store.record(feedback) { result in Self.shared.finished(result) }
        })
        controller.onChange = { [weak self] in self?.notifyChange() }
        store.snapshot { [weak self] snapshot in
            if let error = snapshot.loadError { self?.lastError = error; self?.notifyChange() }
        }
        rules.reconcilePending { [weak self] result in
            guard let self else { return }
            if case .success = result { self.rulesReady = true }
            self.finished(result)
        }
    }

    var enabled: Bool { controller.enabled }
    var recent: [LayoutObservation] { controller.recent }
    var frozenRecent: [LayoutObservation] { controller.frozenRecent }
    func setEnabled(_ enabled: Bool) {
        AppSettings.shared.layoutDiagnosticsEnabled = enabled
        controller.setEnabled(enabled)
        notifyChange()
    }
    func freezeRecent() { controller.freezeRecent() }
    func clearTemporaryState() { controller.clearTemporaryState() }
    func bypassesJournal(bundleID: String) -> Bool {
        LayoutDiagnosticsController.bypassesJournal(editing: journalEditing, bundleID: bundleID, ownBundleID: ownBundleID)
    }
    func clearError() { lastError = nil; notifyChange() }
    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.changeScheduled = false
            NotificationCenter.default.post(name: .layoutDiagnosticsChanged, object: nil)
        }
    }
    private func finished(_ result: Result<Void, Error>) {
        if case .failure(let error) = result { lastError = error }
        notifyChange()
    }
}
