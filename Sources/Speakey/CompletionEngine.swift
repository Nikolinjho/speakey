import Foundation

/// ПОМОЩНИК АВТОДОПОЛНЕНИЯ — отдельный процесс `speakey-complete` (llama-server из vendor/llama.cpp).
///
/// Почему не библиотека внутри Speakey: whisper.cpp уже влинкован со своим ggml, а у llama.cpp свой —
/// две статические копии ggml в одном бинаре конфликтуют по символам. Заодно падение или нехватка
/// памяти у модели не роняет Speakey, а модель можно выгрузить, просто погасив процесс.
///
/// Связь — HTTP/1.1 по unix-сокету в Application Support: наружу не слушаем ни одного порта
/// (принцип №2: в рантайме нет сети). Клиент свой, на POSIX, потому что URLSession unix-сокеты не умеет.
final class CompletionEngine {
    static let shared = CompletionEngine()

    enum State: Equatable { case stopped, starting, ready, failed(String) }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } } }
    }
    /// На main.
    var onStateChange: ((State) -> Void)?

    private var process: Process?
    private var modelURL: URL?
    private var lastUse = Date()
    private var idleTimer: Timer?
    /// Бэкофф перезапусков: упавший помощник (битая модель, нехватка памяти) не поднимается на каждой
    /// паузе в наборе. 5 с, 10 с, 20 с… до 5 минут; успешный старт сбрасывает счётчик.
    private var failures = 0
    private var nextAttempt = Date.distantPast
    /// Подряд идущие запросы без ответа: помощник жив, но завис — перезапускаем.
    private var silentFailures = 0
    var currentModel: URL? { modelURL }

    private let lock = NSLock()
    private var requestSeq = 0
    private var inFlightFD: Int32 = -1
    private var inFlightCompletion: ((String?) -> Void)?
    private let io = DispatchQueue(label: "dev.speakey.complete.io", qos: .userInitiated)

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Speakey", isDirectory: true)
    }
    /// Сокет — во временной папке пользователя, а не в Application Support: установщик сверяет
    /// папку данных до и после замены бандла и отказывается работать при «особых» файлах в ней.
    static var socketPath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("dev.speakey.complete.sock").path
    }
    private static var pidFile: URL { supportDir.appendingPathComponent("complete.pid") }

    /// Бинарь помощника: внутри бандла, иначе из env (харнесс, dev-запуск из терминала).
    static var helperURL: URL? {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/speakey-complete")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        if let env = ProcessInfo.processInfo.environment["SPEAKEY_COMPLETE_BIN"],
           FileManager.default.isExecutableFile(atPath: env) { return URL(fileURLWithPath: env) }
        return nil
    }

    private init() {}

    // MARK: - Жизненный цикл

    /// Идемпотентно. Другая модель — перезапуск. Вызывать с main.
    func ensureRunning(model: URL) {
        lastUse = Date()
        if let p = process, p.isRunning, modelURL == model { return }
        guard Date() >= nextAttempt else { return }
        stop()
        guard let helper = Self.helperURL else {
            noteFailure()
            state = .failed("helper-missing")
            kbLog("complete: помощник не найден в бандле")
            return
        }
        Self.killStale()
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Self.socketPath)

        let p = Process()
        p.executableURL = helper
        p.arguments = ["-m", model.path, "--host", Self.socketPath,
                       "-c", "4096", "-ngl", "99", "-np", "1", "--no-webui",
                       "--cache-reuse", "256", "-t", "4", "--log-disable"]
        // Логи помощника могут содержать куски промпта — в никуда.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.noteFailure()
                self.state = .failed("exit-\(proc.terminationStatus)")
                kbLog("complete: помощник завершился, код \(proc.terminationStatus)")
            }
        }
        do {
            try p.run()
        } catch {
            noteFailure()
            state = .failed("launch")
            kbLog("complete: помощник не запустился")
            return
        }
        process = p
        modelURL = model
        state = .starting
        try? String(p.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        let started = Date()
        kbLog("complete: помощник запущен, pid \(p.processIdentifier)")
        pollHealth(process: p, started: started)
        startIdleTimer()
    }

    func stop() {
        cancelInFlight()
        idleTimer?.invalidate(); idleTimer = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        modelURL = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
        try? FileManager.default.removeItem(atPath: Self.socketPath)
        if state != .stopped { state = .stopped }
    }

    func noteUse() { lastUse = Date() }

    private func noteFailure() {
        failures += 1
        nextAttempt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(failures - 1))))
    }

    /// Старый помощник от упавшего Speakey держал бы гигабайты модели — гасим по pid-файлу.
    private static func killStale() {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
           String(cString: buf).hasSuffix("speakey-complete") {
            kill(pid, SIGTERM)
        }
    }

    private func pollHealth(process p: Process, started: Date) {
        io.async { [weak self] in
            let ok = (try? Self.http(method: "GET", path: "/health", body: nil, timeout: 1, fdSink: nil))?.status == 200
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                if ok {
                    self.failures = 0
                    self.silentFailures = 0
                    self.state = .ready
                    kbLog("complete: модель готова за \(Int(Date().timeIntervalSince(started) * 1000)) мс")
                } else if Date().timeIntervalSince(started) > 120 {
                    kbLog("complete: модель не поднялась за 120 с")
                    self.stop()
                    self.noteFailure()
                    self.state = .failed("timeout")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pollHealth(process: p, started: started) }
                }
            }
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.process != nil else { return }
            let limit = TimeInterval(max(1, AutocompletePrefs.idleUnloadMinutes) * 60)
            if Date().timeIntervalSince(self.lastUse) > limit {
                kbLog("complete: простой — выгружаю модель")
                self.stop()
            }
        }
    }

    // MARK: - Запрос

    /// Отменяет предыдущий незавершённый запрос (его колбэк получает nil). Колбэк — на main.
    /// Потокобезопасно.
    func complete(prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void) {
        let body: [String: Any] = [
            "prompt": prompt, "n_predict": maxTokens, "temperature": 0.2, "top_k": 20, "top_p": 0.9,
            "cache_prompt": true, "stop": ["\n"], "repeat_penalty": 1.1
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion(nil); return }
        lock.lock()
        let prev = inFlightCompletion
        if inFlightFD >= 0 { shutdown(inFlightFD, SHUT_RDWR) }
        requestSeq += 1
        let seq = requestSeq
        inFlightCompletion = completion
        inFlightFD = -1
        lock.unlock()
        if let prev { DispatchQueue.main.async { prev(nil) } }

        io.async { [weak self] in
            guard let self else { return }
            let res = try? Self.http(method: "POST", path: "/completion", body: data, timeout: 3, fdSink: { fd in
                self.lock.lock(); defer { self.lock.unlock() }
                if self.requestSeq == seq { self.inFlightFD = fd; return true }
                return false   // уже отменён
            }, fdDone: { fd in
                // Номер сокета снимаем ДО close: иначе отмена из другого потока могла бы сделать
                // shutdown по номеру, который система уже отдала чужому сокету (ревью 12.11).
                self.lock.lock(); if self.inFlightFD == fd { self.inFlightFD = -1 }; self.lock.unlock()
            })
            var text: String?
            if let res, res.status == 200,
               let obj = try? JSONSerialization.jsonObject(with: res.body) as? [String: Any] {
                text = obj["content"] as? String
            }
            self.lock.lock()
            let mine = self.requestSeq == seq
            let cb = mine ? self.inFlightCompletion : nil
            if mine { self.inFlightCompletion = nil; self.inFlightFD = -1 }
            self.lock.unlock()
            let hung = mine && res == nil
            DispatchQueue.main.async {
                if hung {
                    self.silentFailures += 1
                    if self.silentFailures >= 3, let m = self.modelURL {
                        kbLog("complete: помощник не отвечает — перезапуск")
                        self.silentFailures = 0
                        self.stop()
                        self.ensureRunning(model: m)
                    }
                } else if mine { self.silentFailures = 0 }
                cb?(text)
            }
        }
    }

    private func cancelInFlight() {
        lock.lock()
        let prev = inFlightCompletion
        if inFlightFD >= 0 { shutdown(inFlightFD, SHUT_RDWR) }
        requestSeq += 1
        inFlightCompletion = nil
        inFlightFD = -1
        lock.unlock()
        if let prev { DispatchQueue.main.async { prev(nil) } }
    }

    // MARK: - HTTP по unix-сокету

    struct Response { let status: Int; let body: Data }
    enum HTTPError: Error { case socket, connect, cancelled, io, parse }

    /// `fdSink` получает сокет до отправки и может отказаться (запрос уже отменён).
    static func http(method: String, path: String, body: Data?, timeout: TimeInterval,
                     fdSink: ((Int32) -> Bool)?, fdDone: ((Int32) -> Void)? = nil) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socket }
        defer { fdDone?(fd); close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw HTTPError.connect }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw HTTPError.connect }
        if let fdSink, !fdSink(fd) { throw HTTPError.cancelled }

        var req = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body { req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        req += "\r\n"
        var out = Data(req.utf8)
        if let body { out.append(body) }
        let sent = out.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent else { throw HTTPError.io }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) } else { break }
            if let r = parse(data), r.complete { return Response(status: r.status, body: r.body) }
        }
        guard let r = parse(data) else { throw HTTPError.parse }
        return Response(status: r.status, body: r.body)
    }

    /// Разбор ответа: Content-Length или chunked.
    private static func parse(_ data: Data) -> (status: Int, body: Data, complete: Bool)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let raw = Data(data[sep.upperBound...])
        if let cl = headers["content-length"].flatMap(Int.init) {
            return (status, raw.prefix(cl), raw.count >= cl)
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            var body = Data(); var i = raw.startIndex
            while let lineEnd = raw[i...].range(of: Data("\r\n".utf8)) {
                let sizeStr = String(data: raw[i..<lineEnd.lowerBound], encoding: .utf8)?
                    .split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
                if size == 0 { return (status, body, true) }
                let start = lineEnd.upperBound
                guard raw.distance(from: start, to: raw.endIndex) >= size + 2 else { break }
                let end = raw.index(start, offsetBy: size)
                body.append(raw[start..<end]); i = raw.index(end, offsetBy: 2)
            }
            return (status, body, false)
        }
        return (status, raw, false)
    }
}
