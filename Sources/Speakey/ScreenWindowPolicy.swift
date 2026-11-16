import Foundation
import CoreGraphics

struct ScreenWindowCandidate {
    let pid: Int32
    let id: UInt32
    let layer: Int
    let frame: CGRect
}

/// Сопоставление только доказанного фокуса. Размер и порядок окон не доказывают фокус.
enum ScreenWindowPolicy {
    static func allowed(pid: Int32, frontmostPID: Int32?, permission: Bool, excluded: Bool) -> Bool {
        pid > 0 && pid == frontmostPID && permission && !excluded
    }

    static func select(pid: Int32, frame: CGRect?, windowID: UInt32?,
                       from windows: [ScreenWindowCandidate]) -> UInt32? {
        let matches = windows.filter { window in
            guard window.pid == pid, window.layer == 0, valid(window.frame) else { return false }
            if let windowID { return window.id == windowID }
            guard let frame, valid(frame) else { return false }
            return abs(window.frame.minX - frame.minX) <= 1
                && abs(window.frame.minY - frame.minY) <= 1
                && abs(window.frame.width - frame.width) <= 1
                && abs(window.frame.height - frame.height) <= 1
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 50 && frame.height > 50
    }
}

/// Чистая модель кэша. Владелец сериализует доступ и передаёт монотонное время.
struct ScreenContextState<Focus: Equatable> {
    struct Request: Equatable {
        let generation: UInt64
        let focus: Focus
    }
    private var focus: Focus?
    private var generation: UInt64 = 0
    private var active: Request?
    private var lastAttempt: TimeInterval?
    private var latest: (focus: Focus, date: TimeInterval, text: String)?
    private var cache: (focus: Focus, windowID: UInt32, date: TimeInterval, text: String)?

    mutating func observe(_ newFocus: Focus?) {
        guard newFocus != focus else { return }
        focus = newFocus
        generation &+= 1
        active = nil
        lastAttempt = nil
        latest = nil
    }

    mutating func begin(focus: Focus, now: TimeInterval) -> Request? {
        observe(focus)
        guard active == nil, lastAttempt.map({ now - $0 >= 3 }) ?? true else { return nil }
        generation &+= 1
        let request = Request(generation: generation, focus: focus)
        active = request
        lastAttempt = now
        return request
    }

    mutating func text(focus: Focus?, now: TimeInterval) -> String? {
        observe(focus)
        guard let focus, let latest, latest.focus == focus,
              now >= latest.date, now - latest.date < 15 else { return nil }
        return latest.text.isEmpty ? nil : latest.text
    }

    func cached(_ request: Request, windowID: UInt32, now: TimeInterval) -> String? {
        guard active == request, let cache, cache.focus == request.focus, cache.windowID == windowID,
              now >= cache.date, now - cache.date < 10 else { return nil }
        return cache.text
    }

    @discardableResult mutating func complete(_ request: Request, windowID: UInt32,
                                             text: String, now: TimeInterval, reusingCache: Bool = false) -> Bool {
        guard active == request, focus == request.focus else { return false }
        let capturedAt: TimeInterval
        if reusingCache {
            guard let cache, cached(request, windowID: windowID, now: now) == text else { return false }
            capturedAt = cache.date
        } else {
            capturedAt = now
            cache = (request.focus, windowID, now, text)
        }
        latest = (request.focus, capturedAt, text)
        active = nil
        return true
    }

    mutating func finish(_ request: Request) {
        guard active == request else { return }
        active = nil
    }
}
