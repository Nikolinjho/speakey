import Foundation

enum AudioDevices {
    static func systemDefaultInputUID() -> String? { nil }
}

final class PreviewStub: MicrophoneMonitorPreview {
    var onFailure: (() -> Void)?
    var completions: [(Bool) -> Void] = []
    var inputs: [String] = []
    var playing = false
    func start(inputUID: String, completion: @escaping (Bool) -> Void) {
        inputs.append(inputUID)
        completions.append(completion)
    }
    func play() -> Bool { playing = true; return true }
    func stop() { playing = false }
}

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

let preview = PreviewStub()
var permissions: [(Bool) -> Void] = []
let monitor = MicrophoneMonitor(preview: preview, requestPermission: { permissions.append($0) })
check(monitor.state == .stopped && permissions.isEmpty, "Проверка выключена при создании")
monitor.start(inputUID: "usb")
check(monitor.state == .starting && preview.inputs.isEmpty, "До разрешения микрофон не открывается")
monitor.stop()
permissions.removeFirst()(true)
check(monitor.state == .stopped && preview.inputs.isEmpty, "Отмена запрещает позднее разрешение")
monitor.start(inputUID: "usb")
permissions.removeFirst()(true)
check(preview.inputs == ["usb"], "Открывается выбранный микрофон")
monitor.stop()
preview.completions.removeFirst()(true)
check(monitor.state == .stopped && !preview.playing, "Поздний запуск не включает звук")
monitor.start(inputUID: "headset")
permissions.removeFirst()(true)
preview.completions.removeFirst()(false)
check(monitor.state == .failed && !preview.playing, "Ошибка запуска оставляет звук выключенным")
monitor.start(inputUID: "usb")
permissions.removeFirst()(false)
check(monitor.state == .failed && !preview.playing, "Отказ в разрешении оставляет звук выключенным")
monitor.start(inputUID: "usb")
permissions.removeFirst()(true)
preview.completions.removeFirst()(true)
check(monitor.state == .running && preview.playing, "Звук включается после подтверждённого запуска")
preview.onFailure?()
check(monitor.state == .failed && !preview.playing, "Ошибка сессии выключает звук")
monitor.stop()
check(monitor.state == .stopped && !preview.playing, "Остановка выключает проверку")
monitor.start(inputUID: "old")
let oldPermission = permissions.removeFirst()
monitor.start(inputUID: "new")
oldPermission(false)
check(monitor.state == .starting, "Старый отказ не отменяет новый запуск")
permissions.removeFirst()(true)
preview.completions.removeFirst()(true)
check(monitor.state == .running && preview.inputs.last == "new", "Новый запуск использует новый выбор")
monitor.stop()
var reentrantRequests = 0
let reentrant = MicrophoneMonitor(preview: PreviewStub(), requestPermission: { _ in reentrantRequests += 1 })
reentrant.onStateChanged = { state in
    if state == .starting { reentrant.stop() }
}
reentrant.start(inputUID: "usb")
check(reentrantRequests == 0 && reentrant.state == .stopped, "Остановка из наблюдателя отменяет запрос разрешения")
print("PASS: отмена разрешения, поздний запуск, выбранный вход, ошибки и остановка")
