import Foundation

/// Pure logic: stats, text cleanup, language guess, streaming cut points, correction learning,
/// vocabulary rules, Neural Engine file naming. Expectations come from what the feature promises
/// to the user, not from the current output.
enum UnitTests {
    static let cal = Calendar.current
    /// Fixed "now" at noon, so day arithmetic never lands on a DST switch or midnight.
    static let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 18, hour: 12))!

    static func entry(_ text: String, daysAgo: Int = 0, app: String? = "Slack", lang: String = "ru", seconds: Double = 10) -> HistoryEntry {
        HistoryEntry(id: UUID(), date: cal.date(byAdding: .day, value: -daysAgo, to: now)!, text: text, lang: lang, app: app, seconds: seconds)
    }

    static func run() {
        stats()
        formatting()
        textCleanup()
        language()
        streamingCuts()
        learning()
        vocabularyRules()
        neuralEngineNames()
    }

    // MARK: Stats dashboard

    static func stats() {
        T.test("stats: words, chars and dictations are summed over entries") {
            let s = DictationStats([entry("раз два три", seconds: 3), entry("four five", seconds: 2)])
            T.eq(s.dictations, 2)
            T.eq(s.words, 5)
            T.eq(s.chars, "раз два три".count + "four five".count)
            T.eq(s.seconds, 5)
        }
        T.test("stats: words are split on any whitespace, not just spaces") {
            T.eq(DictationStats.wordCount("  a\tb\nc   d  "), 4)
            T.eq(DictationStats.wordCount(""), 0)
        }
        T.test("stats: speed is words per minute of speaking") {
            let s = DictationStats([entry(Array(repeating: "слово", count: 60).joined(separator: " "), seconds: 30)])
            T.eq(s.wpm, 120)
        }
        T.test("stats: no speaking time means speed 0, not a crash or infinity") {
            T.eq(DictationStats([]).wpm, 0)
            T.eq(DictationStats([entry("a b", seconds: 0)]).wpm, 0)
        }
        T.test("stats: time saved = typing at 40 wpm minus speaking time") {
            // 80 words take 2 min to type; spoken in 30 s → 90 s saved.
            let s = DictationStats([entry(Array(repeating: "w", count: 80).joined(separator: " "), seconds: 30)])
            T.eq(s.savedSeconds, 90)
        }
        T.test("stats: time saved is never negative (slow dictation)") {
            T.eq(DictationStats([entry("one", seconds: 60)]).savedSeconds, 0)
        }
        T.test("stats: apps and languages ranked by words, unknown app shown as a dash") {
            let s = DictationStats([entry("a", app: "Notes"), entry("a b c", app: "Slack"), entry("a b", app: nil, lang: "en")])
            T.eq(s.apps.map(\.name), ["Slack", "—", "Notes"])
            T.eq(s.apps.map(\.words), [3, 2, 1])
            T.eq(s.langs.map(\.code), ["ru", "en"])
            T.eq(s.langs.map(\.words), [4, 2])
        }
        T.test("stats: daily chart has one bar per day, oldest first, ending today") {
            let d = DictationStats.daily([entry("a b", daysAgo: 0), entry("c", daysAgo: 0), entry("d e f", daysAgo: 2)], days: 3, now: now)
            T.eq(d.count, 3)
            T.eq(d.map(\.words), [3, 0, 3])
            T.ok(cal.isDate(d.last!.day, inSameDayAs: now), "last bar is today")
            T.ok(d[0].day < d[1].day && d[1].day < d[2].day, "bars are in chronological order")
        }
        T.test("stats: daily chart ignores entries older than the window") {
            T.eq(DictationStats.daily([entry("old words here", daysAgo: 10)], days: 7, now: now).map(\.words).reduce(0, +), 0)
        }
        T.test("stats: streak counts consecutive days ending today") {
            T.eq(DictationStats.streak([entry("a", daysAgo: 0), entry("a", daysAgo: 1), entry("a", daysAgo: 2), entry("a", daysAgo: 4)], now: now), 3)
        }
        T.test("stats: streak still counts when nothing has been dictated yet today") {
            T.eq(DictationStats.streak([entry("a", daysAgo: 1), entry("a", daysAgo: 2)], now: now), 2)
        }
        T.test("stats: streak is 0 when the last dictation was two days ago, or never") {
            T.eq(DictationStats.streak([entry("a", daysAgo: 2)], now: now), 0)
            T.eq(DictationStats.streak([], now: now), 0)
        }
        T.test("stats: several dictations on one day count as one streak day") {
            T.eq(DictationStats.streak([entry("a"), entry("b"), entry("c")], now: now), 1)
        }
        T.test("stats: period filter — today, last 7 days, last 30 days, all") {
            let d = { (n: Int) in cal.date(byAdding: .day, value: -n, to: now)! }
            T.ok(StatsPane.Period.today.includes(d(0), now: now), "today includes today")
            T.ok(!StatsPane.Period.today.includes(d(1), now: now), "today excludes yesterday")
            T.ok(StatsPane.Period.week.includes(d(6), now: now), "7 days include 6 days ago")
            T.ok(!StatsPane.Period.week.includes(d(7), now: now), "7 days exclude 7 days ago")
            T.ok(StatsPane.Period.month.includes(d(29), now: now), "30 days include 29 days ago")
            T.ok(!StatsPane.Period.month.includes(d(30), now: now), "30 days exclude 30 days ago")
            T.ok(StatsPane.Period.all.includes(d(3000), now: now), "all time includes everything")
        }
    }

    // MARK: Russian formatting on the dashboard

    static func formatting() {
        T.test("format: Russian plural forms for days") {
            let cases: [(Int, String)] = [(0, "дней"), (1, "день"), (2, "дня"), (4, "дня"), (5, "дней"), (11, "дней"),
                                          (12, "дней"), (14, "дней"), (21, "день"), (22, "дня"), (25, "дней"), (101, "день"), (111, "дней")]
            for (n, want) in cases { T.eq(StatsPane.plural(n, "день", "дня", "дней"), want, "for \(n)") }
        }
        T.test("format: durations in seconds, minutes, hours") {
            T.eq(StatsPane.duration(0), "0 с")
            T.eq(StatsPane.duration(59), "59 с")
            T.eq(StatsPane.duration(60), "1 мин")
            T.eq(StatsPane.duration(3599), "59 мин")
            T.eq(StatsPane.duration(3600), "1 ч 0 мин")
            T.eq(StatsPane.duration(3 * 3600 + 25 * 60), "3 ч 25 мин")
        }
        T.test("format: big numbers get a thousands separator") {
            let s = StatsPane.num(1_234_567)
            T.eq(s.filter(\.isNumber), "1234567")
            T.ok(s.count > 7, "has separators: \(s)")
            T.eq(StatsPane.num(999), "999")
        }
    }

    // MARK: Whisper output cleanup

    static func textCleanup() {
        T.test("clean: classic hallucinations on silence become empty") {
            for junk in ["Продолжение следует...", "Субтитры сделал DimaTorzok", "Спасибо за просмотр!",
                         "Thank you for watching.", "[BLANK_AUDIO]", "[Музыка]", "(музыка)", "...", " - "] {
                T.eq(Transcriber.clean(junk), "", "for \(junk)")
            }
        }
        T.test("clean: a real long phrase that merely contains a junk phrase is kept") {
            let s = "Напиши в конце письма спасибо за просмотр презентации и приложи ссылку на отчёт"
            T.eq(Transcriber.clean(s), s)
        }
        T.test("clean: trims and collapses double spaces") {
            T.eq(Transcriber.clean("  привет   мир \n"), "привет мир")
        }
        T.test("clean: a looping sentence is collapsed to one") {
            T.eq(Transcriber.clean("Созвон в 11. Созвон в 11. Созвон в 11."), "Созвон в 11.")
        }
        T.test("clean: different sentences are left alone") {
            let s = "Привет. Как дела? Созвон в 11."
            T.eq(Transcriber.clean(s), s)
        }
    }

    // MARK: Auto language (labels history/stats; decides how the next streamed piece is decoded)

    static func language() {
        T.test("language: mostly Latin text is English, mostly Cyrillic is Russian") {
            T.eq(Transcriber.scriptLanguage("Let's ship the release on Friday"), "en")
            T.eq(Transcriber.scriptLanguage("Давай выкатим релиз в пятницу"), "ru")
        }
        T.test("language: Russian with a few English terms stays Russian") {
            T.eq(Transcriber.scriptLanguage("Посмотри pull request и сделай deploy"), "ru")
        }
        T.test("language: no letters at all defaults to Russian (auto is biased to ru)") {
            T.eq(Transcriber.scriptLanguage(""), "ru")
            T.eq(Transcriber.scriptLanguage("123 456"), "ru")
        }
    }

    // MARK: Streaming: where a long dictation is cut into pieces

    static let rate = 16_000.0

    /// `spec`: (seconds, amplitude) segments; noise is deterministic.
    static func audio(_ spec: [(Double, Float)]) -> [Float] {
        var rng = SeededRandom(42)
        var out: [Float] = []
        for (sec, amp) in spec {
            for _ in 0..<Int(sec * rate) { out.append(amp == 0 ? 0 : Float.random(in: -amp...amp, using: &rng)) }
        }
        return out
    }

    static func streamingCuts() {
        T.test("stream: cuts in the middle of a pause after 5 s of speech") {
            let a = audio([(6, 0.5), (0.6, 0), (3, 0.5)])
            guard let cut = StreamingDictation.findCut(a, rate: rate, force: false) else { return T.fail("no cut found") }
            T.ok(cut >= Int(6.0 * rate) && cut <= Int(6.6 * rate), "cut at \(Double(cut) / rate)s should be inside the 6.0–6.6 s pause")
        }
        T.test("stream: picks the latest pause when there are several") {
            let a = audio([(5.5, 0.5), (0.5, 0), (3, 0.5), (0.5, 0), (2, 0.5)])
            guard let cut = StreamingDictation.findCut(a, rate: rate, force: false) else { return T.fail("no cut found") }
            T.ok(cut >= Int(9.0 * rate) && cut <= Int(9.5 * rate), "cut at \(Double(cut) / rate)s should be in the second pause (9.0–9.5 s)")
        }
        T.test("stream: never cuts a piece shorter than 5 s, even at a pause") {
            let a = audio([(2, 0.5), (0.6, 0), (6, 0.5)])
            T.eq(StreamingDictation.findCut(a, rate: rate, force: false), nil)
        }
        T.test("stream: a pause shorter than 0.3 s is not a cut point") {
            // Loud/medium alternation every 0.1 s: never quiet long enough.
            var spec: [(Double, Float)] = []
            for i in 0..<100 { spec.append((0.1, i % 2 == 0 ? 0.5 : 0.25)) }
            T.eq(StreamingDictation.findCut(audio(spec), rate: rate, force: false), nil)
        }
        T.test("stream: when forced (25 s without a pause) it still cuts, after 5 s") {
            var spec: [(Double, Float)] = []
            for i in 0..<100 { spec.append((0.1, i % 2 == 0 ? 0.5 : 0.25)) }
            let a = audio(spec)
            guard let cut = StreamingDictation.findCut(a, rate: rate, force: true) else { return T.fail("forced cut returned nil") }
            T.ok(cut >= Int(5 * rate) && cut < a.count, "forced cut at \(Double(cut) / rate)s must be within 5 s…end")
        }
        T.test("stream: tiny or empty audio is never cut") {
            T.eq(StreamingDictation.findCut([], rate: rate, force: true), nil)
            T.eq(StreamingDictation.findCut([0.1, 0.2], rate: rate, force: true), nil)
        }
        T.test("stream: works at the Mac mic's native 48 kHz too") {
            let r48 = 48_000.0
            var rng = SeededRandom(7)
            var a: [Float] = []
            for (sec, amp) in [(6.0, Float(0.5)), (0.6, 0), (2.0, 0.5)] as [(Double, Float)] {
                for _ in 0..<Int(sec * r48) { a.append(amp == 0 ? 0 : Float.random(in: -amp...amp, using: &rng)) }
            }
            guard let cut = StreamingDictation.findCut(a, rate: r48, force: false) else { return T.fail("no cut at 48 kHz") }
            T.ok(cut >= Int(6.0 * r48) && cut <= Int(6.6 * r48), "cut at \(Double(cut) / r48)s")
        }
    }

    // MARK: Learning from corrections

    static func learning() {
        T.test("learn: a misheard phrase becomes a replacement rule and the English term a dictionary word") {
            let r = CorrectionLearner.learn(original: "посмотри пул реквест пожалуйста", corrected: "посмотри pull request пожалуйста")
            T.eq(r.rules.map { "\($0.0) => \($0.1)" }, ["пул реквест => pull request"])
            T.eq(r.terms, ["pull request"])
        }
        T.test("learn: case-only fix of a brand is remembered as a term, without a rule") {
            let r = CorrectionLearner.learn(original: "открой figma", corrected: "открой Figma")
            T.ok(r.rules.isEmpty, "no rule for a case-only change, got \(r.rules)")
            T.eq(r.terms, ["Figma"])
        }
        T.test("learn: no change teaches nothing") {
            let r = CorrectionLearner.learn(original: "Созвон в 11", corrected: "Созвон в 11")
            T.ok(r.rules.isEmpty && r.terms.isEmpty, "got \(r.rules) \(r.terms)")
        }
        T.test("learn: punctuation-only edits teach nothing") {
            let r = CorrectionLearner.learn(original: "привет как дела", corrected: "Привет, как дела?")
            T.ok(r.rules.isEmpty, "got rules \(r.rules)")
        }
        T.test("learn: ordinary Russian words that were added are not dictionary terms") {
            let r = CorrectionLearner.learn(original: "созвон завтра", corrected: "созвон перенесли на завтра")
            T.ok(r.terms.isEmpty, "got terms \(r.terms)")
        }
        T.test("learn: a rewrite of more than 4 words is not turned into a rule") {
            let r = CorrectionLearner.learn(original: "раз два три четыре пять", corrected: "one two three four five")
            T.ok(r.rules.isEmpty, "got \(r.rules)")
        }
        T.test("learn (property): correcting a text to itself never produces rules or terms") {
            var rng = SeededRandom(1)
            for _ in 0..<300 {
                let s = rng.phrase(10)
                let r = CorrectionLearner.learn(original: s, corrected: s)
                if !r.rules.isEmpty || !r.terms.isEmpty { return T.fail("'\(s)' → \(r.rules) \(r.terms)") }
            }
        }
        T.test("learn (property): every rule's right side appears in the corrected text") {
            var rng = SeededRandom(2)
            for _ in 0..<300 {
                let a = rng.phrase(8), b = rng.phrase(8)
                for (_, to) in CorrectionLearner.learn(original: a, corrected: b).rules where !b.contains(to) {
                    return T.fail("rule target '\(to)' not in '\(b)'")
                }
            }
        }
    }

    // MARK: Vocabulary rule parsing

    static func vocabularyRules() {
        T.test("vocab: rules accept =>, → and -> separators") {
            for line in ["пул реквест => pull request", "пул реквест → pull request", "пул реквест -> pull request"] {
                guard let r = Vocabulary.parseRule(line) else { T.fail("not parsed: \(line)"); continue }
                T.eq(r.0, "пул реквест"); T.eq(r.1, "pull request")
            }
        }
        T.test("vocab: lines without a separator or with an empty left side are ignored") {
            T.ok(Vocabulary.parseRule("просто слово") == nil, "no separator")
            T.ok(Vocabulary.parseRule(" => что-то") == nil, "empty left side")
        }
        T.test("vocab: longer patterns are applied first") {
            let rs = Vocabulary.rules(from: ["ю эс би => USB", "ю эс би си => USB-C"])
            T.eq(rs.first?.from, "ю эс би си")
        }
        T.test("vocab: a rule matches whole words only, case-insensitively") {
            guard let re = Vocabulary.makeRegex("пул") else { return T.fail("no regex") }
            func count(_ s: String) -> Int { re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
            T.eq(count("Пул готов"), 1)
            T.eq(count("пулемёт и спулить"), 0)
        }
        T.test("vocab: casing map keeps the canonical spelling of each term") {
            let m = Vocabulary.casingMap(["GitHub", "iOS", "Москва"])
            T.eq(m["github"], "GitHub")
            T.eq(m["ios"], "iOS")
        }
    }

    // MARK: Neural Engine encoder naming (must match the files on huggingface.co/ggerganov/whisper.cpp)

    static func neuralEngineNames() {
        T.test("neural engine: encoder name drops the quantisation suffix") {
            T.eq(NeuralEngine.encoderName(for: URL(fileURLWithPath: "/m/ggml-large-v3-turbo-q5_0.bin")), "ggml-large-v3-turbo-encoder.mlmodelc")
            T.eq(NeuralEngine.encoderName(for: URL(fileURLWithPath: "/m/ggml-medium-q8_0.bin")), "ggml-medium-encoder.mlmodelc")
        }
        T.test("neural engine: unquantised and .en models keep their full name") {
            T.eq(NeuralEngine.encoderName(for: URL(fileURLWithPath: "/m/ggml-large-v3-turbo.bin")), "ggml-large-v3-turbo-encoder.mlmodelc")
            T.eq(NeuralEngine.encoderName(for: URL(fileURLWithPath: "/m/ggml-base.en.bin")), "ggml-base.en-encoder.mlmodelc")
        }
    }
}
