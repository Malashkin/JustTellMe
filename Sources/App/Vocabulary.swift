import Foundation

/// Two vocabularies:
///  * built-in (bundled, read-only, generic ru/en tech/business/everyday terms + replacement rules),
///    can be switched off;
///  * personal (~/Library/Application Support/JustTellMe/dictionary.txt + replacements.txt),
///    empty by default, never bundled; all user edits and learned corrections go here.
/// Terms are used for (1) the whisper initial prompt and (2) canonical casing of Latin words in
/// Russian output (zoom -> Zoom). Rules are applied after transcription.
final class Vocabulary {
    static let shared = Vocabulary()

    /// Generic priming sentence: tells whisper that English terms appear in Latin inside Russian text.
    static let defaultPrompt = "Привет! Это диктовка на русском, где English words пишутся латиницей: deploy, pull request, feedback."

    static let dictionaryHeader = "# Личный словарь JustTellMe: по одному термину/имени на строку. Строки с # игнорируются.\n"
    static let replacementsHeader = """
    # Личные замены JustTellMe: «неправильно => правильно», по одной на строку (регистр не важен).
    # Пример:
    # пул реквест => pull request

    """

    typealias Rule = (from: String, to: String, regex: NSRegularExpression)

    private(set) var basePrompt = defaultPrompt
    private(set) var personalTerms: [String] = []
    private(set) var personalRules: [Rule] = []
    private(set) var builtinTerms: [String] = []
    private(set) var builtinPromptTerms: [String] = []
    private(set) var builtinRules: [Rule] = []
    private var casing: [String: String] = [:]
    private let lock = NSLock()

