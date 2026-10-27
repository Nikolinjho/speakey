import Foundation

DiagnosticTestRegistry.add(ModelTests.self)
DiagnosticTestRegistry.run(CommandLine.arguments.dropFirst().first ?? "")
