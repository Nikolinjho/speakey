import Foundation

// Baseline может сохранить слово после навигации. Нейросети этот префикс больше не доверяем.
struct NeuralOccurrenceFence {
    private var blocked: Set<UUID> = []

    mutating func invalidate(current: UUID?, completed: UUID?) {
        // Буфер способен вернуть через backspace только текущее и последнее завершённое слово.
        blocked = Set([current, completed].compactMap { $0 })
    }

    mutating func reset() { blocked.removeAll() }

    func allows(_ occurrence: UUID?) -> Bool {
        guard let occurrence else { return false }
        return !blocked.contains(occurrence)
    }
}
