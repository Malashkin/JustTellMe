import CryptoKit
import Foundation

/// Real files and the real app binary. Everything runs inside a temporary JTM_SUPPORT_DIR,
/// so the user's history, dictionary and models are never touched.
enum IntegrationTests {
    static var support: URL { Paths.support }

    static func run() {
        guard ProcessInfo.processInfo.environment["JTM_SUPPORT_DIR"] != nil else {
            T.skip("integration", "JTM_SUPPORT_DIR not set — refusing to touch real user data")
            return
        }
        history()
        vocabulary()
        builtinDictionary()
        binary()
    }

    // MARK: History file (feeds the home feed and the stats)

    static func history() {
        T.test("history: new dictations are saved newest first and survive a reload from disk") {
            let h = History.shared
            h.clear()
            h.add(text: "первая", lang: "ru", app: "Notes", seconds: 1.5)
            h.add(text: "second", lang: "en", app: nil, seconds: 2)
            T.eq(h.entries.map(\.text), ["second", "первая"])

            let data = try Data(contentsOf: support.appendingPathComponent("history.json"))
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let onDisk = try dec.decode([HistoryEntry].self, from: data)
            T.eq(onDisk.map(\.text), ["second", "первая"])
            T.eq(onDisk.map(\.app), [nil, "Notes"])
            T.eq(onDisk.map(\.seconds), [2, 1.5])
        }
        T.test("history: deleting entries removes exactly those, on disk too") {
            let h = History.shared
            h.clear()
            for t in ["a", "b", "c"] { h.add(text: t, lang: "ru", app: nil, seconds: 1) }
            let b = h.entries.first { $0.text == "b" }!.id
            h.remove(ids: [b])
            T.eq(h.entries.map(\.text), ["c", "a"])
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let onDisk = try dec.decode([HistoryEntry].self, from: Data(contentsOf: support.appendingPathComponent("history.json")))
            T.eq(onDisk.map(\.text), ["c", "a"])
        }
        T.test("history: clear empties the feed and notifies the window") {
            let h = History.shared
            var notified = 0
            h.onChange = { notified += 1 }
            h.add(text: "x", lang: "ru", app: nil, seconds: 1)
            h.clear()
            h.onChange = nil
            T.eq(h.entries.count, 0)
            T.eq(notified, 2)
        }
        T.test("history (property): any entry survives the JSON round trip unchanged") {
            var rng = SeededRandom(3)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            for _ in 0..<200 {
                // ISO-8601 keeps whole seconds; that is the stored precision.
                let date = Date(timeIntervalSince1970: Double(Int.random(in: 1_600_000_000...1_900_000_000, using: &rng)))
                let e = HistoryEntry(id: UUID(), date: date, text: rng.phrase(12) + " ёЁ «»—✓", lang: ["ru", "en"].randomElement(using: &rng)!,
                                     app: Bool.random(using: &rng) ? nil : "App \(Int.random(in: 0...9, using: &rng))",
                                     seconds: Double(Int.random(in: 0...6000, using: &rng)) / 100)
                let back = try dec.decode(HistoryEntry.self, from: enc.encode(e))
                if back.id != e.id || back.date != e.date || back.text != e.text || back.lang != e.lang || back.app != e.app || back.seconds != e.seconds {
                    return T.fail("round trip changed \(e) → \(back)")
                }
            }
        }
    }

    // MARK: Personal dictionary and replacements applied to recognised text

    static func vocabulary() {
        T.test("vocab: personal replacements and term casing are applied to Russian text") {
            try "# my terms\nGitHub\nFigma\n".write(to: Paths.dictionary, atomically: true, encoding: .utf8)
            try "гитхаб => GitHub\nпул реквест -> pull request\n".write(to: Paths.replacements, atomically: true, encoding: .utf8)
            let v = Vocabulary()
            T.eq(v.apply("залей на гитхаб и открой пул реквест", lang: "ru"), "залей на GitHub и открой pull request")
            T.eq(v.apply("скинь макет в figma", lang: "ru"), "скинь макет в Figma")
        }
        T.test("vocab: replacements don't touch parts of longer words") {
            try "пул => pull\n".write(to: Paths.replacements, atomically: true, encoding: .utf8)
            let v = Vocabulary()
            T.eq(v.apply("пулемёт", lang: "ru"), "пулемёт")
        }
        T.test("vocab: English output gets personal rules but no Russian-only casing fixes") {
            try "GitHub\n".write(to: Paths.dictionary, atomically: true, encoding: .utf8)
            try "teh => the\n".write(to: Paths.replacements, atomically: true, encoding: .utf8)
            let v = Vocabulary()
            T.eq(v.apply("push teh fix to github", lang: "en"), "push the fix to github")
        }
        T.test("vocab: saving from the dictionary page writes files that load back the same") {
            let v = Vocabulary()
            v.save(prompt: Vocabulary.defaultPrompt, dictionary: "Zoom\n", replacements: "зум => Zoom\n")
            let w = Vocabulary()
            T.eq(w.personalTerms, ["Zoom"])
            T.eq(w.apply("созвон в зум", lang: "ru"), "созвон в Zoom")
            T.ok(!FileManager.default.fileExists(atPath: Paths.prompt.path), "default prompt is not stored as a custom one")
        }
    }

    // MARK: Built-in dictionary shipped to every user

