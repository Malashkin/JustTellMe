import AVFoundation

enum AudioUtil {
    static let targetRate: Double = 16_000

    /// Resample mono float samples to 16 kHz mono using AVAudioConverter.
    static func resampleTo16k(_ samples: [Float], rate: Double) -> [Float] {
        if samples.isEmpty { return [] }
        if abs(rate - targetRate) < 1 { return samples }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
            let conv = AVAudioConverter(from: inFmt, to: outFmt),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCap = AVAudioFrameCount(Double(samples.count) * targetRate / rate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return [] }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { NSLog("JustTellMe: resample error \(String(describing: err))"); return [] }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
    }

    /// Read any audio file (wav/aiff/m4a...) as 16 kHz mono float.
    static func loadFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let ch = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch {
            let p = buf.floatChannelData![c]
            for i in 0..<n { mono[i] += p[i] / Float(ch) }
        }
        return resampleTo16k(mono, rate: fmt.sampleRate)
    }

    static func rms(_ s: [Float]) -> Float {
        if s.isEmpty { return 0 }
        var acc: Float = 0
        for v in s { acc += v * v }
        return (acc / Float(s.count)).squareRoot()
    }
}

/// Microphone recorder. The engine runs only while recording (so the orange mic
/// indicator is visible only during dictation).
final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var rate: Double = 48_000
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        rate = fmt.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let chunk = UnsafeBufferPointer(start: data[0], count: n)
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns 16 kHz mono audio.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let raw = samples; samples.removeAll(); lock.unlock()
        return AudioUtil.resampleTo16k(raw, rate: rate)
    }
}
