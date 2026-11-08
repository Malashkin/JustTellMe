import Foundation

struct ModelInfo: Equatable {
    let url: URL
    let bundled: Bool
    var name: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "") }
    var sizeMB: Int {
        let s = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return s / 1_000_000
    }
}

struct CuratedModel {
    let file: String
    let title: String
    let bytes: Int64
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
}

/// Lists, imports and downloads ggml whisper models.
final class ModelManager: NSObject, URLSessionDownloadDelegate {
    static let defaultFile = "ggml-large-v3-turbo-q5_0.bin"

    static let curated: [CuratedModel] = [
        .init(file: "ggml-small-q5_1.bin", title: "small q5_1 — 190 МБ, быстрая, слабее", bytes: 190_085_487),
        .init(file: "ggml-small.bin", title: "small — 488 МБ", bytes: 487_601_967),
        .init(file: "ggml-medium-q5_0.bin", title: "medium q5_0 — 539 МБ", bytes: 539_212_467),
        .init(file: "ggml-large-v3-turbo-q8_0.bin", title: "large-v3-turbo q8_0 — 874 МБ, точнее q5", bytes: 874_188_075),
        .init(file: "ggml-large-v3-q5_0.bin", title: "large-v3 q5_0 — 1.1 ГБ, точная, медленнее", bytes: 1_081_140_203),
        .init(file: "ggml-large-v3-turbo.bin", title: "large-v3-turbo f16 — 1.6 ГБ, максимум точности turbo", bytes: 1_624_555_275),
    ]

    /// Progress callback: (file, fraction 0...1) while downloading; (file, nil) when finished/failed.
    var onProgress: ((String, Double?) -> Void)?
    var onFinished: ((String, Error?) -> Void)?
    private(set) var downloading: String?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    // MARK: Listing

    static func available() -> [ModelInfo] {
        var out: [ModelInfo] = []
        if let res = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(at: res, includingPropertiesForKeys: nil) {
            out += items.filter { $0.pathExtension == "bin" }.map { ModelInfo(url: $0, bundled: true) }
        }
        if let items = try? FileManager.default.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil) {
            out += items.filter { $0.pathExtension == "bin" && isGGML($0) }.map { ModelInfo(url: $0, bundled: false) }
        }
        return out.sorted { ($0.bundled ? 0 : 1, $0.name) < ($1.bundled ? 0 : 1, $1.name) }
    }

    /// Active model: saved choice if it still exists, else the bundled default, else any.
    static func active() -> ModelInfo? {
        let all = available()
        if let saved = UserDefaults.standard.string(forKey: "modelPath"),
           let m = all.first(where: { $0.url.path == saved }) { return m }
        return all.first(where: { $0.url.lastPathComponent == defaultFile }) ?? all.first
    }

    static func setActive(_ m: ModelInfo) { UserDefaults.standard.set(m.url.path, forKey: "modelPath") }

    static func isGGML(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 4)
        return d == Data("lmgg".utf8) // 0x67676d6c little-endian
    }

    // MARK: Import

    enum ImportError: LocalizedError {
        case notGGML
        var errorDescription: String? { "Это не модель whisper.cpp (ggml .bin)." }
    }

    static func importModel(from src: URL) throws -> ModelInfo {
        guard isGGML(src) else { throw ImportError.notGGML }
        let dst = Paths.models.appendingPathComponent(src.lastPathComponent)
        if src.standardizedFileURL != dst.standardizedFileURL {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        return ModelInfo(url: dst, bundled: false)
    }

    // MARK: Download

    func download(_ m: CuratedModel) {
        guard downloading == nil else { return }
        downloading = m.file
        task = session.downloadTask(with: m.url)
        task?.taskDescription = m.file
        task?.resume()
        onProgress?(m.file, 0)
    }

    func cancel() { task?.cancel(); }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        let file = downloadTask.taskDescription ?? ""
        let total = t > 0 ? t : (Self.curated.first { $0.file == file }?.bytes ?? 1)
        onProgress?(file, min(1, Double(w) / Double(total)))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let file = downloadTask.taskDescription ?? "model.bin"
        let dst = Paths.models.appendingPathComponent(file)
        var err: Error?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            err = NSError(domain: "JustTellMe", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        } else if !Self.isGGML(location) {
            err = ImportError.notGGML
        } else {
            do {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: location, to: dst)
            } catch { err = error }
        }
        finish(file, err)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // success path handled above
        finish(task.taskDescription ?? "", error)
    }

    private func finish(_ file: String, _ err: Error?) {
        guard downloading != nil else { return }
        downloading = nil
        task = nil
        onProgress?(file, nil)
        onFinished?(file, err)
    }
}
