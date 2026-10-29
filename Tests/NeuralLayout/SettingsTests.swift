import Foundation

private final class SettingsBackend: NeuralLayoutBackend {
    func predict(_ word: String) throws -> NeuralLayoutScores {
        try NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
    }
}

enum SettingsTests: DiagnosticSuite {
    static let name = "settings"
    static func run(_ t: DiagnosticTests) {
        let suite = "speakey-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        t.check("Без настройки выбран режим наблюдения", NeuralLayoutModeSettings.read(defaults) == .observe)
        defaults.set("future", forKey: "neuralLayoutMode")
        t.check("Неизвестный режим безопасно выключен", NeuralLayoutModeSettings.read(defaults) == .off)
        defaults.set(true, forKey: "layoutDiagnosticsEnabled")
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: .neuralLayoutModeChanged, object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        for mode in [NeuralLayoutMode.observe, .off, .assist] {
            NeuralLayoutModeSettings.write(mode, to: defaults)
            t.check("Режим \(mode.rawValue) сохраняется после повторного открытия", NeuralLayoutModeSettings.read(UserDefaults(suiteName: suite)!) == mode)
            NeuralLayoutModeSettings.write(mode, to: defaults)
        }
        t.check("Смена режима уведомляет один раз и сохраняет сбор", notifications == 3 && defaults.bool(forKey: "layoutDiagnosticsEnabled"))
        var work: [() -> Void] = []
        var delivery: [() -> Void] = []
        let profile = try! NeuralLayoutProfile(modelSHA256: String(repeating: "a", count: 64), enabled: true, minimumScore: 0.99, minimumMargin: 0.5)
        let presentation = NeuralLayoutPresentationStore()
        let runtime = NeuralLayoutRuntime(mode: .assist, presentation: presentation, factory: {
            NeuralLayoutLoadedBackend(backend: SettingsBackend(), modelID: "fixture", sha256: String(repeating: "b", count: 64), profile: profile)
        }, work: { work.append($0) }, deliver: { delivery.append($0) })
        t.check("Загрузка публикуется без второго backend", presentation.value.status == .loading && work.count == 1)
        work.removeFirst()(); delivery.removeFirst()()
        t.check("Несовпадение SHA не предоставляет профиль помощи", runtime.profile == nil)
        t.check("Assist с несовпадением SHA показан как наблюдение", presentation.value.status == .ready && !presentation.value.assistanceAvailable && presentation.value.effectiveMode == .observe)
        let request = runtime.request(occurrenceID: UUID(), word: "hello", bundleID: "test", layoutCode: "en")
        runtime.setMode(.observe)
        t.check("Смена режима инвалидирует ожидающий контекст", !runtime.isCurrent(request))
        runtime.stop()
        t.check("Off публикуется независимо от сбора", presentation.value.status == .off && defaults.bool(forKey: "layoutDiagnosticsEnabled"))
        var failedWork: [() -> Void] = []
        let failed = NeuralLayoutRuntime(mode: .observe, presentation: presentation, factory: { throw NeuralLayoutError.unavailable }, work: { failedWork.append($0) }, deliver: { $0() })
        failedWork.removeFirst()()
        t.check("Ошибка загрузки доступна для UI", presentation.value.status == .unavailable && presentation.value.error != nil)
        failed.stop()
        var disabledWork: [() -> Void] = []
        let disabledProfile = try! NeuralLayoutProfile(modelSHA256: profile.modelSHA256, enabled: false, minimumScore: 0.99, minimumMargin: 0.5)
        let disabled = NeuralLayoutRuntime(mode: .assist, presentation: presentation, factory: {
            NeuralLayoutLoadedBackend(backend: SettingsBackend(), modelID: "disabled", sha256: profile.modelSHA256, profile: disabledProfile)
        }, work: { disabledWork.append($0) }, deliver: { $0() })
        disabledWork.removeFirst()()
        t.check("Отключённый профиль сохраняет assist, эффективно observe", disabled.mode == .assist && presentation.value.effectiveMode == .observe && !presentation.value.assistanceAvailable)
        disabled.stop()
    }
}
