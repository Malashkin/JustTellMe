import Foundation

/// Transcribes a long dictation in pieces while the user is still talking: once enough speech has
/// piled up and there is a pause, that piece goes to Whisper right away. When the key is released
/// only the last piece is left, so a 30-second dictation appears about as fast as a short one.
final class StreamingDictation {
    static let minChunk = 8.0    // seconds of audio before looking for a pause to cut at
    static let minCutAt = 5.0    // never make a piece shorter than this
    static let maxChunk = 25.0   // cut even without a clear pause (Whisper's window is 30 s)
    static let pause = 0.3       // quiet stretch that counts as a pause

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let language: String
    private let basePrompt: String?
    private var cut = 0                          // raw sample index up to which audio has been sent
    private var issued = 0
    private var results: [Int: Transcriber.Result] = [:]
    private var prevText = ""                    // last non-empty piece; touched only on the inference queue
    private var onDone: (() -> Void)?
    private var cancelled = false

    /// Pieces already sent before the key was released (for logs).
    var piecesSent: Int { issued }

    init(recorder: Recorder, transcriber: Transcriber, language: String, prompt: String?) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.language = language
        self.basePrompt = prompt
    }

    /// Call periodically on the main queue while recording.
    func poll() {
        guard !cancelled else { return }
        let rate = recorder.sampleRate
        let end = recorder.rawCount
        let pending = Double(end - cut) / rate
        guard pending >= Self.minChunk else { return }
        let audio = recorder.raw(cut..<end)
        guard let at = Self.findCut(audio, rate: rate, force: pending >= Self.maxChunk) else { return }
        send(Array(audio[0..<at]))
        cut += at
    }

    /// Call after the recorder stopped. `completion` gets the joined result of all pieces, on the main queue.
    func finish(completion: @escaping (Transcriber.Result) -> Void) {
        let tail = recorder.raw(cut..<recorder.rawCount)
        // A trailing bit of silence after the last piece: nothing to decode (Whisper would only hallucinate).
        if issued == 0 || AudioUtil.rms(tail) >= 0.0015 { send(tail) }
        let total = issued
        onDone = { [weak self] in
            guard let self else { return }
            completion(self.combined(total))
        }
        checkDone()
    }

    func cancel() { cancelled = true; onDone = nil }

    // MARK: -

    private func send(_ raw: [Float]) {
        let idx = issued
        issued += 1
        let pcm = AudioUtil.resampleTo16k(raw, rate: recorder.sampleRate)
        let language = self.language, basePrompt = self.basePrompt
        let setup = { [weak self] () -> (language: String, prompt: String?) in
            let prev = self?.prevText ?? ""
            // The end of the previous piece primes Whisper for continuity (names, casing, style).
            let prompt = [basePrompt, prev.isEmpty ? nil : String(prev.suffix(150))].compactMap { $0 }.joined(separator: " ")
            // In auto mode Whisper decodes as Russian; if the previous piece came out English, keep
            // English (forced Russian would translate a short English tail).
            let lang = language == "auto" && Transcriber.scriptLanguage(prev) == "en" && !prev.isEmpty ? "en" : language
            return (lang, prompt.isEmpty ? nil : prompt)
        }
        transcriber.transcribe(pcm, setup: setup, onQueue: { [weak self] r in
            if !r.text.isEmpty { self?.prevText = r.text }
        }) { [weak self] r in
            guard let self, !self.cancelled else { return }
            self.results[idx] = r
            self.checkDone()
        }
    }

    private func checkDone() {
        guard let done = onDone, results.count == issued else { return }
        onDone = nil
        done()
    }

    private func combined(_ n: Int) -> Transcriber.Result {
        let parts = (0..<n).compactMap { results[$0] }
        let join = { (xs: [String]) in xs.filter { !$0.isEmpty }.joined(separator: " ") }
        let text = join(parts.map(\.text))
        return Transcriber.Result(text: text, raw: join(parts.map(\.raw)),
                                  lang: language == "auto" ? Transcriber.scriptLanguage(text) : language,
                                  seconds: parts.map(\.seconds).reduce(0, +))
    }

    /// Where to cut `audio` (device-rate samples): middle of the latest pause after `minCutAt`,
    /// or, when `force`, the quietest moment. nil = keep accumulating.
    static func findCut(_ audio: [Float], rate: Double, force: Bool) -> Int? {
        let frame = Int(rate * 0.03)
        guard frame > 0 else { return nil }
        let n = audio.count / frame
        guard n > 0 else { return nil }
        var rms = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for j in (i * frame)..<((i + 1) * frame) { acc += audio[j] * audio[j] }
            rms[i] = (acc / Float(frame)).squareRoot()
        }
        let sorted = rms.sorted()
        let floor = sorted[n * 15 / 100], peak = sorted[min(n - 1, n * 90 / 100)]
        let threshold = max(floor * 1.5, floor + 0.2 * (peak - floor))
        let first = Int(minCutAt / 0.03)
        let need = Int(pause / 0.03)

        var best: Int?
        var run = 0
        for i in 0..<n {
            if rms[i] <= threshold { run += 1 } else { run = 0 }
            if run >= need, i - run / 2 >= first { best = i - run / 2 }   // keep the latest pause
        }
        if let b = best { return b * frame }
        guard force, n > first + need else { return nil }
        var quietest = first, minSum = Float.greatestFiniteMagnitude
        for i in first...(n - need) {
            let s = rms[i..<(i + need)].reduce(0, +)
            if s < minSum { minSum = s; quietest = i + need / 2 }
        }
        return quietest * frame
    }
}
