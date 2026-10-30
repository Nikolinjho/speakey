import AppKit

// Явный локальный CLI завершается до AppDelegate, NSApplication, микрофона и настроек.
if ProcessInfo.processInfo.environment["SPEAKEY_SPEECH_CLI"] == "1" {
    setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
    Task {
        exit(await SpeechEvaluationCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
    dispatchMain()
}

// Проверочный процесс не запускает AppDelegate и не касается пользовательских настроек.
if ProcessInfo.processInfo.environment["SPEAKEY_NEURAL_TRANSPORT_CHECK"] == "1" {
    exit(NeuralLayoutTransportCheck.run())
}

// Изолированный просмотр настроек: до любых системных guard и AppDelegate.
if ProcessInfo.processInfo.environment["SPEAKEY_JOURNAL_PREVIEW"] == "1" || ProcessInfo.processInfo.environment["SPEAKEY_NEURAL_PREVIEW_CHECK"] == "1" {
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.regular)
    let previewAppearance: NSAppearance.Name = ProcessInfo.processInfo.environment["SPEAKEY_JOURNAL_PREVIEW_LIGHT"] == "1" ? .aqua : .darkAqua
    previewApp.appearance = NSAppearance(named: previewAppearance)
    let suite = "speakey-journal-preview-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("ru", forKey: "language")
    defaults.set(740.0, forKey: "proWindowHeight")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    AppSettings.shared = AppSettings(defaults: defaults)
    ExceptionStore.shared = ExceptionStore(defaults: defaults)
    let store = LayoutJournalStore(directory: directory)
    let runtime = LayoutDiagnosticsRuntime(store: store, settings: .shared, backend: ExceptionLayoutRuleBackend(exceptions: .shared))
    LayoutDiagnosticsRuntime.shared = runtime
    runtime.setEnabled(true)
    let neuralCheck = ProcessInfo.processInfo.environment["SPEAKEY_NEURAL_PREVIEW_CHECK"] == "1"
    let neuralPresentation = NeuralLayoutPresentationStore()
    if neuralCheck { AppSettings.shared.neuralLayoutMode = .assist }
    var neuralPreview: NeuralLayoutRuntime!
    neuralPreview = NeuralLayoutRuntime(mode: neuralCheck ? .assist : .off, presentation: neuralPresentation, factory: {
        let sha = String(repeating: "a", count: 64)
        let profile = try NeuralLayoutProfile(modelSHA256: sha, enabled: false, minimumScore: 0.99, minimumMargin: 0.5)
        return NeuralLayoutLoadedBackend(backend: PreviewNeuralLayoutBackend(), modelID: "preview", sha256: sha, profile: profile)
    }, note: { runtime.noteNeuralRequest($0) }, evidence: { request, value in
        runtime.acceptNeuralResult(request, evidence: value)
    }, result: { result in
        let admission = NeuralLayoutAdmission(mode: neuralPreview.mode, modelSHA256: neuralPreview.modelSHA256, profile: neuralPreview.profile,
            fresh: neuralPreview.isCurrent(result.request), block: nil, wordLength: result.request.word.count, sourceCyrillic: result.request.word == "дд")
        neuralPreview.recordPolicy(NeuralLayoutPolicy.evaluate(scores: result.scores, admission: admission), for: result.request)
    })
    let neuralObserver = NotificationCenter.default.addObserver(forName: .neuralLayoutModeChanged, object: nil, queue: .main) { _ in
        neuralPreview.setMode(AppSettings.shared.neuralLayoutMode)
    }
    defer { NotificationCenter.default.removeObserver(neuralObserver); neuralPreview.stop() }
    runtime.controller.addManualCase(typed: "ghbdtn", expected: "привет", bundleID: "com.apple.TextEdit", kind: .missedConversion)
    runtime.controller.addManualCase(typed: "ghbdtn", expected: "привёт", bundleID: "com.apple.TextEdit", kind: .missedConversion)
    runtime.controller.addManualCase(typed: "hello", expected: "hello", bundleID: "com.apple.Safari", kind: .unwantedConversion)
    // Настоящие факты из встроенных словарей и текущей таблицы клавиатуры.
    let data = LayoutData.shared
    func facts(_ typed: String) -> LayoutObservationFacts {
        LayoutObservationFacts.evaluate(typed, wordsRu: data.wordsRu, wordsEn: data.wordsEn) {
            Keymap.convert($0, toCyrillic: $1)
        }
    }
    let missing = facts("дд")
    var oldObservation = LayoutObservation(occurrenceID: UUID(), contextID: UUID(), bundleID: "com.apple.TextEdit",
        typed: "дд", proposed: nil, alternative: missing.alternative, dictionaryMatch: missing.dictionaryMatch,
        path: .boundary, reason: .detectorKeep, action: .keep, submission: .notNeeded,
        isCompleteWord: true, uptime: ProcessInfo.processInfo.systemUptime - 60)
    oldObservation.recordedAt = Date().addingTimeInterval(-60)
    store.recordObservation(oldObservation)
    let punctuation = facts("[kt,")
    if let replacement = runtime.controller.record(occurrenceID: UUID(), bundleID: "com.apple.TextEdit", typed: "[kt,",
        proposed: punctuation.alternative, alternative: punctuation.alternative, dictionaryMatch: punctuation.dictionaryMatch,
        path: .boundary, reason: .detectorConvert, action: .replace, complete: true) {
        runtime.controller.submission(observationID: replacement.id, contextID: replacement.contextID, submitted: true)
    }
    let unknown = facts("жжжж")
    runtime.controller.record(occurrenceID: UUID(), bundleID: "com.apple.TextEdit", typed: "жжжж", proposed: nil,
        alternative: unknown.alternative, dictionaryMatch: unknown.dictionaryMatch,
        path: .boundary, reason: .detectorKeep, action: .keep, complete: true)
    let blocked = facts("hello")
    runtime.controller.record(occurrenceID: UUID(), bundleID: "com.apple.Safari", typed: "hello", proposed: nil,
        alternative: blocked.alternative, dictionaryMatch: blocked.dictionaryMatch,
        path: .boundary, reason: .appDisabled, action: .blocked, complete: true)
    var previewWindow: SettingsWindowController?
    // Ограничивает также ожидание начальной загрузки и отрисовки.
    if ProcessInfo.processInfo.environment["SPEAKEY_JOURNAL_PREVIEW_INTERACTIVE"] != "1" ||
        ProcessInfo.processInfo.environment["SPEAKEY_JOURNAL_PREVIEW_CHECK"] == "1" || neuralCheck {
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        fputs("FAIL: preview не завершился за 30 секунд\n", stderr)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        exit(1)
    }
    }
    store.flush { result in
        if case .failure(let error) = result {
            fputs("FAIL: \(error)\n", stderr)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            exit(1)
        }
        previewWindow = SettingsWindowController(neuralPresentation: neuralPresentation)
        previewWindow?.show(section: .layoutJournal)
        previewWindow?.whenLayoutJournalReady {
            let environment = ProcessInfo.processInfo.environment
            if let path = environment["SPEAKEY_JOURNAL_PREVIEW_PNG"], let index = SettingsSection.sidebarCases.firstIndex(of: .layoutJournal) {
                previewWindow?.dumpFullWindow(section: index, to: path, appearance: previewAppearance, selectSection: false)
            }
            if environment["SPEAKEY_JOURNAL_PREVIEW_CHECK"] == "1" || neuralCheck, let window = previewWindow {
                Task { @MainActor in
                    var status: Int32 = 0
                    do {
                        if neuralCheck {
                            _ = try await LayoutJournalPreviewCheck.runNeural(window: window, diagnostics: runtime, neural: neuralPreview,
                                presentation: neuralPresentation, defaults: defaults, appearance: previewAppearance)
                        } else { _ = try await LayoutJournalPreviewCheck.run(window: window, runtime: runtime, directory: directory) }
                    }
                    catch { fputs("FAIL: \(error)\n", stderr); status = 1 }
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: directory)
                    exit(status)
                }
                return
            }
            if environment["SPEAKEY_JOURNAL_PREVIEW_INTERACTIVE"] != "1" {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
                exit(0)
            }
        }
    }
    previewApp.run()
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
    exit(0)
}


