import CoreML
import Foundation

/// Optional Neural Engine acceleration. Whisper's encoder (the heavy part) runs through a Core ML
/// model on the Apple Neural Engine instead of the GPU: ~5× faster on M1 and unaffected by other
/// apps keeping the GPU busy. The encoder (~1.2 GB) is downloaded from the whisper.cpp model repo;
/// macOS then compiles it for the Neural Engine once (can take 20–30 min on M1, cached afterwards).
/// Until it is ready, dictation keeps working on the GPU.
final class NeuralEngine: NSObject, URLSessionDownloadDelegate {
    enum Status: Equatable {
        case off
        case downloading(Double)
        case unpacking
        case preparing
        case ready
        case failed(String)
    }

    private(set) var status: Status = .off { didSet { if status != oldValue { onChange?() } } }
    /// Called on the main queue whenever `status` changes.
    var onChange: (() -> Void)?

    private var model: URL?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// "ggml-large-v3-turbo-q5_0.bin" -> "ggml-large-v3-turbo-encoder.mlmodelc" (same rule as whisper.cpp).
    static func encoderName(for model: URL) -> String {
        var base = model.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #"-q\d_\d$"#, options: .regularExpression) { base.removeSubrange(r) }
        return base + "-encoder.mlmodelc"
    }

    static func encoderURL(for model: URL) -> URL { Paths.models.appendingPathComponent(encoderName(for: model)) }

    /// Encoder to hand to whisper, once it is downloaded and compiled for this model.
    func encoder(for model: URL) -> URL? {
        status == .ready && self.model == model ? Self.encoderURL(for: model) : nil
    }

    /// Bring acceleration up for `model` (download/prepare as needed), or turn it off when disabled.
    func update(for model: URL) {
        guard Prefs.neuralEngine else { cancelDownload(); self.model = nil; status = .off; return }
        if self.model == model, status != .off, !isFailed { return }
        self.model = model
        let enc = Self.encoderURL(for: model)
        if FileManager.default.fileExists(atPath: enc.appendingPathComponent("coremldata.bin").path) {
            prepare(enc)
        } else {
            download(for: model)
        }
    }

    func retry(for model: URL) { self.model = nil; status = .off; update(for: model) }

    func cancelDownload() { task?.cancel(); task = nil }

    private var isFailed: Bool { if case .failed = status { return true }; return false }

    // MARK: Prepare (macOS compiles the model for the Neural Engine on first load; cached afterwards)

    private func prepare(_ enc: URL) {
        status = .preparing
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all   // same as whisper.cpp's Core ML loader, so the cached compilation is reused
            let result: Result<Void, Error> = Result { _ = try MLModel(contentsOf: enc, configuration: cfg) }
            DispatchQueue.main.async {
                guard self.model.map(Self.encoderURL(for:)) == enc else { return } // model switched meanwhile
                switch result {
                case .success:
                    NSLog("JustTellMe: Neural Engine encoder ready in %.0fs", Date().timeIntervalSince(started))
                    self.status = .ready
                case .failure(let e):
                    NSLog("JustTellMe: Neural Engine encoder failed: \(e)")
                    self.status = .failed(e.localizedDescription)
                }
            }
        }
    }

    // MARK: Download

    private func download(for model: URL) {
        let name = Self.encoderName(for: model)
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name).zip") else { return }
        cancelDownload()
        status = .downloading(0)
        task = session.downloadTask(with: url)
        task?.taskDescription = name
        task?.resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard t > 0 else { return }
        let p = (Double(w) / Double(t) * 100).rounded() / 100   // 1 % steps: fewer menu rebuilds
        if status != .downloading(p) { status = .downloading(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            status = .failed(http.statusCode == 404 ? "для этой модели нет версии под Neural Engine" : "HTTP \(http.statusCode)")
            return
        }
        // The temp file disappears when this method returns: move it first, unpack in the background.
        let zip = Paths.models.appendingPathComponent(".encoder-download.zip")
        try? FileManager.default.removeItem(at: zip)
        do { try FileManager.default.moveItem(at: location, to: zip) } catch { status = .failed(error.localizedDescription); return }
        status = .unpacking
        let name = downloadTask.taskDescription ?? ""
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", zip.path, "-x", "__MACOSX/*", "-d", Paths.models.path]
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            try? FileManager.default.removeItem(at: zip)
            DispatchQueue.main.async {
                let enc = Paths.models.appendingPathComponent(name)
                guard ok, FileManager.default.fileExists(atPath: enc.path) else { self.status = .failed("не удалось распаковать"); return }
                guard self.model.map(Self.encoderURL(for:)) == enc else { return }
                self.prepare(enc)
            }
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { if case .downloading = status { status = .off }; return }
        status = .failed(error.localizedDescription)
    }
}
