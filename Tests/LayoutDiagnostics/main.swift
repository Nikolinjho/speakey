import Foundation

enum HarnessTests: DiagnosticSuite {
    static let name = "harness"
    static func run(_ tests: DiagnosticTests) {
        tests.check("Успешная проверка учитывается", true)
        tests.check("Ошибочная проверка обнаруживается", DiagnosticTests.isFailure(false))
        tests.check("Успешная проверка не считается ошибкой", !DiagnosticTests.isFailure(true))
    }
}

DiagnosticTestRegistry.add(HarnessTests.self)
DiagnosticTestRegistry.run(CommandLine.arguments.dropFirst().first ?? "")
