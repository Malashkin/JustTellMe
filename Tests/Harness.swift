import Foundation

/// Minimal test harness: the build machine has only Command Line Tools (no XCTest), so tests are a
/// plain executable compiled together with the app sources. Run with scripts/test.sh.
enum T {
    static var passed = 0
    static var failed: [String] = []
    static var skipped: [String] = []
    private static var current = ""
    private static var currentFailed = false

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        currentFailed = false
        do { try body() } catch { fail("threw \(error)") }
        if currentFailed { print("✗ \(name)") } else { passed += 1 }
    }

    static func skip(_ name: String, _ why: String) {
        skipped.append("\(name) — \(why)")
        print("- \(name) (skipped: \(why))")
    }

    static func fail(_ msg: String, file: StaticString = #file, line: UInt = #line) {
        currentFailed = true
        let where_ = "\((String(describing: file) as NSString).lastPathComponent):\(line)"
        failed.append("\(current): \(msg) [\(where_)]")
        print("  \(where_): \(msg)")
    }

    static func eq<V: Equatable>(_ a: V, _ b: V, _ note: String = "", file: StaticString = #file, line: UInt = #line) {
        if a != b { fail("expected \(b), got \(a) \(note)", file: file, line: line) }
    }

    static func ok(_ c: Bool, _ note: String, file: StaticString = #file, line: UInt = #line) {
        if !c { fail(note, file: file, line: line) }
    }
}

/// Deterministic random source for property tests (same cases on every run).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension SeededRandom {
    static let words = ["привет", "мир", "deploy", "pull", "request", "Figma", "созвон", "завтра", "в", "11",
                        "GitHub", "ок", "release", "API", "тест", "Москва", "и", "но", "code", "review"]
    mutating func phrase(_ maxWords: Int = 8) -> String {
        (0..<Int.random(in: 0...maxWords, using: &self)).map { _ in Self.words.randomElement(using: &self)! }.joined(separator: " ")
    }
}
