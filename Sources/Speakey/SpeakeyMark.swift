import AppKit

/// Резервный знак из текущей иконки приложения.
enum SpeakeyMark {
    static func draw(in rect: NSRect, color: NSColor = .black) {
        let side = min(rect.width, rect.height)
        let target = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                            width: side, height: side)
        DockPresence.bundleIcon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
