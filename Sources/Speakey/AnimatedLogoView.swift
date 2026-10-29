import AppKit

/// Иконка приложения в интро. Сохраняет интерфейс завершения для перехода к онбордингу.
final class AnimatedLogoView: NSView {
    var onFinished: (() -> Void)?
    private var finishWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView()
        icon.image = DockPresence.bundleIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { finishWork?.cancel() }

    func play() {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onFinished?() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
