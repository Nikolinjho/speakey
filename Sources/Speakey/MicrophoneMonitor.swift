import AppKit
import AVFoundation

protocol MicrophoneMonitorPreview: AnyObject {
    var onFailure: (() -> Void)? { get set }
    func start(inputUID: String, completion: @escaping (Bool) -> Void)
    func play() -> Bool
    func stop()
}

final class MicrophoneMonitor {
    enum State: Equatable { case stopped, starting, running, failed }

    static let shared = MicrophoneMonitor()
    private(set) var state: State = .stopped
    var onStateChanged: ((State) -> Void)?

    private let preview: MicrophoneMonitorPreview
    private let requestPermission: (@escaping (Bool) -> Void) -> Void
    private var generation = UUID()

    private convenience init() {
        self.init(preview: CaptureMicrophonePreview(), requestPermission: { completion in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: completion(true)
            case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
            default: completion(false)
            }
        })
    }

    init(preview: MicrophoneMonitorPreview,
         requestPermission: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.preview = preview
        self.requestPermission = requestPermission
    }

    func start(inputUID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        let token = UUID()
        generation = token
        setState(.starting)
        guard generation == token else { return }
        preview.onFailure = { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail()
        }
        requestPermission { [weak self] allowed in
            Self.onMain {
                guard let self, self.generation == token else { return }
                guard allowed else { self.fail(); return }
                self.preview.start(inputUID: inputUID) { [weak self] started in
                    Self.onMain {
                        guard let self, self.generation == token else { return }
                        guard started, self.preview.play() else { self.fail(); return }
                        self.setState(.running)
                    }
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        preview.stop()
        setState(.stopped)
    }

    private func fail() {
        generation = UUID()
        preview.stop()
        setState(.failed)
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }

    private static func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}

private final class CaptureMicrophonePreview: MicrophoneMonitorPreview {
    var onFailure: (() -> Void)?
    private let queue = DispatchQueue(label: "speakey.microphone-preview")
    private let lock = NSLock()
    private var generation = UUID()
    private var output: AVCaptureAudioPreviewOutput?
    private var ready = false
    // Сессия и наблюдатели принадлежат только очереди захвата.
    private var session: AVCaptureSession?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(inputUID: String, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = UUID()
        let failure = onFailure
        lock.lock()
        generation = token
        ready = false
        output?.volume = 0
        lock.unlock()
        queue.async { [self] in
            tearDown()
            guard isCurrent(token) else { return }
            let uid = inputUID.isEmpty ? AudioDevices.systemDefaultInputUID() : inputUID
            let device: AVCaptureDevice?
            if let uid {
                device = AVCaptureDevice(uniqueID: uid)
            } else {
                device = AVCaptureDevice.default(for: .audio)
            }
            guard let device, device.hasMediaType(.audio), device.isConnected else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let capture = AVCaptureSession()
                let preview = AVCaptureAudioPreviewOutput()
                preview.volume = 0
                preview.outputDeviceUniqueID = nil
                guard capture.canAddInput(input), capture.canAddOutput(preview) else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                capture.beginConfiguration()
                capture.addInput(input)
                capture.addOutput(preview)
                capture.commitConfiguration()
                guard isCurrent(token) else { return }
                session = capture
                observe(capture, device: device, token: token, failure: failure)
                lock.lock()
                let current = generation == token
                if current { output = preview }
                lock.unlock()
                guard current else { tearDown(); return }
                capture.startRunning()
                lock.lock()
                let started = generation == token && capture.isRunning
                ready = started
                lock.unlock()
                guard started else {
                    tearDown()
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                // Включение звука выполняется на main после проверки отмены в контроллере.
                DispatchQueue.main.async { completion(true) }
            } catch {
                tearDown()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    func play() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        guard ready, let output else { return false }
        output.volume = 1
        return true
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        generation = UUID()
        ready = false
        output?.volume = 0
        lock.unlock()
        queue.async { [self] in tearDown() }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    private func observe(_ capture: AVCaptureSession, device: AVCaptureDevice,
                         token: UUID, failure: (() -> Void)?) {
        let failed: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == token
            if current {
                self.ready = false
                self.output?.volume = 0
            }
            self.lock.unlock()
            guard current else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.isCurrent(token) == true else { return }
                failure?()
            }
        }
        let center = NotificationCenter.default
        for (name, object) in [
            (AVCaptureSession.runtimeErrorNotification, capture as AnyObject),
            (AVCaptureSession.didStopRunningNotification, capture as AnyObject),
            (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject)
        ] {
            observers.append((center, center.addObserver(forName: name, object: object, queue: nil, using: failed)))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil, using: failed)))
    }

    private func tearDown() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        lock.lock()
        output?.volume = 0
        output = nil
        ready = false
        lock.unlock()
        if let session {
            if session.isRunning { session.stopRunning() }
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
        }
        session = nil
    }
}
