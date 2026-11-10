import Foundation

/// File locations: ~/Library/Application Support/JustTellMe/ (JTM_SUPPORT_DIR overrides it, used by tests).
enum Paths {
    static let support: URL = {
        let u = ProcessInfo.processInfo.environment["JTM_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustTellMe", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let models: URL = {
        let u = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var prompt: URL { support.appendingPathComponent("prompt.txt") }
    static var dictionary: URL { support.appendingPathComponent("dictionary.txt") }
    static var replacements: URL { support.appendingPathComponent("replacements.txt") }
}


/// "Learning from corrections": word-level diff between what was recognised and what the user
/// corrected it to. Changed spans become replacement rules, new words go to the dictionary.
enum CorrectionLearner {
    struct Result { var rules: [(String, String)] = []; var terms: [String] = [] }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "+#@&")))
        }.filter { !$0.isEmpty }
    }

    /// Worth putting into the prompt: contains Latin letters, or is capitalised (names, brands).
    static func isTermLike(_ s: String) -> Bool {
        if s.unicodeScalars.contains(where: { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) { return true }
        return s.first?.isUppercase ?? false
    }

    static func learn(original: String, corrected: String) -> Result {
        let a = words(original), b = words(corrected)
        let al = a.map { $0.lowercased() }, bl = b.map { $0.lowercased() }
        // LCS table
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = al[i] == bl[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var res = Result()
        var i = 0, j = 0
        var delA: [String] = [], insB: [String] = []
        func flush() {
            if !insB.isEmpty {
                if !delA.isEmpty && delA.count <= 4 && insB.count <= 4 {
                    res.rules.append((delA.joined(separator: " "), insB.joined(separator: " ")))
                }
                // Terms = maximal runs of term-like words ("на Figma" -> "Figma", "pull request" stays).
                var run: [String] = []
                func endRun() {
                    let phrase = run.joined(separator: " ")
                    if !run.isEmpty && run.count <= 4 && phrase.count >= 2 { res.terms.append(phrase) }
                    run.removeAll()
                }
                for w in insB { if isTermLike(w) { run.append(w) } else { endRun() } }
                endRun()
            }
            delA.removeAll(); insB.removeAll()
        }
        while i < n || j < m {
            if i < n && j < m && al[i] == bl[j] {
                flush()
                // Case-only change of a word (e.g. figma -> Figma) is worth remembering as a term.
                if a[i] != b[j] { res.terms.append(b[j]) }
                i += 1; j += 1
            } else if j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j]) {
                insB.append(b[j]); j += 1
            } else {
                delA.append(a[i]); i += 1
            }
        }
        flush()
        return res
    }
}
