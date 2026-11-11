import Cocoa

/// New versions are GitHub Releases of github.com/Malashkin/JustTellMe with JustTellMe.zip attached.
/// Once a day the app asks the GitHub API for the latest release (nothing else is sent). Installing
/// downloads the zip, checks it is the same app signed with the same certificate, swaps the bundle
/// and relaunches. A download by the app itself carries no quarantine flag, so Gatekeeper does not
/// ask again, and an unchanged signature keeps the Microphone and Accessibility grants.
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let repo = "Malashkin/JustTellMe"
    static let assetName = "JustTellMe.zip"

    struct Release: Equatable {
        var version: String
        var page: URL
        var zip: URL?
        var size: Int
        var notes: String
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Release, Double), installing, failed(String)
    }

    var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// Asked right before quitting to install; return false to postpone (e.g. while dictating).
    var canRestart: () -> Bool = { true }

    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _): return r
        default: return nil
        }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    // MARK: Pure helpers (tested)

    /// "v1.10.0" > "1.9" — numeric, component by component; missing components count as 0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let t = v.trimmingCharacters(in: .whitespaces)
            let core = (t.hasPrefix("v") || t.hasPrefix("V")) ? String(t.dropFirst()) : t
            return core.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// GitHub "latest release" JSON → Release (nil for drafts, pre-releases or garbage).
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, !tag.isEmpty,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              j["draft"] as? Bool != true, j["prerelease"] as? Bool != true else { return nil }
        let assets = j["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { $0["name"] as? String == assetName }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: v, page: page,
                       zip: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                       size: zip?["size"] as? Int ?? 0, notes: j["body"] as? String ?? "")
    }

    /// "https://github.com/o/r/releases/tag/v1.2.0" → "1.2.0"; nil when there is no tag (no releases yet).
    static func version(fromReleasePage url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: "tag"), i + 1 < parts.count else { return nil }
        let tag = parts[i + 1]
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return v.first?.isNumber == true ? v : nil
    }

    // MARK: Checking

    private var timer: Timer?
    private static let lastCheckKey = "lastUpdateCheck"

    /// Check now if due, then every hour see whether a day has passed.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 600
    }

    private func checkIfDue() {
        guard Prefs.checkUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 24 * 3600 { check() }
    }

    func check(completion: ((State) -> Void)? = nil) {
        switch state { case .downloading, .installing, .checking: completion?(state); return; default: break }
        state = .checking
        Self.fetchLatest { [weak self] result in
            guard let self else { return }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            switch result {
            case .success(let r?) where Self.isNewer(r.version, than: Self.currentVersion): self.state = .available(r)
            case .success: self.state = .upToDate
            case .failure(let e): self.state = .failed(e.localizedDescription)
            }
            completion?(self.state)
        }
    }

    static func fetchLatest(_ done: @escaping (Result<Release?, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("JustTellMe/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r: Result<Release?, Error>
            if let err { r = .failure(err) }
            else if code == 404 { r = .success(nil) } // no releases yet
            else if code == 200, let data { r = .success(parse(data)) }
            else if code == 403 || code == 429 {
                // The API allows 60 requests an hour per IP address, shared by everyone behind it (an office NAT).
                return fetchLatestFromPage(done)
            }
            else { r = .failure(UpdateError("GitHub ответил \(code)")) }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    /// Without the API: the web page /releases/latest redirects to /releases/tag/vX.Y.Z, and the zip
    /// has a fixed URL per tag. No notes or size this way.
    static func fetchLatestFromPage(_ done: @escaping (Result<Release?, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue("JustTellMe/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let r: Result<Release?, Error>
            if let err { r = .failure(err) }
            else if let page = resp?.url, (resp as? HTTPURLResponse)?.statusCode == 200 {
                r = .success(version(fromReleasePage: page).map {
                    Release(version: $0, page: page,
                            zip: URL(string: "https://github.com/\(repo)/releases/download/v\($0)/\(assetName)"), size: 0, notes: "")
                })
            } else { r = .failure(UpdateError("GitHub недоступен")) }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    // MARK: Installing

    private var session: URLSession?
    private var installTarget = Bundle.main.bundleURL
    private var relaunch = true
    private var installDone: ((Error?) -> Void)?

    /// Download, verify, swap the app at `target` and (unless `relaunch` is false) quit and reopen it.
    func install(_ r: Release, target: URL = Bundle.main.bundleURL, relaunch: Bool = true, done: ((Error?) -> Void)? = nil) {
        guard let zip = r.zip else { NSWorkspace.shared.open(r.page); return }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            // E.g. installed by another user: let them download it by hand.
            NSWorkspace.shared.open(r.page)
            return
        }
        installTarget = target
        self.relaunch = relaunch
        installDone = done
        state = .downloading(r, 0)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        s.downloadTask(with: zip).resume()
    }

    func cancelDownload() {
        session?.invalidateAndCancel()
        session = nil
        if let r = available { state = .available(r) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard case .downloading(let r, _) = state else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(max(r.size, 1))
        state = .downloading(r, min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard case .downloading(let r, _) = state else { return }
        // The file is deleted when this method returns: move it out first.
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("JustTellMe-\(r.version)-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: location, to: zip) } catch { finish(error); return }
        state = .installing
        let target = installTarget
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let app = try Self.stage(zip: zip, expectVersion: r.version)
                try? FileManager.default.removeItem(at: zip)
                DispatchQueue.main.async { self.swap(to: app, target: target) }
            } catch {
                try? FileManager.default.removeItem(at: zip)
                DispatchQueue.main.async { self.finish(error) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { finish(error) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ error: Error?) {
        if let error { state = .failed(error.localizedDescription) }
        installDone?(error)
        installDone = nil
    }

    /// Unpack the zip next to nothing else and check it is our app, the expected version, intact,
    /// and signed by the same certificate as the running app. Returns the unpacked .app.
    static func stage(zip: URL, expectVersion: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("JustTellMe-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { return try verify(unpacking: zip, into: dir, expectVersion: expectVersion) } catch {
            try? FileManager.default.removeItem(at: dir) // a refused app must not stay around (it is ~550 MB)
            throw error
        }
    }

    private static func verify(unpacking zip: URL, into dir: URL, expectVersion: String?) throws -> URL {
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).status == 0 else { throw UpdateError("архив повреждён") }
        let app = dir.appendingPathComponent("JustTellMe.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("в архиве нет JustTellMe.app")
        }
        let myID = Bundle.main.bundleIdentifier ?? "com.justtellme.app"
        guard info["CFBundleIdentifier"] as? String == myID else { throw UpdateError("в архиве другое приложение") }
        if let v = expectVersion, info["CFBundleShortVersionString"] as? String != v {
            throw UpdateError("в архиве версия \(info["CFBundleShortVersionString"] as? String ?? "?") вместо \(v)")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw UpdateError("подпись приложения нарушена")
        }
        // Same certificate as the running app. An ad-hoc signed (developer) build has no certificate to compare.
        if let req = designatedRequirement(of: Bundle.main.bundleURL), !req.contains("cdhash") {
            guard run("/usr/bin/codesign", ["--verify", "-R", "=" + req, app.path]).status == 0 else {
                throw UpdateError("приложение подписано другим сертификатом")
            }
        }
        return app
    }

    static func designatedRequirement(of app: URL) -> String? {
        let out = run("/usr/bin/codesign", ["-d", "-r-", app.path]).output
        return out.split(separator: "\n").first { $0.hasPrefix("designated => ") }
            .map { String($0.dropFirst("designated => ".count)) }
    }

    /// Replace `target` with `app`. The running app cannot replace itself while running, so a small
    /// shell script waits for it to quit, swaps (rolling back on failure) and opens the new version.
    private func swap(to app: URL, target: URL) {
        let replacingSelf = target.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        if replacingSelf && !canRestart() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.swap(to: app, target: target) }
            return
        }
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3.old"
            if mv "$3" "$3.old" && /usr/bin/ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
            rm -rf "$(dirname "$2")"
            [ "$4" = 1 ] && /usr/bin/open "$3"
            exit 0
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for ourselves only when replacing the running app.
        let waitPID = replacingSelf ? ProcessInfo.processInfo.processIdentifier : 0
        p.arguments = ["-c", script, "sh", "\(waitPID)", app.path, target.path, relaunch ? "1" : "0"]
        do { try p.run() } catch { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()); finish(error); return }
        if replacingSelf {
            NSLog("JustTellMe: installing update, restarting")
            finish(nil)
            NSApp.terminate(nil)
        } else {
            p.waitUntilExit()
            state = .idle
            finish(p.terminationStatus == 0 ? nil : UpdateError("не удалось заменить приложение"))
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
