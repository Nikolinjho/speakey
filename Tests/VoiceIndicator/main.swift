import AppKit

// Изолируем показ плашки от записи звука, моделей и настроек пользователя.
final class AppSettings {
    static let shared = AppSettings()
    var voiceHudIsland = false
    var voiceHudTop = false
}
final class VoiceController {
    static let shared = VoiceController()
    func cancel() {}
    func end() {}
}
enum L10n { static func t(_ key: String) -> String { key } }
enum CaretLocator { static func caretScreenRect() -> NSRect? { nil } }
func kbLog(_ message: String) {}

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}
func flushUI() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
func checkPlacement(_ panel: NSPanel, _ name: String) {
    expect(panel.collectionBehavior.contains(.moveToActiveSpace),
           "\(name): показ переносит окно на активный рабочий стол")
    expect(!panel.collectionBehavior.contains(.canJoinAllSpaces),
           "\(name): перенос не конфликтует с закреплением на всех столах")
    expect(panel.styleMask.contains(.nonactivatingPanel), "\(name): панель не забирает фокус")
    expect(!panel.hidesOnDeactivate, "\(name): панель остаётся при вводе в другом приложении")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let indicator = VoiceIndicator.shared
indicator.showRecording()
flushUI()
guard let panel = app.windows.compactMap({ $0 as? NSPanel }).first else {
    print("FAIL: окно записи не создано")
    exit(1)
}
checkPlacement(panel, "Обычная плашка")
expect(panel.isVisible, "Запись показывает плашку")
expect(panel.isOnActiveSpace, "Плашка записи находится на активном столе")
expect(!panel.isKeyWindow, "Плашка записи не становится ключевым окном")
indicator.showProcessing()
flushUI()
expect(panel.isVisible, "Распознавание сохраняет плашку")
indicator.hide()
flushUI()
expect(!panel.isVisible, "Завершение скрывает плашку")
indicator.showRecording()
flushUI()
expect(panel.isVisible && panel.isOnActiveSpace, "Повторная запись показывает плашку на активном столе")
indicator.hide()
flushUI()
let island = NotchIsland()
checkPlacement(island.panel, "Плашка у выреза")
print("\(checks - failures)/\(checks) проверок пройдено")
exit(failures == 0 ? 0 : 1)
