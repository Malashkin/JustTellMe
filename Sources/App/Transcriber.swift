import Foundation

/// Keeps the whisper model loaded in memory; all inference runs on one serial queue.
final class Transcriber {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "justtellme.whisper", qos: .userInitiated)
    /// The chosen model. Stays set while the model is temporarily unloaded after idle.
    private(set) var loadedURL: URL?
    var isLoaded: Bool { ctx != nil }
    /// Free the model after this much inactivity (nil = keep it in memory).
    var idleUnload: TimeInterval?
    private var lastUse = Date()
    private var idleWork: DispatchWorkItem?
    let threads: Int

    init() {
        // Use the performance cores (M1: 4).
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0) != 0 || perf <= 0 { perf = 4 }
        threads = Int(max(2, min(perf, 8)))
    }

    /// Core ML encoder (Neural Engine) to use with the model; nil = GPU only.
    private(set) var encoderURL: URL?
    private var loadedEncoder: URL?
    /// True when the loaded model actually runs its encoder on the Neural Engine.
    private(set) var usesNeuralEngine = false

    /// Synchronous (re)load (call off the main thread unless in CLI mode).
    func loadSync(_ url: URL, encoder: URL? = nil, verbose: Bool = false) -> Bool {
        if loadedURL == url, loadedEncoder == encoder, ctx != nil { return true }
        if let c = ctx { vf_free(c); ctx = nil }
        let vad = Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "vad")?.path
        setenv("JTM_COREML_ENCODER", encoder?.path ?? "", 1)
        ctx = vf_load(url.path, vad, verbose)
        loadedURL = ctx != nil ? url : nil
        loadedEncoder = encoder
        encoderURL = encoder
        usesNeuralEngine = ctx.map { vf_uses_coreml($0) != 0 } ?? false
        lastUse = Date()
        return ctx != nil
    }

    func load(_ url: URL, encoder: URL? = nil, completion: @escaping (Bool) -> Void) {
        queue.async { let ok = self.loadSync(url, encoder: encoder); DispatchQueue.main.async { completion(ok) } }
    }

    /// Start loading a temporarily unloaded model now (e.g. when recording starts), so it is ready by the time speech ends.
    func prewarm() {
        idleWork?.cancel()
        queue.async {
            guard self.ctx == nil, let u = self.loadedURL else { return }
            let t0 = Date()
            _ = self.loadSync(u, encoder: self.encoderURL)
            NSLog("JustTellMe: model reloaded in %.2fs", Date().timeIntervalSince(t0))
        }
    }

    /// (Re)arm the idle timer; call on the main queue after each use.
    func scheduleIdleUnload() {
        idleWork?.cancel()
        guard let after = idleUnload, after > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, let c = self.ctx, Date().timeIntervalSince(self.lastUse) >= after - 1 else { return }
                vf_free(c)
                self.ctx = nil
                NSLog("JustTellMe: model unloaded after idle")
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    struct Result { var text: String; var raw: String; var lang: String; var seconds: Double }

    /// Synchronous transcription: whisper (with dictionary prompt) -> cleanup -> replacement rules.
    func transcribeSync(_ samples: [Float], language: String, prompt: String?, fast: Bool = true,
                        vocabulary: Vocabulary? = Vocabulary.shared) -> Result {
        let t0 = Date()
        guard let ctx, !samples.isEmpty else { return Result(text: "", raw: "", lang: "", seconds: 0) }
        // "auto": decode as Russian without a separate language-detection pass (that pass costs a
        // whole extra encoder run). Forced-"ru" Whisper still writes English speech and English
        // terms in Latin script; the language label is then taken from the script of the result.
        let whisperLang = language == "auto" ? "ru" : language
        var out = [CChar](repeating: 0, count: 64 * 1024)
        var lang = [CChar](repeating: 0, count: 8)
        let rc = samples.withUnsafeBufferPointer { buf in
            vf_transcribe(ctx, buf.baseAddress, Int32(buf.count), whisperLang, prompt, Int32(threads), fast,
                          &out, Int32(out.count), &lang)
        }
        if rc != 0 { NSLog("JustTellMe: transcribe failed rc=\(rc)") }
        var raw = Transcriber.clean(String(cString: out))
        // Prompt echo on near-silence: the model just repeats the priming text.
        if let p = prompt?.lowercased(), raw.count >= 12,
           p.contains(raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))) { raw = "" }
        let used = language == "auto" ? Transcriber.scriptLanguage(raw) : String(cString: lang)
        let text = vocabulary?.apply(raw, lang: used) ?? raw
        return Result(text: text, raw: raw, lang: used, seconds: Date().timeIntervalSince(t0))
    }

    func transcribe(_ samples: [Float], language: String, prompt: String?, completion: @escaping (Result) -> Void) {
        transcribe(samples, setup: { (language, prompt) }, completion: completion)
    }

    /// `setup` and `onQueue` run on the inference queue right before / after this job, i.e. after all
    /// earlier jobs finished — so a job can depend on the result of the previous one.
    func transcribe(_ samples: [Float], setup: @escaping () -> (language: String, prompt: String?),
                    onQueue: ((Result) -> Void)? = nil, completion: @escaping (Result) -> Void) {
        queue.async {
            if self.ctx == nil, let u = self.loadedURL { _ = self.loadSync(u, encoder: self.encoderURL) }
            let (language, prompt) = setup()
            let r = self.transcribeSync(samples, language: language, prompt: prompt)
            self.lastUse = Date()
            onQueue?(r)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// "en" if the text is mostly Latin letters, otherwise "ru".
    static func scriptLanguage(_ t: String) -> String {
        var latin = 0, cyr = 0
        for u in t.unicodeScalars {
            if ("a"..."z").contains(u) || ("A"..."Z").contains(u) { latin += 1 }
            else if (0x0400...0x04FF).contains(u.value) { cyr += 1 }
        }
        return latin > cyr ? "en" : "ru"
    }

    /// Trim and drop the classic whisper hallucinations on silence/noise.
    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        let lower = t.lowercased()
        let junk = [
            "продолжение следует", "субтитры сделал", "субтитры создавал", "редактор субтитров",
            "спасибо за просмотр", "подписывайтесь на канал", "dimatorzok", "thank you for watching",
            "thanks for watching", "[музыка]", "[music]", "[blank_audio]", "(музыка)",
        ]
        if junk.contains(where: { lower.contains($0) }) && t.count < 60 { return "" }
        if t.hasPrefix("[") && t.hasSuffix("]") { return "" }
        if t.hasPrefix("(") && t.hasSuffix(")") { return "" }
        if !t.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return "" } // "...", "-"
        return collapseRepeats(t)
    }

    /// Whisper sometimes loops and repeats the same sentence: "A. A. A." -> "A."
    static func collapseRepeats(_ t: String) -> String {
        var sentences: [String] = []
        t.enumerateSubstrings(in: t.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(s.trimmingCharacters(in: .whitespaces)) }
        }
        guard sentences.count > 1 else { return t }
        var out: [String] = []
        for s in sentences where !s.isEmpty {
            if let last = out.last, last.lowercased() == s.lowercased() { continue }
            out.append(s)
        }
        return out.count == sentences.count ? t : out.joined(separator: " ")
    }
}
