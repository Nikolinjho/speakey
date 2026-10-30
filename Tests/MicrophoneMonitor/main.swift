import Foundation

enum AudioDevices {
    static func systemDefaultInputUID() -> String? { nil }
}

final class PreviewStub: MicrophoneMonitorPreview {
    var onFailure: (() -> Void)?
    var onStatusChanged: ((MicrophoneMonitorStatus) -> Void)?
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

check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: -60) == 0, "Нижняя граница шкалы — -60 дБ")
check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: -30) == 0.5, "Середина шкалы — -30 дБ")
check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: 6) == 1, "Перегрузка ограничена единицей")
check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: -160) == 0, "Тишина ограничена нулём")
check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: .nan) == 0, "Некорректный уровень даёт ноль")
check(MicrophoneMonitorStatus.normalizedInputLevel(averagePower: .infinity) == 0, "Бесконечный уровень даёт ноль")

let preview = PreviewStub()
var permissions: [(Bool) -> Void] = []
let monitor = MicrophoneMonitor(preview: preview, requestPermission: { permissions.append($0) })
check(monitor.state == .stopped && permissions.isEmpty, "Проверка выключена при создании")
monitor.start(inputUID: "usb")
check(monitor.state == .starting && preview.inputs.isEmpty, "До разрешения микрофон не открывается")
monitor.stop()
monitor.selectInput(inputUID: "other")
check(permissions.count == 1 && !monitor.isRequested, "Выбор после отмены разрешения не создаёт новый запрос")
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
check(monitor.status == nil, "Запуск не утверждает наличие сигнала")
let measured = MicrophoneMonitorStatus(connectionActive: true, inputLevel: 0.5)
var statuses: [MicrophoneMonitorStatus?] = []
monitor.onStatusChanged = { statuses.append($0) }
let oldStatus = preview.onStatusChanged
oldStatus?(measured)
check(monitor.status == measured && statuses.last! == measured, "Состояние соединения и уровень передаются интерфейсу")
preview.onFailure?()
check(monitor.state == .failed && !preview.playing, "Ошибка сессии выключает звук")
check(monitor.status == nil && statuses.last! == nil, "Ошибка очищает уровень")
oldStatus?(measured)
check(monitor.status == nil, "Поздний уровень после ошибки игнорируется")
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
oldStatus?(measured)
check(monitor.status == nil, "Уровень предыдущего запуска игнорируется")
preview.onStatusChanged?(measured)
monitor.stop()
check(monitor.status == nil, "Остановка очищает уровень")
preview.onStatusChanged?(measured)
check(monitor.status == nil, "Поздний уровень после остановки игнорируется")
var reentrantRequests = 0
let reentrant = MicrophoneMonitor(preview: PreviewStub(), requestPermission: { _ in reentrantRequests += 1 })
reentrant.onStateChanged = { state in
    if state == .starting { reentrant.stop() }
}
reentrant.start(inputUID: "usb")
check(reentrantRequests == 0 && reentrant.state == .stopped, "Остановка из наблюдателя отменяет запрос разрешения")

let selectionPreview = PreviewStub()
var selectionPermissions = 0
let selectionMonitor = MicrophoneMonitor(preview: selectionPreview, requestPermission: {
    selectionPermissions += 1
    $0(true)
})
selectionMonitor.selectInput(inputUID: "A")
check(selectionPermissions == 0, "Выбор микрофона не запускает выключенную проверку")
selectionMonitor.start(inputUID: "A")
selectionPreview.completions.removeFirst()(true)
selectionMonitor.selectInput(inputUID: "missing")
selectionPreview.completions.removeFirst()(false)
check(selectionMonitor.state == .failed && selectionMonitor.isRequested, "Ошибка входа сохраняет намерение проверять микрофон")
selectionMonitor.selectInput(inputUID: "A")
selectionPreview.completions.removeFirst()(true)
check(selectionMonitor.state == .running && selectionPreview.inputs.last == "A", "Возврат рабочего входа возобновляет включённую проверку")

selectionMonitor.selectInput(inputUID: "B")
let staleCompletion = selectionPreview.completions.removeFirst()
let staleFailure = selectionPreview.onFailure
let staleStatus = selectionPreview.onStatusChanged
selectionMonitor.selectInput(inputUID: "A")
staleCompletion(true)
staleFailure?()
staleStatus?(measured)
check(selectionMonitor.state == .starting && selectionMonitor.status == nil && !selectionPreview.playing,
      "События предыдущего выбора не изменяют новый запуск")
selectionPreview.completions.removeFirst()(true)
check(selectionMonitor.state == .running && selectionPreview.inputs.last == "A", "При быстром выборе запускается последний вход")
selectionMonitor.stop()
let stoppedPermissions = selectionPermissions
selectionMonitor.selectInput(inputUID: "B")
check(selectionPermissions == stoppedPermissions && selectionMonitor.state == .stopped && !selectionMonitor.isRequested, "После остановки выбор не включает проверку")

selectionMonitor.start(inputUID: "missing")
selectionPreview.completions.removeFirst()(false)
selectionMonitor.stop()
let failedPermissions = selectionPermissions
selectionMonitor.selectInput(inputUID: "A")
check(selectionPermissions == failedPermissions && selectionMonitor.state == .stopped && !selectionMonitor.isRequested, "Остановка после ошибки отменяет возобновление")
print("PASS: отмена разрешения, поздний запуск, уровень сигнала, смена входа, ошибки и остановка")
