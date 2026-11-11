import Foundation

// Test entry point (replaces Sources/App/main.swift in the test build).
let started = Date()
UnitTests.run()
FeatureTests.run()
IntegrationTests.run()

print("")
print("passed: \(T.passed), failed: \(T.failed.count), skipped: \(T.skipped.count), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
if !T.failed.isEmpty {
    print("\nFAILURES:")
    for f in T.failed { print("  ✗ \(f)") }
    exit(1)
}
