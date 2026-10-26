import Foundation

final class DiagnosticTests {
    private(set) var count = 0
    private(set) var failures = 0

    static func isFailure(_ condition: Bool) -> Bool { !condition }

    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        count += 1
        if Self.isFailure(condition()) {
            failures += 1
            print("FAIL: \(name)")
        } else {
            print("PASS: \(name)")
        }
    }

    func finish() -> Never {
        guard count > 0 else {
            fputs("Пустой набор проверок\n", stderr)
            exit(2)
        }
        print("\(count) проверок, \(failures) ошибок")
        exit(failures == 0 ? 0 : 1)
    }
}

protocol DiagnosticSuite {
    static var name: String { get }
    static func run(_ tests: DiagnosticTests)
}

enum DiagnosticTestRegistry {
    private static var suites: [String: (DiagnosticTests) -> Void] = [:]

    static func add<T: DiagnosticSuite>(_ suite: T.Type) {
        precondition(suites[T.name] == nil, "Повторное имя набора: \(T.name)")
        suites[T.name] = T.run
    }

    static func run(_ name: String) -> Never {
        guard let suite = suites[name] else {
            fputs("Неизвестный или пустой набор: \(name)\n", stderr)
            exit(2)
        }
        let tests = DiagnosticTests()
        suite(tests)
        tests.finish()
    }
}
