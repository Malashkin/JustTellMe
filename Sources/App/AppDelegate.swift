import AVFoundation
import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case loading, idle, recording, transcribing, error(String) }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Разрешить Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
    private let micItem = NSMenuItem(title: "Разрешить микрофон…", action: #selector(openMicSettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
    private let modelRoot = NSMenuItem(title: "Модель", action: nil, keyEquivalent: "")
    private let fixItem = NSMenuItem(title: "Исправить последнюю фразу…", action: #selector(fixLast), keyEquivalent: "")
    private let builtinItem = NSMenuItem(title: "Встроенный словарь ru/en", action: #selector(toggleBuiltin), keyEquivalent: "")
    private var langItems: [String: NSMenuItem] = [:]

    private let transcriber = Transcriber()
    private let recorder = Recorder()
    private let hotkey = PushToTalkHotkey(key: PushToTalkHotkey.Key(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .fn)
    private let welcome = WelcomeWindow()
    private var keyItems: [PushToTalkHotkey.Key: NSMenuItem] = [:]
    private let models = ModelManager()
    private let vocabWindow = VocabularyWindow()
    private let fixWindow = CorrectionWindow()
    private var state: State = .loading
    private var recordStart = Date()
    private var permTimer: Timer?
    private var lastResult = ""
    private var downloadProgress: Double?

    private let minHold: TimeInterval = 0.3
    private var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        _ = Vocabulary.shared // create default files

        loadActiveModel()

        hotkey.onDown = { [weak self] in self?.pttDown() }
        hotkey.onUp = { [weak self] in self?.pttUp() }
        hotkey.onCombo = { [weak self] in self?.cancelRecording() }

        models.onProgress = { [weak self] _, p in self?.downloadProgress = p; self?.rebuildModelMenu() }
        models.onFinished = { [weak self] file, err in self?.downloadFinished(file, err) }
        fixWindow.onCorrected = { [weak self] text in
            self?.lastResult = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        welcome.onOpenAccessibility = { [weak self] in self?.openAccessibility() }
        welcome.onOpenMic = { [weak self] in self?.openMicSettings() }

        requestPermissions()
        if !UserDefaults.standard.bool(forKey: "welcomeShown") || !allGood {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            showWelcome()
        }
    }

    /// Double-click on the app while it is already running → show the status window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWelcome()
        return false
    }

    private var allGood: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
    }

    private var conflictingApp: String? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").lowercased().contains("wispr") || ($0.localizedName ?? "").lowercased().contains("wispr")
        }?.localizedName
    }

    /// System setting "Press 🌐 key to": 0 nothing, 1 change input source, 2 emoji, 3 dictation.
    private var fnHasSystemAction: Bool {
        let v = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return (v ?? 2) != 0
    }

    @objc private func showWelcome() {
        welcome.open { [weak self] in
            guard let self else { return .init(hotkey: "", micOK: false, accessOK: false, modelReady: false, conflictingApp: nil, fnSwitchesInput: false) }
            var ready = false
            if case .idle = self.state { ready = true }
            if case .recording = self.state { ready = true }
            if case .transcribing = self.state { ready = true }
            return .init(hotkey: self.hotkey.key.short,
                         micOK: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         accessOK: AXIsProcessTrusted() && self.hotkey.isInstalled,
                         modelReady: ready,
                         conflictingApp: self.conflictingApp,
                         fnSwitchesInput: self.hotkey.key == .fn && self.fnHasSystemAction)
        }
    }

    private func loadActiveModel() {
        guard let m = ModelManager.active() else { setState(.error("нет модели")); return }
        setState(.loading)
        transcriber.load(m.url) { [weak self] ok in
            self?.setState(ok ? .idle : .error("модель не загрузилась"))
            self?.rebuildModelMenu()
        }
    }

    /// Accessory apps have no visible menu bar, but key equivalents (⌘C/⌘V/⌘A/⌘Z) in our
    /// windows still go through the main menu, so give it a standard Edit menu.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let e = NSMenu(title: "Edit")
        e.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        e.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        e.addItem(.separator())
        e.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = e
        NSApp.mainMenu = main
    }

    // MARK: - Permissions

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissionItems() } }
        }
        tryInstallHotkey()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tryInstallHotkey() }
    }

    private func tryInstallHotkey() {
        if !hotkey.isInstalled, AXIsProcessTrusted() { _ = hotkey.install() }
        if hotkey.isInstalled { permTimer?.invalidate(); permTimer = nil }
        refreshPermissionItems()
    }

    private func refreshPermissionItems() {
        accessItem.isHidden = hotkey.isInstalled && AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micItem.isHidden = (mic == .authorized || mic == .notDetermined)
        updateStatusLine()
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: - Push to talk

    private func pttDown() {
        guard case .idle = state else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        guard mic == .authorized else {
            if mic == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissionItems() } }
            } else { NSSound.beep(); refreshPermissionItems() }
            return
        }
        do {
            try recorder.start()
            recordStart = Date()
            setState(.recording)
            NSSound(named: "Tink")?.play()
        } catch {
            NSLog("JustTellMe: mic start failed: \(error)")
            setState(.error("микрофон недоступен"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.setState(.idle) }
        }
    }

    private func cancelRecording() {
        guard case .recording = state else { return }
        _ = recorder.stop()
        setState(.idle)
    }

    private func pttUp() {
        guard case .recording = state else { return }
        let held = Date().timeIntervalSince(recordStart)
        let audio = recorder.stop()
        if held < minHold { setState(.idle); return }
        NSSound(named: "Pop")?.play()
        if AudioUtil.rms(audio) < 0.0015 { setState(.idle); return } // silence
        setState(.transcribing)
        transcriber.transcribe(audio, language: language, prompt: Vocabulary.shared.prompt()) { [weak self] r in
            guard let self else { return }
            NSLog("JustTellMe: [\(r.lang)] %.1fs audio -> %.2fs: \(r.text)", Double(audio.count) / 16_000, r.seconds)
            self.setState(.idle)
            guard !r.text.isEmpty else { return }
            var out = r.text
            if let last = out.last, ".!?…".contains(last) { out += " " }
            self.lastResult = r.text
            self.updateStatusLine()
            Paster.insert(out)
        }
    }

    // MARK: - Status icon

    private func setState(_ s: State) {
        state = s
        let symbol: String, tint: NSColor?
        switch s {
        case .loading: symbol = "hourglass"; tint = nil
        case .idle: symbol = "mic"; tint = nil
        case .recording: symbol = "mic.fill"; tint = .systemRed
        case .transcribing: symbol = "waveform"; tint = .systemOrange
        case .error: symbol = "mic.slash"; tint = .systemYellow
        }
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "JustTellMe")
            img?.isTemplate = tint == nil
            b.image = img
            b.contentTintColor = tint
            b.toolTip = "JustTellMe"
        }
        updateStatusLine()
    }

    private func updateStatusLine() {
        var t: String
        switch state {
        case .loading: t = "Загрузка модели…"
        case .idle: t = "Готово — удерживайте \(hotkey.key.short)"
        case .recording: t = "● Запись…"
        case .transcribing: t = "Распознавание…"
        case .error(let e): t = "Ошибка: \(e)"
        }
        if !(hotkey.isInstalled && AXIsProcessTrusted()) { t += " (нет Accessibility)" }
        statusLine.title = "JustTellMe — " + t
        lastLine.isHidden = lastResult.isEmpty
        let short = lastResult.count > 50 ? String(lastResult.prefix(50)) + "…" : lastResult
        lastLine.title = "Последнее: «\(short)»"
        fixItem.isEnabled = !lastResult.isEmpty
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        lastLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(lastLine)
        for it in [accessItem, micItem] { it.target = self; menu.addItem(it) }
        let welcomeItem = NSMenuItem(title: "Состояние и подсказка…", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        menu.addItem(.separator())

        let keyRoot = NSMenuItem(title: "Клавиша диктовки", action: nil, keyEquivalent: "")
        let keySub = NSMenu()
        for k in PushToTalkHotkey.Key.allCases {
            let it = NSMenuItem(title: k.title, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = k.rawValue
            keySub.addItem(it)
            keyItems[k] = it
        }
        keyRoot.submenu = keySub
        menu.addItem(keyRoot)

        let langRoot = NSMenuItem(title: "Язык", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (code, title) in [("auto", "Авто (ru/en, с уклоном в ru)"), ("ru", "Русский"), ("en", "English")] {
            let it = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = code
            sub.addItem(it)
            langItems[code] = it
        }
        langRoot.submenu = sub
        menu.addItem(langRoot)

        modelRoot.submenu = NSMenu()
        menu.addItem(modelRoot)
        rebuildModelMenu()

        menu.addItem(.separator())
        let vocab = NSMenuItem(title: "Словарь и замены…", action: #selector(openVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)
        builtinItem.target = self
        menu.addItem(builtinItem)
        fixItem.target = self
        menu.addItem(fixItem)
        let copyLast = NSMenuItem(title: "Скопировать последний текст", action: #selector(copyLast), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast)

        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshPermissionItems()
    }

    private func rebuildModelMenu() {
        guard let m = modelRoot.submenu else { return }
        m.removeAllItems()
        m.autoenablesItems = false
        let active = ModelManager.active()
        let loadedPath = transcriber.loadedURL?.path
        for info in ModelManager.available() {
            let title = "\(info.name)  (\(info.sizeMB) МБ\(info.bundled ? ", встроенная" : ""))"
            let it = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = info.url.path
            it.state = info.url.path == (loadedPath ?? active?.url.path) ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        let add = NSMenuItem(title: "Добавить модель из файла…", action: #selector(addModelFromFile), keyEquivalent: "")
        add.target = self
        m.addItem(add)

        let dlRoot = NSMenuItem(title: "Скачать модель…", action: nil, keyEquivalent: "")
        let dl = NSMenu(); dl.autoenablesItems = false
        let have = Set(ModelManager.available().map { $0.url.lastPathComponent })
        for c in ModelManager.curated {
            let it = NSMenuItem(title: c.title + (have.contains(c.file) ? " ✓" : ""), action: #selector(downloadModel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.file
            it.isEnabled = models.downloading == nil && !have.contains(c.file)
            dl.addItem(it)
        }
        dl.addItem(.separator())
        let src = NSMenuItem(title: "Все модели на huggingface.co/ggerganov/whisper.cpp…", action: #selector(openHF), keyEquivalent: "")
        src.target = self
        dl.addItem(src)
        dlRoot.submenu = dl
        m.addItem(dlRoot)

        if let file = models.downloading {
            let pct = Int((downloadProgress ?? 0) * 100)
            let p = NSMenuItem(title: "⬇︎ \(file): \(pct)%", action: nil, keyEquivalent: "")
            p.isEnabled = false
            m.addItem(p)
            let cancel = NSMenuItem(title: "Отменить загрузку", action: #selector(cancelDownload), keyEquivalent: "")
            cancel.target = self
            m.addItem(cancel)
            modelRoot.title = "Модель (загрузка \(pct)%)"
        } else {
            modelRoot.title = "Модель: " + (transcriber.loadedURL.map { ModelInfo(url: $0, bundled: false).name } ?? "—")
        }
        m.addItem(.separator())
        let folder = NSMenuItem(title: "Открыть папку моделей", action: #selector(openModelsFolder), keyEquivalent: "")
        folder.target = self
        m.addItem(folder)
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (code, it) in langItems { it.state = code == language ? .on : .off }
        for (k, it) in keyItems { it.state = k == hotkey.key ? .on : .off }
        let st = SMAppService.mainApp.status
        loginItem.state = st == .enabled ? .on : .off
        loginItem.title = st == .requiresApproval ? "Запускать при входе (нужно одобрить)" : "Запускать при входе"
        builtinItem.state = Vocabulary.shared.builtinEnabled ? .on : .off
        builtinItem.title = "Встроенный словарь ru/en (\(Vocabulary.shared.builtinTerms.count) слов)"
        rebuildModelMenu()
        refreshPermissionItems()
    }

    @objc private func toggleBuiltin() { Vocabulary.shared.builtinEnabled.toggle() }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = PushToTalkHotkey.Key(rawValue: raw) else { return }
        hotkey.key = k
        UserDefaults.standard.set(raw, forKey: "hotkey")
        updateStatusLine()
        if k == .fn && fnHasSystemAction { showWelcome() }
    }

    // MARK: - Actions

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? String { language = c }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let info = ModelManager.available().first(where: { $0.url.path == path }) else { return }
        switch state { case .recording, .transcribing: NSSound.beep(); return; default: break }
        ModelManager.setActive(info)
        loadActiveModel()
    }

    @objc private func addModelFromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.title = "Выберите модель whisper.cpp (ggml-*.bin)"
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let info = try ModelManager.importModel(from: url)
            ModelManager.setActive(info)
            loadActiveModel()
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String,
              let c = ModelManager.curated.first(where: { $0.file == file }) else { return }
        models.download(c)
    }

    @objc private func cancelDownload() { models.cancel() }

    private func downloadFinished(_ file: String, _ err: Error?) {
        rebuildModelMenu()
        if let err {
            if (err as NSError).code == NSURLErrorCancelled { return }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Не удалось скачать \(file)"
            a.informativeText = err.localizedDescription
            a.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Модель \(file) скачана"
        a.informativeText = "Переключиться на неё сейчас?"
        a.addButton(withTitle: "Переключиться")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn,
           let info = ModelManager.available().first(where: { $0.url.lastPathComponent == file }) {
            ModelManager.setActive(info)
            loadActiveModel()
        }
    }

    @objc private func openHF() { NSWorkspace.shared.open(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!) }
    @objc private func openModelsFolder() { NSWorkspace.shared.open(Paths.models) }
    @objc private func openVocabulary() { vocabWindow.open() }

    @objc private func fixLast() {
        guard !lastResult.isEmpty else { return }
        fixWindow.open(original: lastResult)
    }

    @objc private func copyLast() {
        guard !lastResult.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResult, forType: .string)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("JustTellMe: login item error: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