// ОБЪЕДИНЁННЫЙ RESOURCE-СТОРОЖ — до всего остального (задачи 96 + 35). Запуск с
// `--globe-guard <pid>` это не приложение: ни перехватчика, ни строки меню, ни разрешений, ни
// охраны единственного экземпляра. Legacy v1 охраняет 🌐; persistent v3 по приватному pipe держит
// независимые аренды 🌐 и SPU всю жизнь родителя и переживает его crash/SIGKILL. Проверка первая,
// чтобы helper не поднял UI.
GlobeGuard.runIfRequested()

// The repair hook must first win the cross-build singleton and then complete an authenticated
// helper transaction. AppDelegate consumes this flag before normal UI/resource startup.
let speakeyGlobeFixRequested =
    ProcessInfo.processInfo.environment["SPEAKEY_GLOBEFIX"] == "1"

// ggml/Metal: ВЫКЛЮЧАЕМ residency sets ДО первого касания Metal (первый whisper_init).
// Иначе при выходе с загруженной моделью статический деструктор ggml бьёт осознанный ассерт
// GGML_ASSERT([rsets->data count] == 0) → SIGABRT при квите (реальный краш-репорт 20.07;
// llama.cpp #19137 — апстрим закрыл как «not a bug: освободи контекст до exit»). С этим env
// (vendor .../ggml-metal-device.m:823-826) rsets вообще не создаются → ассерт невозможен и
// heartbeat-поток не поднимается. Цена — wiring-оптимизация памяти на простое (macOS 15+),
// которая нам не нужна: мы сами выгружаем модель на простое. Второй слой защиты —
// whisper_free в applicationWillTerminate (AppDelegate).
setenv("GGML_METAL_NO_RESIDENCY", "1", 1)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Без иконки в Dock — живём в статус-баре рядом с часами.
app.setActivationPolicy(.accessory)
app.run()
