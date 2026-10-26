import AppKit

// Изолированный просмотр настроек: до любых системных guard и AppDelegate.
if ProcessInfo.processInfo.environment["KEYBOOP_JOURNAL_PREVIEW"] == "1" {
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.regular)
    let suite = "keyboop-journal-preview-" + UUID().uuidString
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
    runtime.controller.addManualCase(typed: "ghbdtn", expected: "привет", bundleID: "com.apple.TextEdit", kind: .missedConversion)
    runtime.controller.addManualCase(typed: "ghbdtn", expected: "привёт", bundleID: "com.apple.TextEdit", kind: .missedConversion)
    runtime.controller.addManualCase(typed: "hello", expected: "hello", bundleID: "com.apple.Safari", kind: .unwantedConversion)
    var previewWindow: SettingsWindowController?
    store.flush { _ in
        previewWindow = SettingsWindowController()
        previewWindow?.show(section: .layoutJournal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let environment = ProcessInfo.processInfo.environment
            if let path = environment["KEYBOOP_JOURNAL_PREVIEW_PNG"], let index = SettingsSection.sidebarCases.firstIndex(of: .layoutJournal) {
                previewWindow?.dumpFullWindow(section: index, to: path, appearance: environment["KEYBOOP_JOURNAL_PREVIEW_LIGHT"] == "1" ? .aqua : .darkAqua)
            }
            if environment["KEYBOOP_JOURNAL_PREVIEW_INTERACTIVE"] != "1" {
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
let keyboopGlobeFixRequested =
    ProcessInfo.processInfo.environment["KEYBOOP_GLOBEFIX"] == "1"

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
