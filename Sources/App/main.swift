import Cocoa

// Hidden CLI modes (for testing the exact same code paths without UI):
//   JustTellMe --transcribe file.wav [--lang auto|ru|en] [--model path.bin] [--no-prompt]
//              [--prompt "..."] [--no-fast] [--repeat N] [--verbose]
//   JustTellMe --learn "recognised text" "corrected text"     (prints what would be learned)
//   JustTellMe --list-models
let args = CommandLine.arguments
func opt(_ name: String) -> String? {
    guard let j = args.firstIndex(of: name), j + 1 < args.count else { return nil }
    return args[j + 1]
}
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

if args.contains("--list-models") {
    for m in ModelManager.available() { print("\(m.bundled ? "[bundled]" : "[user]   ") \(m.name)  \(m.sizeMB) MB  \(m.url.path)") }
    print("active: \(ModelManager.active()?.url.path ?? "none")")
    exit(0)
}

if let i = args.firstIndex(of: "--learn"), i + 2 < args.count {
    let r = CorrectionLearner.learn(original: args[i + 1], corrected: args[i + 2])
    for (a, b) in r.rules { print("rule: \(a) => \(b)") }
    for t in r.terms { print("term: \(t)") }
    exit(0)
}

if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    let lang = opt("--lang") ?? "auto"
    let repeatN = Int(opt("--repeat") ?? "1") ?? 1
    let verbose = args.contains("--verbose")
    let fast = !args.contains("--no-fast")
    let modelURL = opt("--model").map { URL(fileURLWithPath: $0) }
        ?? ProcessInfo.processInfo.environment["JTM_MODEL"].map { URL(fileURLWithPath: $0) }
        ?? ModelManager.active()?.url
    guard let modelURL else { log("ERROR: no model found"); exit(2) }
    let prompt: String? = args.contains("--no-prompt") ? nil : (opt("--prompt") ?? Vocabulary.shared.prompt())

    let t = Transcriber()
    let t0 = Date()
    guard t.loadSync(modelURL, verbose: verbose) else { log("ERROR: failed to load model \(modelURL.path)"); exit(2) }
    log(String(format: "model load: %.2fs (threads=%d, model=%@, fast=%d)", Date().timeIntervalSince(t0), t.threads, modelURL.lastPathComponent, fast ? 1 : 0))
    log("prompt: \(prompt ?? "<none>")")

    let audio: [Float]
    do { audio = try AudioUtil.loadFile(URL(fileURLWithPath: args[i + 1])) } catch { log("ERROR: cannot read audio: \(error)"); exit(3) }
    log(String(format: "audio: %.2fs", Double(audio.count) / 16_000))

    for r in 0..<repeatN {
        let res = t.transcribeSync(audio, language: lang, prompt: prompt, fast: fast)
        log(String(format: "run %d: %.2fs, lang=%@", r + 1, res.seconds, res.lang))
        if res.raw != res.text { log("raw (before replacements): \(res.raw)") }
        if r == repeatN - 1 { print(res.text) }
    }
    exit(0)
}

//   JustTellMe --demo-overlay        (shows the recording pill for a few seconds, for screenshots)
if args.contains("--demo-overlay") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let o = RecordingOverlay()
    o.show(.recording)
    var t = 0.0
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        t += 0.05
        o.push(level: Float(0.02 + 0.08 * abs(sin(t * 3))))
    }
    let snap = opt("--demo-overlay")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if let p = snap, p.hasSuffix(".png") { o.snapshot(to: URL(fileURLWithPath: p + "-rec.png")) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { o.show(.transcribing) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if let p = snap, p.hasSuffix(".png") { o.snapshot(to: URL(fileURLWithPath: p + "-tr.png")) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { o.hide() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) { exit(0) }
    app.run()
}

//   JustTellMe --demo-stats out.png   (renders the dashboard with synthetic history, for checking the layout)
if let out = opt("--demo-stats") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let texts = ["Привет, посмотри пожалуйста этот pull request и оставь комментарии", "Let's ship the release on Friday",
                 "Созвон переносим на завтра в 11", "Нужно обновить README и добавить скриншоты", "Thanks, looks good to me"]
    let apps = ["Slack", "Telegram", "Cursor", "Google Chrome", "Notes"]
    var fake: [HistoryEntry] = []
    for i in 0..<180 {
        let t = texts[i % texts.count]
        fake.append(HistoryEntry(id: UUID(), date: Date().addingTimeInterval(-Double((i * 37) % 26) * 86_400 - Double(i * 611 % 40_000)),
                                 text: t, lang: t.first!.isASCII ? "en" : "ru", app: apps[(i * 7) % apps.count], seconds: Double(t.count) / 14))
    }
    let w = StatsWindow()
    w.source = { fake }
    w.snapshot(to: URL(fileURLWithPath: out))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
