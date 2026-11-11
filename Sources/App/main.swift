import Cocoa

// Hidden CLI modes (for testing the exact same code paths without UI):
//   JustTellMe --transcribe file.wav [--lang auto|ru|en] [--model path.bin] [--no-prompt]
//              [--prompt "..."] [--no-fast] [--repeat N] [--verbose] [--encoder x-encoder.mlmodelc]
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
    let encoder = opt("--encoder").map { URL(fileURLWithPath: $0) }   // Core ML *-encoder.mlmodelc (Neural Engine)
    guard t.loadSync(modelURL, encoder: encoder, verbose: verbose) else { log("ERROR: failed to load model \(modelURL.path)"); exit(2) }
    log(String(format: "model load: %.2fs (threads=%d, model=%@, fast=%d, neural engine=%d)", Date().timeIntervalSince(t0), t.threads, modelURL.lastPathComponent, fast ? 1 : 0, t.usesNeuralEngine ? 1 : 0))
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

//   JustTellMe --stream file.wav [--lang auto]   (plays the file in real time through the streaming path, prints latency after "release")
if let file = opt("--stream") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let m = ModelManager.active(), let audio = try? AudioUtil.loadFile(URL(fileURLWithPath: file)) else { log("ERROR: model or audio"); exit(2) }
    let t = Transcriber()
    guard t.loadSync(m.url, encoder: opt("--encoder").map { URL(fileURLWithPath: $0) }) else { exit(2) }
    let rec = Recorder()
    let sess = StreamingDictation(recorder: rec, transcriber: t, language: opt("--lang") ?? "auto", prompt: Vocabulary.shared.prompt())
    var pos = 0
    let step = 16_000 / 10
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
        let n = min(step, audio.count - pos)
        if n > 0 { rec.debugAppend(Array(audio[pos..<(pos + n)]), rate: 16_000); pos += n }
        if Int(pos) % 8000 == 0 { sess.poll() }
        if pos >= audio.count {
            timer.invalidate()
            let released = Date()
            let early = sess.piecesSent
            sess.finish { r in
                log(String(format: "audio %.1fs, pieces sent while speaking: %d, ready %.2fs after release", Double(audio.count) / 16_000, early, Date().timeIntervalSince(released)))
                print(r.text)
                exit(0)
            }
        }
    }
    app.run()
}

//   JustTellMe --demo-paste "text"   (clipboard round-trip self-test without sending ⌘V)
if let text = opt("--demo-paste") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Paster.shared.insert(text, sendKeys: false)
    let types = NSPasteboard.general.pasteboardItems?.first?.types.map(\.rawValue) ?? []
    print("types: \(types.joined(separator: ", "))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    app.run()
}

//   JustTellMe --audio-info   (microphones, output mute state, secure input)
if args.contains("--audio-info") {
    let def = AudioDevices.defaultDevice(input: true)
    for d in AudioDevices.inputs() { print("mic: \(d.name)  [\(d.uid)]\(d.id == def ? "  (system default)" : "")") }
    if let out = AudioDevices.defaultDevice(input: false) {
        print("output: \(AudioDevices.name(of: out) ?? "?") muted=\(AudioDevices.muted(out).map { "\($0)" } ?? "n/a")")
    }
    print("secure input: \(SecureInput.isOn) \(SecureInput.holder() ?? "")")
    if args.contains("--test-mute"), let out = AudioDevices.defaultDevice(input: false) {
        SystemMute.begin(); print("after begin: muted=\(AudioDevices.muted(out).map { "\($0)" } ?? "n/a")")
        SystemMute.end(); print("after end: muted=\(AudioDevices.muted(out).map { "\($0)" } ?? "n/a")")
    }
    exit(0)
}

//   JustTellMe --demo-window out-prefix   (renders every page of the main window with the real history, for checking the layout)
if let out = opt("--demo-window") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let w = MainWindow()
    w.home.status = { AppStatus(hotkey: "Fn", micOK: true, accessOK: false, modelReady: true) }
    var pages = MainWindow.Page.allCases
    func next() {
        guard let p = pages.first else { exit(0) }
        pages.removeFirst()
        w.open(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            w.snapshot(to: URL(fileURLWithPath: "\(out)-\(p.rawValue).png"))
            next()
        }
    }
    DispatchQueue.main.async { next() }
    app.run()
}

