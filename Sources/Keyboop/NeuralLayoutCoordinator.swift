import Foundation

final class NeuralLayoutCoordinator {
    typealias Schedule = (@escaping () -> Void) -> Void

    private let backend: NeuralLayoutBackend
    private let work: Schedule
    private let deliver: Schedule
    private let onResult: (Result<NeuralLayoutResult, Error>) -> Void
    private var busy = false
    private var pending: NeuralLayoutRequest?
    private var generation: UInt64 = 0

    init(backend: NeuralLayoutBackend,
         work: Schedule? = nil,
         deliver: @escaping Schedule = { DispatchQueue.main.async(execute: $0) },
         onResult: @escaping (Result<NeuralLayoutResult, Error>) -> Void) {
        self.backend = backend
        if let work {
            self.work = work
        } else {
            let queue = DispatchQueue(label: "com.keyboop.neural-layout")
            self.work = { action in queue.async(execute: DispatchWorkItem(block: action)) }
        }
        self.deliver = deliver
        self.onResult = onResult
    }

    // Только чтение на главном потоке для диагностики ограниченной очереди.
    var activeRequestCount: Int {
        precondition(Thread.isMainThread)
        return busy ? 1 : 0
    }

    var pendingRequestCount: Int {
        precondition(Thread.isMainThread)
        return pending == nil ? 0 : 1
    }

    func submit(_ request: NeuralLayoutRequest) {
        precondition(Thread.isMainThread)
        pending = request
        drain()
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        generation &+= 1
        pending = nil
    }

    private func drain() {
        precondition(Thread.isMainThread)
        guard !busy, let request = pending else { return }
        pending = nil
        busy = true
        let generation = self.generation
        let backend = self.backend
        let deliver = self.deliver
        work { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let result = Result {
                let scores = try backend.predict(request.word)
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                return NeuralLayoutResult(request: request, scores: scores, durationMs: Double(elapsed) / 1_000_000)
            }
            deliver { [weak self] in
                guard let self else { return }
                precondition(Thread.isMainThread)
                // Слот остаётся занятым и во время callback: повторный submit заменяет pending.
                if self.generation == generation { self.onResult(result) }
                self.busy = false
                self.drain()
            }
        }
    }
}
