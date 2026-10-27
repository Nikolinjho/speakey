import Foundation

#if MODEL_TESTS
DiagnosticTestRegistry.add(ModelTests.self)
#endif
#if COORDINATOR_TESTS
DiagnosticTestRegistry.add(CoordinatorTests.self)
#endif
#if POLICY_TESTS
DiagnosticTestRegistry.add(PolicyTests.self)
#endif
#if INTEGRATION_TESTS
DiagnosticTestRegistry.add(ObservationIntegrationTests.self)
#endif
DiagnosticTestRegistry.run(CommandLine.arguments.dropFirst().first ?? "")
