import Foundation

private final class IntegrationQueues {
    var work: [() -> Void] = []
    var delivery: [() -> Void] = []
    func run() { work.removeFirst()() }
    func deliver() { delivery.removeFirst()() }
}
private final class IntegrationBackend: NeuralLayoutBackend {
    var words: [String] = []
    func predict(_ word: String) throws -> NeuralLayoutScores {
        words.append(word)
        return try NeuralLayoutScores(logits: [0, 0, 0, 10, 0, 0, 0, 0, 0])
    }


}

private final class LifetimeBackend: NeuralLayoutBackend {
    let released: () -> Void
    init(released: @escaping () -> Void) { self.released = released }
    deinit { released() }
    func predict(_ word: String) throws -> NeuralLayoutScores {
        try NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
    }
}

enum ObservationIntegrationTests: DiagnosticSuite {
    static let name = "integration"
    static func run(_ t: DiagnosticTests) {
        t.check("Незаполненный layout cache не читает системную раскладку", KeyboardLayoutCache.cachedSourceID == nil)
        let domain = "keyboop-integration-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        t.check("Отсутствующий режим означает observe", NeuralLayoutModeSettings.read(defaults) == .observe)
        defaults.set("future", forKey: "neuralLayoutMode")
        t.check("Неизвестный режим выключает модель", NeuralLayoutModeSettings.read(defaults) == .off)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: .neuralLayoutModeChanged, object: nil, queue: nil) { _ in notifications += 1 }
        NeuralLayoutModeSettings.write(.observe, to: defaults)
        NeuralLayoutModeSettings.write(.observe, to: defaults)
        t.check("Смена режима сохраняется и уведомляет один раз", NeuralLayoutModeSettings.read(defaults) == .observe && notifications == 1)
        NotificationCenter.default.removeObserver(token)
        let queues = IntegrationQueues()
        let backend = IntegrationBackend()
        var loads = 0
        var noted: [NeuralLayoutRequest] = []
        var results: [(NeuralLayoutRequest, NeuralLayoutEvidence)] = []
        var rawResults: [NeuralLayoutResult] = []
        let runtime = NeuralLayoutRuntime(mode: .off, factory: {
            loads += 1
            return NeuralLayoutLoadedBackend(backend: backend, modelID: "test-model", sha256: String(repeating: "a", count: 64))
        }, work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) },
        note: { noted.append($0) }, evidence: { results.append(($0, $1)) }, result: { rawResults.append($0) })
        let profile = try! NeuralLayoutProfile(modelSHA256: String(repeating: "a", count: 64), enabled: false, minimumScore: 0.95, minimumMargin: 0.5)
        let profileQueues = IntegrationQueues()
        let profiled = NeuralLayoutRuntime(mode: .observe, factory: {
            NeuralLayoutLoadedBackend(backend: backend, modelID: "test-model", sha256: profile.modelSHA256, profile: profile)
        }, work: { profileQueues.work.append($0) }, deliver: { profileQueues.delivery.append($0) })
        profileQueues.run(); profileQueues.deliver()
        t.check("Runtime сохраняет проверенный профиль backend", profiled.profile?.minimumScore == 0.95 && profiled.profile?.enabled == false)
        profiled.setMode(.off)
        t.check("Off очищает загруженный профиль", profiled.profile == nil)
        let occurrence = UUID()
        runtime.observe(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN", collecting: true)
        t.check("Off не загружает модель", queues.work.isEmpty && loads == 0)
        runtime.setMode(.observe)
        runtime.changed()
        runtime.observe(occurrenceID: occurrence, word: "gh", bundleID: "editor", layoutCode: "EN", collecting: true)
        runtime.changed()
        runtime.observe(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN", collecting: true)
        let original = runtime.request(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN")
        t.check("До готовности ввод не ждёт worker", backend.words.isEmpty && queues.work.count == 1)
        runtime.bind(original, detectorCyrillic: nil)
        queues.run(); queues.deliver()
        queues.run()
        runtime.changed()
        t.check("Граница снимает право замены", !runtime.isCurrent(original))
        queues.deliver()
        t.check("Последний снимок до ready сохраняет точный ключ после границы", backend.words == ["ghbdtn"] && results.first?.0 == original && noted.contains(original))
        t.check("Observe сохраняет предложение модели", results.first?.1.proposedCyrillic == true && results.first?.1.modelID == "test-model")
        let exported = results.first.flatMap { try? JSONEncoder().encode($0.1) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        t.check("JSON экспорт содержит SHA и все девять исходных оценок", (exported?["classScores"] as? [String: Double])?.count == 9 && exported?["modelSHA256"] as? String == String(repeating: "a", count: 64))
        runtime.changed()
        runtime.observe(occurrenceID: UUID(), word: "hello", bundleID: "editor", layoutCode: "EN", collecting: false)
        queues.run(); queues.deliver()
        t.check("Отключённый сбор не создаёт evidence и request журнала", backend.words.count == 2 && results.count == 1 && noted.count == 2 && rawResults.count == 2)
        runtime.observe(occurrenceID: UUID(), word: "same", bundleID: "editor", layoutCode: "EN", collecting: true)
        queues.run()
        runtime.invalidateContext()
        queues.deliver()
        t.check("Смена контекста отбрасывает поздний callback", results.count == 1 && rawResults.count == 2)
        runtime.observe(occurrenceID: UUID(), word: "same", bundleID: "editor", layoutCode: "EN", collecting: true)
        queues.run()
        runtime.setMode(.off)
        queues.deliver()
        queues.run()
        t.check("Off инвалидирует выполняющийся результат", results.count == 1 && rawResults.count == 2)
        runtime.setMode(.observe)
        queues.run(); queues.deliver()
        t.check("Повторное включение создаёт backend заново", loads == 2 && runtime.status == .ready)
        let exceptions = ExceptionStore(defaults: defaults)
        func trace(_ mode: NeuralLayoutMode) -> [SwapDecision] {
            runtime.setMode(mode)
            return ["ghbdtn", "hello", "руддщ", "привет", "api", "ghbdtn"].map { word in
                runtime.changed()
                runtime.observe(occurrenceID: UUID(), word: word, bundleID: "editor", layoutCode: "EN", collecting: false)
                return LayoutDetector.decide(word: word, exceptions: exceptions)
            }
        }
        t.check("Реальный детектор даёт одинаковые действия off и observe", trace(.off) == trace(.observe))
        let failedQueues = IntegrationQueues()
        let failed = NeuralLayoutRuntime(mode: .observe, factory: { throw NeuralLayoutError.unavailable }, work: { failedQueues.work.append($0) }, deliver: { failedQueues.delivery.append($0) })
        failedQueues.run(); failedQueues.deliver()
        t.check("Ошибка загрузки доступна без вмешательства в детектор", failed.status == .unavailable && failed.lastError != nil)
        runtime.stop()
        checkJournal(t)
        checkLifetime(t)
        checkFocus(t)
        checkPolicyEvidence(t)
        checkRetainedOccurrence(t)
    }
    private static func wait(_ ready: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(5)
        while !ready() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        return ready()
    }

    private static func checkLifetime(_ t: DiagnosticTests) {
        let lock = NSLock()
        var loadedOnWorker = false
        var releasedOnWorker = false
        var released = false
        let runtime = NeuralLayoutRuntime(mode: .observe, factory: {
            lock.lock(); loadedOnWorker = !Thread.isMainThread; lock.unlock()
            return NeuralLayoutLoadedBackend(backend: LifetimeBackend {
                lock.lock(); releasedOnWorker = !Thread.isMainThread; released = true; lock.unlock()
            }, modelID: "lifetime", sha256: String(repeating: "b", count: 64))
        })
        let ready = wait { runtime.status == .ready }
        runtime.setMode(.off)
        let finished = wait { lock.lock(); defer { lock.unlock() }; return released }
        lock.lock()
        let correctThreads = loadedOnWorker && releasedOnWorker
        lock.unlock()
        t.check("Production очередь создаёт и освобождает backend вне main", ready && finished && correctThreads)
    }

    private static func checkJournal(_ t: DiagnosticTests) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyboop-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutJournalStore(directory: directory)
        var attached = false
        let buffer = NeuralLayoutEvidenceBuffer(store: store, enabled: true) { result in
            if case .success = result { attached = true }
        }
        let controller = LayoutDiagnosticsController(enabled: true, sink: { _ in })
        controller.onObservation = { store.recordObservation($0) }
        let queues = IntegrationQueues()
        let runtime = NeuralLayoutRuntime(mode: .observe, factory: {
            NeuralLayoutLoadedBackend(backend: IntegrationBackend(), modelID: "journal", sha256: String(repeating: "c", count: 64))
        }, work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) },
        note: { buffer.note($0) }, evidence: { buffer.accept($0, evidence: $1) })
        let occurrence = UUID()
        runtime.changed()
        runtime.observe(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN", collecting: true)
        let original = runtime.request(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN")
        // Граница приходит даже до готовности модели, следующий ввод уже получил другую revision.
        runtime.changed()
        runtime.changed()
        runtime.observe(occurrenceID: UUID(), word: "hello", bundleID: "editor", layoutCode: "EN", collecting: false)
        let observation = controller.record(occurrenceID: occurrence, bundleID: "editor", typed: "ghbdtn", proposed: nil,
            path: .boundary, reason: .detectorKeep, action: .keep, complete: true)!
        buffer.bind(observation.id, to: original)
        runtime.bind(original, detectorCyrillic: nil)
        // Запрос последнего слова вытеснил ещё не запущенный первый. Он не должен получить чужие оценки.
        queues.run(); queues.deliver(); queues.run(); queues.deliver()
        var snapshot: LayoutJournalSnapshot?
        store.snapshot { snapshot = $0 }
        _ = wait { snapshot != nil }
        t.check("Вытесненный до ready запрос не получает оценки следующего слова", snapshot?.observations.first?.neural == nil)
        let currentOccurrence = UUID()
        runtime.changed()
        runtime.observe(occurrenceID: currentOccurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN", collecting: true)
        let current = runtime.request(occurrenceID: currentOccurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "EN")
        queues.run()
        runtime.changed()
        runtime.changed()
        let completed = controller.record(occurrenceID: currentOccurrence, bundleID: "editor", typed: "ghbdtn", proposed: nil,
            path: .boundary, reason: .detectorKeep, action: .keep, complete: true)!
        buffer.bind(completed.id, to: current)
        runtime.bind(current, detectorCyrillic: nil)
        queues.deliver()
        _ = wait { attached }
        snapshot = nil
        store.snapshot { snapshot = $0 }
        _ = wait { snapshot != nil }
        t.check("Поздний результат дополняет исходный id после следующей буквы", snapshot?.observations.first(where: { $0.id == completed.id })?.neural?.modelID == "journal")
        t.check("Одинаковое слово другого occurrence не получает evidence", snapshot?.observations.first(where: { $0.id == observation.id })?.neural == nil)
        runtime.stop()
    }
    private static func checkFocus(_ t: DiagnosticTests) {
        let queues = IntegrationQueues()
        let runtime = NeuralLayoutRuntime(mode: .observe, factory: {
            NeuralLayoutLoadedBackend(backend: IntegrationBackend(), modelID: "focus", sha256: String(repeating: "a", count: 64))
        }, work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) })
        var changed: (() -> Void)?
        var cancelled = 0
        let focus = NeuralFocusMonitor(install: { _, callback in
            changed = callback
            return { cancelled += 1 }
        }, changed: { runtime.invalidateContext() })
        focus.track(pid: 123)
        let request = runtime.request(occurrenceID: UUID(), word: "same", bundleID: "editor", layoutCode: "source.id")
        changed?()
        t.check("Смена поля того же приложения меняет epoch для того же слова", runtime.session.epoch != request.epoch && !runtime.isCurrent(request))
        t.check("Доступность AX tracking явно доступна", focus.available)
        focus.track(pid: 456)
        focus.stop()
        t.check("Смена PID и остановка освобождают AX регистрации", cancelled == 2 && !focus.available)
        let unavailable = NeuralFocusMonitor(install: { _, _ in nil }, changed: {})
        unavailable.track(pid: 123)
        t.check("Недоступный AX tracking не выдаёт разрешение assistance", !unavailable.available)
        runtime.stop()
    }

    private static func checkPolicyEvidence(_ t: DiagnosticTests) {
        let queues = IntegrationQueues()
        var saved: NeuralLayoutEvidence?
        var runtime: NeuralLayoutRuntime!
        runtime = NeuralLayoutRuntime(mode: .observe, factory: {
            NeuralLayoutLoadedBackend(backend: IntegrationBackend(), modelID: "policy", sha256: String(repeating: "d", count: 64))
        }, work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) },
        evidence: { _, evidence in saved = evidence }, result: { result in
            let admission = NeuralLayoutAdmission(mode: .assist, modelSHA256: runtime.modelSHA256, profile: nil,
                fresh: true, block: .editing, wordLength: result.request.word.count, sourceCyrillic: false)
            runtime.recordPolicy(NeuralLayoutPolicy.evaluate(scores: result.scores, admission: admission), for: result.request)
        })
        queues.run(); queues.deliver()
        let occurrence = UUID()
        runtime.observe(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "source.id", collecting: true)
        let request = runtime.request(occurrenceID: occurrence, word: "ghbdtn", bundleID: "editor", layoutCode: "source.id")
        runtime.bind(request, detectorCyrillic: nil)
        queues.run(); queues.deliver()
        t.check("Policy Engine сохраняется в evidence до emit", saved?.block == .editing)
        t.check("Policy не стирает независимое предложение raw scores", saved?.proposedCyrillic == true && runtime.modelSHA256 == String(repeating: "d", count: 64))
        runtime.stop()
        runtime = nil
    }

    private static func checkRetainedOccurrence(_ t: DiagnosticTests) {
        for event in ["фокус другого поля", "стрелка при arrowsCancel=false", "смена раскладки", "смена режима"] {
            let buffer = KeystrokeBuffer()
            var fence = NeuralOccurrenceFence()
            let queues = IntegrationQueues()
            let backend = IntegrationBackend()
            let runtime = NeuralLayoutRuntime(mode: .observe, factory: {
                NeuralLayoutLoadedBackend(backend: backend, modelID: "fence", sha256: String(repeating: "e", count: 64))
            }, work: { queues.work.append($0) }, deliver: { queues.delivery.append($0) })
            queues.run(); queues.deliver()
            var snapshots: [String] { backend.words }
            func observe() {
                guard let occurrence = buffer.currentOccurrenceID, fence.allows(occurrence) else { return }
                runtime.changed()
                runtime.observe(occurrenceID: occurrence, word: buffer.currentWord, bundleID: "editor", layoutCode: "source.id", collecting: false)
                queues.run(); queues.deliver()
            }
            buffer.onContextReset = {
                fence.invalidate(current: buffer.currentOccurrenceID, completed: buffer.lastOccurrenceID)
                runtime.invalidateContext()
            }
            buffer.append("ghbd")
            let original = buffer.currentOccurrenceID
            observe()
            fence.invalidate(current: buffer.currentOccurrenceID, completed: buffer.lastOccurrenceID)
            buffer.append("t")
            observe()
            t.check("Карантин сохраняет baseline buffer, но запрещает snapshot: \(event)",
                buffer.currentWord == "ghbdt" && buffer.currentOccurrenceID == original && snapshots == ["ghbd"])
            buffer.boundary(" ")
            buffer.append("hello")
            observe()
            t.check("Новое естественное occurrence разрешает observation: \(event)", snapshots == ["ghbd", "hello"])
            buffer.softContextReset()
            buffer.append("t")
            observe()
            t.check("Soft reset с новым id и прежним префиксом также остаётся в карантине: \(event)", snapshots == ["ghbd", "hello"])
            buffer.clear()
            buffer.append("world")
            observe()
            t.check("Полный clear снимает карантин: \(event)", snapshots == ["ghbd", "hello", "world"])
            buffer.boundary(" ")
            fence.invalidate(current: buffer.currentOccurrenceID, completed: buffer.lastOccurrenceID)
            buffer.backspace()
            buffer.backspace()
            observe()
            t.check("Backspace в старое завершённое occurrence не обходит карантин: \(event)", snapshots == ["ghbd", "hello", "world"])
            runtime.stop()
        }
        var changes = 0
        let monitor = NeuralFocusMonitor(install: { _, _ in {} }, changed: { changes += 1 })
        monitor.track(pid: 123)
        monitor.track(pid: 123)
        monitor.track(pid: 456)
        t.check("Смена процесса того же bundle инвалидирует контекст ровно при смене PID", changes == 2)
    }

}
