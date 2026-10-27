import Foundation

private final class ControlledQueues {
    var work: [() -> Void] = []
    var delivery: [() -> Void] = []
    func runWork() { work.removeFirst()() }
    func deliver() { delivery.removeFirst()() }
}

private final class RecordingBackend: NeuralLayoutBackend {
    var words: [String] = []
    var failNext = false
    func predict(_ word: String) throws -> NeuralLayoutScores {
        words.append(word)
        if failNext {
            failNext = false
            throw NeuralLayoutError.unavailable
        }
        return try NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
    }
}

private final class ThreadRecordingBackend: NeuralLayoutBackend {
    private(set) var ranOffMain = false
    func predict(_ word: String) throws -> NeuralLayoutScores {
        ranOffMain = !Thread.isMainThread
        return try NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
    }
}

private final class ResultOwner {
    var count = 0
    func receive(_ result: Result<NeuralLayoutResult, Error>) { count += 1 }
}

enum CoordinatorTests: DiagnosticSuite {
    static let name = "coordinator"

    static func run(_ t: DiagnosticTests) {
        let epoch = UUID()
        let occurrence = UUID()
        func request(_ word: String, revision: UInt64 = 0) -> NeuralLayoutRequest {
            NeuralLayoutRequest(epoch: epoch, revision: revision, occurrenceID: occurrence,
                                bundleID: "test.editor", layoutCode: "en", word: word)
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            var results: [NeuralLayoutResult] = []
            let coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) {
                if case .success(let result) = $0 { results.append(result) }
            }
            coordinator.submit(request("A"))
            coordinator.submit(request("B"))
            coordinator.submit(request("C", revision: 2))
            t.check("Занят один worker и один pending", coordinator.activeRequestCount == 1 && coordinator.pendingRequestCount == 1)
            t.check("До выполнения назначена только одна работа", queues.work.count == 1 && backend.words.isEmpty)
            queues.runWork()
            t.check("Backend завершён до обработки delivery", backend.words == ["A"] && results.isEmpty && queues.work.isEmpty)
            queues.deliver()
            queues.runWork()
            queues.deliver()
            t.check("Из A, B, C выполняются только A и C", backend.words == ["A", "C"])
            t.check("Результат сохраняет точный снимок", results.map(\.request) == [request("A"), request("C", revision: 2)])
            t.check("Длительность измерена", results.allSatisfy { $0.durationMs.isFinite && $0.durationMs >= 0 })
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            var received = 0
            let coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) { _ in received += 1 }
            coordinator.submit(request("old"))
            coordinator.submit(request("discarded"))
            coordinator.invalidate()
            coordinator.submit(request("new"))
            t.check("Инвалидация сохраняет занятый слот до завершения работы", queues.work.count == 1)
            queues.runWork()
            queues.deliver()
            t.check("Старый generation не вызывает callback", received == 0 && queues.work.count == 1)
            queues.runWork()
            queues.deliver()
            t.check("После инвалидации выполняется новый pending", backend.words == ["old", "new"] && received == 1)
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            backend.failNext = true
            var failures = 0
            var successes = 0
            let coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) {
                switch $0 {
                case .failure(let error): if (error as? NeuralLayoutError) == .unavailable { failures += 1 }
                case .success: successes += 1
                }
            }
            coordinator.submit(request("fails"))
            coordinator.submit(request("next"))
            queues.runWork()
            queues.deliver()
            queues.runWork()
            queues.deliver()
            t.check("Ошибка доставляется и освобождает слот без retry", failures == 1 && successes == 1 && backend.words == ["fails", "next"] && queues.work.isEmpty)
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            var coordinator: NeuralLayoutCoordinator!
            var received = 0
            coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) { _ in
                received += 1
                if received == 1 {
                    coordinator.submit(request("reentrant"))
                }
            }
            coordinator.submit(request("first"))
            coordinator.submit(request("pending"))
            queues.runWork()
            queues.deliver()
            t.check("Повторный submit из callback оставляет одну работу", queues.work.count == 1)
            queues.runWork()
            queues.deliver()
            t.check("Submit из callback заменяет прежний pending", backend.words == ["first", "reentrant"])
            coordinator = nil
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            var coordinator: NeuralLayoutCoordinator!
            coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) { _ in
                coordinator.invalidate()
            }
            coordinator.submit(request("first"))
            coordinator.submit(request("discarded"))
            queues.runWork()
            queues.deliver()
            t.check("Invalidate из callback очищает pending", queues.work.isEmpty && backend.words == ["first"])
            coordinator = nil
        }
        do {
            let queues = ControlledQueues()
            let backend = RecordingBackend()
            var owner: ResultOwner? = ResultOwner()
            weak let weakOwner = owner
            let coordinator = NeuralLayoutCoordinator(backend: backend,
                work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) }) { [weak owner] in owner?.receive($0) }
            coordinator.submit(request("word"))
            owner = nil
            t.check("Ожидающая работа не удерживает владельца слабого callback", weakOwner == nil)
            queues.runWork()
            queues.deliver()
        }
        do {
            let backend = ThreadRecordingBackend()
            let completed = DispatchSemaphore(value: 0)
            let coordinator = NeuralLayoutCoordinator(backend: backend,
                deliver: { _ in completed.signal() }) { _ in }
            coordinator.submit(request("background"))
            let finished = completed.wait(timeout: .now() + 5) == .success
            t.check("Production worker выполняет backend вне main", finished && backend.ranOffMain)
        }
        var session = NeuralLayoutSession()
        let snapshot = NeuralLayoutRequest(epoch: session.epoch, revision: session.revision, occurrenceID: occurrence,
            bundleID: "test.editor", layoutCode: "en", word: "same")
        func matches(_ occurrenceID: UUID? = occurrence, bundleID: String = "test.editor", layout: String = "en", word: String = "same") -> Bool {
            session.matches(snapshot, occurrenceID: occurrenceID, bundleID: bundleID, layoutCode: layout, word: word)
        }
        t.check("Точный снимок совпадает", matches())
        t.check("Тот же текст в другом occurrence устарел", !matches(UUID()) && !matches(nil))
        t.check("Смена приложения, раскладки и текста делает снимок устаревшим", !matches(bundleID: "other") && !matches(layout: "ru") && !matches(word: "Same"))
        for event in ["буква", "удаление", "граница слова", "Enter", "навигация", "режим"] {
            session.changed()
            t.check("Изменение ввода: \(event) делает снимок устаревшим", !matches())
        }
        let current = NeuralLayoutRequest(epoch: session.epoch, revision: session.revision,
            occurrenceID: occurrence, bundleID: "test.editor", layoutCode: "en", word: "same")
        let wrongEpoch = NeuralLayoutRequest(epoch: UUID(), revision: session.revision,
            occurrenceID: occurrence, bundleID: "test.editor", layoutCode: "en", word: "same")
        t.check("Epoch проверяется независимо от revision", !session.matches(wrongEpoch, occurrenceID: occurrence,
            bundleID: "test.editor", layoutCode: "en", word: "same"))
        t.check("Текущая revision принимается после изменений", session.matches(current, occurrenceID: occurrence,
            bundleID: "test.editor", layoutCode: "en", word: "same"))
        let oldEpoch = session.epoch
        let oldRevision = session.revision
        session.invalidate()
        t.check("Новая сессия меняет epoch и revision", session.epoch != oldEpoch && session.revision == oldRevision + 1 && !matches())
    }
}