    static func builtinDictionary() {
        let res = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JTM_RESOURCES"] ?? "Resources")
        let terms = res.appendingPathComponent("builtin_terms.txt"), rules = res.appendingPathComponent("builtin_replacements.txt")
        guard FileManager.default.fileExists(atPath: terms.path) else { return T.skip("builtin dictionary", "Resources not found") }

        T.test("builtin: contains no client-specific names (other users see this dictionary)") {
            // SHA-256 of the banned names (Latin and Cyrillic), so the names themselves are not published.
            let banned: Set<String> = ["621e187b1890d349f274e855802c4b69bed4344baa78ed15f43804357f320df1",
                                       "dbcdf626839ab91138daad2a8e7d58334b4d7201a62b0b8846f64c4bcab3b66a",
                                       "4f9f278e68a29db5e5c872028a06d54cd59af933cb74874dca8dae5d08049ce3",
                                       "49bd18e8a176ca753f9d25ea3b91d9af3274018d02daa60ace7f8f40f5e58d50"]
            let all = (try String(contentsOf: terms, encoding: .utf8) + String(contentsOf: rules, encoding: .utf8)).lowercased()
            for w in Set(all.split(whereSeparator: { !$0.isLetter }).map(String.init)) where banned.contains(sha256(w)) {
                T.fail("found a banned name: \(w)")
            }
        }
        T.test("builtin: every replacement line is a valid rule") {
            for line in Vocabulary.lines(rules) where Vocabulary.parseRule(line) == nil || Vocabulary.makeRegex(Vocabulary.parseRule(line)!.0) == nil {
                T.fail("bad rule line: \(line)")
            }
        }
    }

    // MARK: The app binary (hidden CLI modes use the same code paths as the app)

    static func binary() {
        guard let bin = ProcessInfo.processInfo.environment["JTM_APP_BIN"], FileManager.default.isExecutableFile(atPath: bin) else {
            return T.skip("binary", "JTM_APP_BIN not set — build the app first")
        }
        T.test("binary: --learn prints the rule and the term it would learn") {
            let out = try run(bin, ["--learn", "посмотри пул реквест", "посмотри pull request"]).out
            T.ok(out.contains("rule: пул реквест => pull request"), "output: \(out)")
            T.ok(out.contains("term: pull request"), "output: \(out)")
        }
        T.test("binary: --list-models finds the bundled model and marks it active") {
            let out = try run(bin, ["--list-models"]).out
            T.ok(out.contains("[bundled]") && out.contains("large-v3-turbo"), "output: \(out)")
            T.ok(out.contains("active: ") && !out.contains("active: none"), "output: \(out)")
        }
        if ProcessInfo.processInfo.environment["JTM_SKIP_SLOW"] == "1" {
            return T.skip("binary: speech recognition", "JTM_SKIP_SLOW=1")
        }
        T.test("binary: Russian speech with English terms is recognised, terms stay in Latin") {
            let wav = try tts("Milena", "Привет! Посмотри, пожалуйста, мой pull request до пятницы.")
            let r = try run(bin, ["--transcribe", wav.path, "--lang", "auto"], timeout: 180)
            let text = r.out.lowercased()
            T.eq(r.status, 0, r.err)
            T.ok(text.contains("привет") && text.contains("пятниц"), "Russian words missing: \(r.out)")
            T.ok(text.contains("pull request"), "English term should stay Latin: \(r.out)")
        }
        T.test("binary: long dictation is transcribed in pieces while speaking and is ready fast after release") {
            let sentence = "Сегодня мы обсуждаем релиз нового приложения для диктовки. Нужно проверить, как оно работает на длинных фразах."
            let wav = try tts("Milena", sentence + " " + sentence + " " + sentence)
            let r = try run(bin, ["--stream", wav.path, "--lang", "auto"], timeout: 300)
            T.eq(r.status, 0, r.err)
            // stderr: "audio 21.1s, pieces sent while speaking: 2, ready 0.91s after release"
            let m = r.err.range(of: #"pieces sent while speaking: (\d+), ready ([\d.]+)s"#, options: .regularExpression).map { String(r.err[$0]) } ?? ""
            let nums = m.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard nums.count == 2 else { return T.fail("no timing line in: \(r.err)") }
            T.ok(nums[0] >= 1, "a long dictation should be split while speaking, pieces = \(nums[0])")
            T.ok(nums[1] < 15, "ready \(nums[1])s after release — far slower than the ~1–3 s target")
            T.ok(r.out.lowercased().contains("диктовк"), "text: \(r.out)")
            print("  (stream: \(Int(nums[0])) piece(s) early, ready \(nums[1])s after release)")
        }
    }

    struct Run { var status: Int32; var out: String; var err: String }

    static func run(_ bin: String, _ args: [String], timeout: TimeInterval = 30) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        let outData = DispatchGroup()
        var out = Data(), err = Data()
        outData.enter(); DispatchQueue.global().async { out = o.fileHandleForReading.readDataToEndOfFile(); outData.leave() }
        outData.enter(); DispatchQueue.global().async { err = e.fileHandleForReading.readDataToEndOfFile(); outData.leave() }
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(args.first ?? "") timed out"]) }
        outData.wait()
        return Run(status: p.terminationStatus, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }

    /// Speech from macOS text-to-speech as 16 kHz WAV.
    static func tts(_ voice: String, _ text: String) throws -> URL {
        let url = support.appendingPathComponent("tts-\(abs(text.hashValue)).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "say failed"]) }
        return url
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