    var builtinEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "builtinDictionary") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "builtinDictionary"); reload() }
    }

    static var builtinTermsURL: URL? { Bundle.main.url(forResource: "builtin_terms", withExtension: "txt") }
    static var builtinRulesURL: URL? { Bundle.main.url(forResource: "builtin_replacements", withExtension: "txt") }

    init() { reload() }

    // MARK: Load / save

    func reload() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.dictionary.path) { try? Self.dictionaryHeader.write(to: Paths.dictionary, atomically: true, encoding: .utf8) }
        if !fm.fileExists(atPath: Paths.replacements.path) { try? Self.replacementsHeader.write(to: Paths.replacements, atomically: true, encoding: .utf8) }

        // prompt.txt exists only if the user customised the prompt.
        let customPrompt = (try? String(contentsOf: Paths.prompt, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pTerms = Self.lines(Paths.dictionary)
        let pRules = Self.rules(from: Self.lines(Paths.replacements))

        var bAll: [String] = [], bPrompt: [String] = []
        if let u = Self.builtinTermsURL {
            for l in Self.lines(u) {
                if l.hasPrefix("*") {
                    let t = String(l.dropFirst()).trimmingCharacters(in: .whitespaces)
                    bPrompt.append(t); bAll.append(t)
                } else { bAll.append(l) }
            }
        }
        let bRules = Self.builtinRulesURL.map { Self.rules(from: Self.lines($0)) } ?? []

        lock.lock()
        basePrompt = customPrompt ?? Self.defaultPrompt
        personalTerms = pTerms
        personalRules = pRules
        builtinTerms = bAll
        builtinPromptTerms = bPrompt
        builtinRules = bRules
        casing = Self.casingMap(pTerms + (builtinEnabled ? bAll : []))
        lock.unlock()
    }

    static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func parseRule(_ line: String) -> (String, String)? {
        for sep in ["=>", "→", "->"] {
            if let r = line.range(of: sep) {
                let a = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let b = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return a.isEmpty ? nil : (a, b)
            }
        }
        return nil
    }

    /// Longest patterns first, so "ю эс би си" wins over "ю эс би".
    static func rules(from lines: [String]) -> [Rule] {
        lines.compactMap(parseRule)
            .compactMap { p in makeRegex(p.0).map { (p.0, p.1, $0) } }
            .sorted { $0.from.count > $1.from.count }
    }

    static func makeRegex(_ phrase: String) -> NSRegularExpression? {
        // Whole word(s), case-insensitive, flexible whitespace/hyphen between words.
        let words = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let body = words.joined(separator: "[\\s\\-]+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    /// lowercase single Latin word -> canonical spelling, only for terms with capitals (iPhone, API, Zoom).
    static func casingMap(_ terms: [String]) -> [String: String] {
        var m: [String: String] = [:]
        for t in terms where !t.contains(" ") && t != t.lowercased() && t.unicodeScalars.allSatisfy({ $0.isASCII }) {
            m[t.lowercased()] = m[t.lowercased()] ?? t
        }
        return m
    }

    /// Save personal files from the editor. A prompt equal to the default is not stored.
    func save(prompt: String, dictionary: String, replacements: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == Self.defaultPrompt { try? FileManager.default.removeItem(at: Paths.prompt) }
        else { try? p.write(to: Paths.prompt, atomically: true, encoding: .utf8) }
        try? dictionary.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        try? replacements.write(to: Paths.replacements, atomically: true, encoding: .utf8)
        reload()
    }

    /// Adds to the PERSONAL dictionary (skips anything already known, built-in included).
    func addTerms(_ new: [String]) -> [String] {
        let existing = Set((personalTerms + (builtinEnabled ? builtinTerms : [])).map { $0.lowercased() })
        var seen = Set<String>()
        let add = new.filter { t in
            let l = t.lowercased()
            return !existing.contains(l) && seen.insert(l).inserted
        }
        if add.isEmpty { return [] }
        append(Paths.dictionary, add)
        reload()
        return add
    }

    func addRules(_ new: [(String, String)]) -> [(String, String)] {
        let existing = Set((personalRules + (builtinEnabled ? builtinRules : [])).map { $0.from.lowercased() })
        let add = new.filter { !existing.contains($0.0.lowercased()) && $0.0.lowercased() != $0.1.lowercased() }
        if add.isEmpty { return [] }
        append(Paths.replacements, add.map { "\($0.0) => \($0.1)" })
        reload()
        return add
    }

    private func append(_ url: URL, _ lines: [String]) {
        var s = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        s += lines.joined(separator: "\n") + "\n"
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Use

    /// Initial prompt: priming sentence + personal terms (priority, newest first kept) + the
    /// built-in shortlist if room is left. Whisper keeps only ~224 tokens of prompt.
    func prompt() -> String {
        lock.lock(); defer { lock.unlock() }
        let budget = 420
        var list: [String] = []
        var len = 0
        for t in personalTerms.reversed() {
            if len + t.count + 2 > budget { break }
            list.insert(t, at: 0); len += t.count + 2
        }
        if builtinEnabled {
            let have = Set(list.map { $0.lowercased() })
            for t in builtinPromptTerms where !have.contains(t.lowercased()) && !basePrompt.lowercased().contains(t.lowercased()) {
                if len + t.count + 2 > budget { break }
                list.append(t); len += t.count + 2
            }
        }
        var p = basePrompt
        if !list.isEmpty {
            // Continue the priming sentence's list: "..., feedback, commit, merge, Zoom."
            if p.hasSuffix(".") { p.removeLast(); p += ", " } else if !p.isEmpty { p += " " }
            p += list.joined(separator: ", ") + "."
        }
        return p
    }

    /// Post-processing: personal rules, then built-in rules (for patterns not overridden),
    /// then canonical casing of Latin words — the last two only for Russian output.
    func apply(_ text: String, lang: String) -> String {
        lock.lock()
        let pr = personalRules
        let br = builtinEnabled ? builtinRules : []
        let cm = casing
        lock.unlock()

        var t = text
        func run(_ rs: [Rule]) {
            for r in rs {
                t = r.regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                                     withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
            }
        }
        run(pr)
        guard lang != "en" else { return t }
        let overridden = Set(pr.map { $0.from.lowercased() })
        run(br.filter { !overridden.contains($0.from.lowercased()) })

        if !cm.isEmpty, let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])[A-Za-z][A-Za-z0-9]*(?![\\p{L}\\p{N}])") {
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let w = ns.substring(with: m.range)
                out += cm[w.lowercased()] ?? w
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t
    }
}