//   JustTellMe --unload-cycle file.wav [--encoder x-encoder.mlmodelc]
//   (idle unload → reload as on a key press: how long the reload takes, whether the text is the same,
//    whether the Neural Engine encoder gets attached again in the background)
if let file = opt("--unload-cycle") {
    guard let m = ModelManager.active(), let audio = try? AudioUtil.loadFile(URL(fileURLWithPath: file)) else { log("ERROR: model or audio"); exit(2) }
    let enc = opt("--encoder").map { URL(fileURLWithPath: $0) }
    let t = Transcriber()
    guard t.loadSync(m.url, encoder: enc) else { exit(2) }
    let first = t.transcribeSync(audio, language: "auto", prompt: nil).text
    print("first: \(first)")
    print("neural engine before unload: \(t.usesNeuralEngine)")
    t.unload()
    print("in memory after unload: \(t.isInMemory)")
    let t0 = Date()
    t.prewarm()
    t.drain()
    print(String(format: "reload: %.2fs, neural engine right after reload: %@", Date().timeIntervalSince(t0), t.usesNeuralEngine ? "true" : "false"))
    let sem = DispatchSemaphore(value: 0)
    var second = ""
    t.transcribe(audio, setup: { ("auto", nil) }, onQueue: { second = $0.text; sem.signal() }, completion: { _ in })
    sem.wait()
    print("second: \(second)")
    print(String(format: "ready after key press: %.2fs", Date().timeIntervalSince(t0)))
    if enc != nil {
        print("neural engine during the first dictation: \(t.usesNeuralEngine)")
        t.attachEncoderIfNeeded()
        let deadline = Date().addingTimeInterval(60)
        while !t.usesNeuralEngine && Date() < deadline { Thread.sleep(forTimeInterval: 0.2); t.drain() }
        print(String(format: "neural engine attached: %@ after %.1fs", t.usesNeuralEngine ? "true" : "false", Date().timeIntervalSince(t0)))
        let t1 = Date()
        let third = t.transcribeSync(audio, language: "auto", prompt: nil)
        print(String(format: "third: %.2fs %@", Date().timeIntervalSince(t1), third.text))
    }
    exit(0)
}

//   JustTellMe --focus-check [seconds]   (after the delay: is a text field focused in the frontmost app?)
if args.contains("--focus-check") {
    Thread.sleep(forTimeInterval: Double(opt("--focus-check") ?? "0") ?? 0)
    let front = NSWorkspace.shared.frontmostApplication
    print("\(front?.bundleIdentifier ?? "?"): \(FocusedField.current(in: front)) (trusted: \(AXIsProcessTrusted()))")
    exit(0)
}

//   JustTellMe --demo-card out.png   (renders the «Курсор не в поле ввода?» card)
if let out = opt("--demo-card") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let c = NoFieldCard()
    c.show("Созвон перенесли на четверг, в 15:00. Захвати, пожалуйста, ноутбук и отчёт по продажам за октябрь.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.snapshot(to: URL(fileURLWithPath: out)); exit(0) }
    app.run()
}

//   JustTellMe --update-check [--page]   (latest GitHub release vs this build; --page: without the API)
//   JustTellMe --update-stage file.zip [--version X]   (unpack and verify a release zip like the updater does)
//   JustTellMe --update-install target.app   (full update of another copy of the app, without relaunching it)
if args.contains("--update-check") {
    let fetch = args.contains("--page") ? Updater.fetchLatestFromPage : Updater.fetchLatest
    fetch { r in
        switch r {
        case .success(let rel?):
            print("latest: \(rel.version) zip: \(rel.zip?.absoluteString ?? "none") size: \(rel.size)")
            print("this build: \(Updater.currentVersion), newer available: \(Updater.isNewer(rel.version, than: Updater.currentVersion))")
        case .success(nil): print("no releases")
        case .failure(let e): print("error: \(e.localizedDescription)"); exit(1)
        }
        exit(0)
    }
    RunLoop.main.run()
}
if let zip = opt("--update-stage") {
    do {
        let app = try Updater.stage(zip: URL(fileURLWithPath: zip), expectVersion: opt("--version"))
        print("ok: \(app.path)")
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
        exit(0)
    }
    catch { print("rejected: \(error.localizedDescription)"); exit(1) }
}
if let target = opt("--update-install") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let u = Updater()
    Updater.fetchLatest { r in
        guard case .success(let rel?) = r else { print("error: no release"); exit(1) }
        var last = -1
        u.onChange = { if case .downloading(_, let p) = u.state, Int(p * 10) != last { last = Int(p * 10); log("download \(last * 10)%") } }
        u.install(rel, target: URL(fileURLWithPath: target), relaunch: false) { err in
            print(err.map { "error: \($0.localizedDescription)" } ?? "installed \(rel.version)")
            exit(err == nil ? 0 : 1)
        }
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
