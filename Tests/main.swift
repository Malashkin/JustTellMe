import Foundation

// Test entry point (replaces Sources/App/main.swift in the test build).
let started = Date()
// Most expectations are the Russian interface texts; English is checked by LocalizationTests.
L10n.isRussian = true
UnitTests.run()
FeatureTests.run()
IntegrationTests.run()
LocalizationTests.run()

print("")
print("passed: \(T.passed), failed: \(T.failed.count), skipped: \(T.skipped.count), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
if !T.failed.isEmpty {
    print("\nFAILURES:")
    for f in T.failed { print("  ✗ \(f)") }
    exit(1)
}
