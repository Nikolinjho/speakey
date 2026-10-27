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
#if QUALITY_TESTS
DiagnosticTestRegistry.add(QualityTests.self)
#endif
#if ASSISTANCE_TESTS
DiagnosticTestRegistry.add(AssistanceTests.self)
#endif
#if SETTINGS_TESTS
DiagnosticTestRegistry.add(SettingsTests.self)
#endif
DiagnosticTestRegistry.run(CommandLine.arguments.dropFirst().first ?? "")
