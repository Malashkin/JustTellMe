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
    private let secureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsRoot = NSMenuItem(title: "Настройки", action: nil, keyEquivalent: "")

    private let transcriber = Transcriber()
    private let recorder = Recorder()
    private let hotkey = PushToTalkHotkey(key: PushToTalkHotkey.Key(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .fn)
    private let welcome = WelcomeWindow()
    private let overlay = RecordingOverlay()
    private let historyWindow = HistoryWindow()
    private let statsWindow = StatsWindow()
    private let historyRoot = NSMenuItem(title: "История", action: nil, keyEquivalent: "")
    private var keyItems: [PushToTalkHotkey.Key: NSMenuItem] = [:]
    private let models = ModelManager()
    private let neural = NeuralEngine()
    private let vocabWindow = VocabularyWindow()
    private let fixWindow = CorrectionWindow()
    private var state: State = .loading
    private var recordStart = Date()
    private var permTimer: Timer?
    private var lastResult = ""
    private var downloadProgress: Double?

    private let minHold: TimeInterval = 0.3
    private let maxHandsFree: TimeInterval = 5 * 60
    private var handsFree = false
    private var ignoreNextUp = false
    private var job = 0
    private var session: StreamingDictation?
    private var pollTimer: Timer?
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

        recorder.onLevel = { [weak self] l in self?.overlay.push(level: l) }
        hotkey.onDown = { [weak self] in self?.pttDown() }
        hotkey.onUp = { [weak self] in self?.pttUp() }
        hotkey.onCombo = { [weak self] in self?.cancelRecording() }
        hotkey.onEscape = { [weak self] in self?.escapePressed() }
        applyUnloadPref()

        neural.onChange = { [weak self] in self?.neuralChanged() }
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
        // GPU first (ready in a second); the Neural Engine encoder is attached once macOS has prepared it.
        transcriber.load(m.url, encoder: neural.encoder(for: m.url)) { [weak self] ok in
            self?.setState(ok ? .idle : .error("модель не загрузилась"))
            self?.rebuildModelMenu()
        }
        neural.update(for: m.url)
    }

    /// Neural Engine status changed: attach/detach the Core ML encoder by reloading the model.
    private func neuralChanged() {
        rebuildSettingsMenu()
        guard let m = ModelManager.active() else { return }
        let enc = neural.encoder(for: m.url)
        guard enc != transcriber.encoderURL else { return }
        switch state { case .loading: return; default: break }
        transcriber.load(m.url, encoder: enc) { [weak self] ok in
            guard let self else { return }
            NSLog("JustTellMe: model reloaded, Neural Engine: \(self.transcriber.usesNeuralEngine)")
            if !ok { self.setState(.error("модель не загрузилась")) }
            self.rebuildModelMenu()
            self.rebuildSettingsMenu()
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
        // Hands-free recording in progress: this tap ends it (and its key-up is ignored).
        if case .recording = state, handsFree {
            ignoreNextUp = true
            finishRecording()
            return
        }
        guard case .idle = state else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        guard mic == .authorized else {
            if mic == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissionItems() } }
            } else { NSSound.beep(); refreshPermissionItems() }
            return
        }
        transcriber.prewarm()
        do {
            try recorder.start()
            recordStart = Date()
            handsFree = false
            let sess = StreamingDictation(recorder: recorder, transcriber: transcriber, language: language, prompt: Vocabulary.shared.prompt())
            session = sess
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in sess.poll() }
            setState(.recording)
            if Prefs.sounds { NSSound(named: "Tink")?.play() }
            if Prefs.muteWhileRecording {
                // Let the start sound play out before muting.
                DispatchQueue.main.asyncAfter(deadline: .now() + (Prefs.sounds ? 0.2 : 0)) {
                    if case .recording = self.state { SystemMute.begin() }
                }
            }
        } catch {
            NSLog("JustTellMe: mic start failed: \(error)")
            setState(.error("микрофон недоступен"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.setState(.idle) }
        }
    }

    private func pttUp() {
        if ignoreNextUp { ignoreNextUp = false; return }
        guard case .recording = state, !handsFree else { return }
        if Date().timeIntervalSince(recordStart) < minHold {
            guard Prefs.trigger == .holdOrTap else { cancelRecording(); return }
            // Short tap: keep listening until the next tap (or Esc).
            handsFree = true
            overlay.locked = true
            let started = recordStart
            DispatchQueue.main.asyncAfter(deadline: .now() + maxHandsFree) { [weak self] in
                guard let self, case .recording = self.state, self.handsFree, self.recordStart == started else { return }
                self.finishRecording()
            }
            return
        }
        finishRecording()
    }

    /// Esc: drop the current recording, or discard a transcription that is still running.
    private func escapePressed() {
        switch state {
        case .recording: cancelRecording()
        case .transcribing:
            job += 1
            session?.cancel()
            session = nil
            setState(.idle)
        default: break
        }
    }

    private func cancelRecording() {
        guard case .recording = state else { return }
        _ = recorder.stop()
        stopStreaming(cancel: true)
        handsFree = false
        SystemMute.end()
        setState(.idle)
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        handsFree = false
        let audio = recorder.stop()
        SystemMute.end()
        if Prefs.sounds { NSSound(named: "Pop")?.play() }
        guard let sess = session, AudioUtil.rms(audio) >= 0.0015 else { stopStreaming(cancel: true); setState(.idle); return } // silence
        stopStreaming(cancel: false)
        setState(.transcribing)
        job += 1
        let myJob = job
        let released = Date()
        let early = sess.piecesSent
        sess.finish { [weak self] r in
            guard let self else { return }
            NSLog("JustTellMe: [\(r.lang)] %.1fs audio, %d piece(s) sent while speaking, ready %.2fs after release: \(r.text)",
                  Double(audio.count) / 16_000, early, Date().timeIntervalSince(released))
            self.transcriber.scheduleIdleUnload()
            guard myJob == self.job else { return } // cancelled with Esc
            self.setState(.idle)
            guard !r.text.isEmpty else { return }
            var out = r.text
            if let last = out.last, ".!?…".contains(last) { out += " " }
            self.lastResult = r.text
            self.updateStatusLine()
            History.shared.add(text: r.text, lang: r.lang, app: NSWorkspace.shared.frontmostApplication?.localizedName, seconds: Double(audio.count) / 16_000)
            Paster.shared.insert(out)
        }
    }

    private func stopStreaming(cancel: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        if cancel { session?.cancel(); session = nil }
    }

    // MARK: - Status icon

    private func setState(_ s: State) {
        state = s
        switch s {
        case .recording: overlay.show(.recording)
        case .transcribing: overlay.show(.transcribing)
        default: overlay.hide()
        }
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
        secureItem.isEnabled = false
        secureItem.isHidden = true
        menu.addItem(secureItem)
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
        settingsRoot.submenu = NSMenu()
        menu.addItem(settingsRoot)

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
        let stats = NSMenuItem(title: "Статистика…", action: #selector(openStats), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        historyRoot.submenu = NSMenu()
        menu.addItem(historyRoot)

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
            modelRoot.title = "Модель: " + (transcriber.loadedURL.map { ModelInfo(url: $0, bundled: false).name } ?? "—") + (transcriber.usesNeuralEngine ? " · Neural Engine" : "")
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
        rebuildSettingsMenu()
        if let who = SecureInput.isOn ? (SecureInput.holder() ?? "другое приложение") : nil {
            secureItem.title = "⚠︎ Защищённый ввод включён (\(who)) — Esc не отменит запись"
            secureItem.toolTip = "Так macOS защищает поле пароля или «Защищённый ввод с клавиатуры» в Терминале. Диктовка работает, но нажатия клавиш до JustTellMe не доходят."
            secureItem.isHidden = false
        } else {
            secureItem.isHidden = true
        }
        builtinItem.title = "Встроенный словарь ru/en (\(Vocabulary.shared.builtinTerms.count) слов)"
        rebuildModelMenu()
        rebuildHistoryMenu()
        refreshPermissionItems()
    }

    private func rebuildHistoryMenu() {
        guard let m = historyRoot.submenu else { return }
        m.removeAllItems()
        m.autoenablesItems = false
        let recent = History.shared.entries.prefix(10)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Пока пусто", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            m.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Клик — скопировать", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            m.addItem(hint)
            for e in recent {
                let short = e.text.count > 60 ? String(e.text.prefix(60)) + "…" : e.text
                let it = NSMenuItem(title: short, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = e.text
                it.toolTip = e.text
                m.addItem(it)
            }
        }
        m.addItem(.separator())
        let all = NSMenuItem(title: "Вся история… (\(History.shared.entries.count))", action: #selector(openHistory), keyEquivalent: "")
        all.target = self
        m.addItem(all)
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func openHistory() { historyWindow.open() }

    @objc private func openStats() {
        statsWindow.onOpenHistory = { [weak self] in self?.historyWindow.open() }
        statsWindow.open()
    }

    @objc private func toggleBuiltin() { Vocabulary.shared.builtinEnabled.toggle() }

    // MARK: - Settings menu

    private func rebuildSettingsMenu() {
        guard let m = settingsRoot.submenu else { return }
        m.removeAllItems()
        m.autoenablesItems = false
        func item(_ title: String, _ sel: Selector, on: Bool, _ obj: Any? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            it.representedObject = obj
            m.addItem(it)
            return it
        }
        func header(_ t: String) { let h = NSMenuItem(title: t, action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h) }

        header("Клавиша \(hotkey.key.short)")
        for t in Prefs.Trigger.allCases { _ = item(t.title, #selector(pickTrigger(_:)), on: Prefs.trigger == t, t.rawValue) }
        header("Esc — отменить запись или распознавание")
        m.addItem(.separator())
        _ = item("Звуки начала и конца записи", #selector(toggleSounds), on: Prefs.sounds)
        _ = item("Приглушать звук компьютера во время диктовки", #selector(toggleMute), on: Prefs.muteWhileRecording)
        let clip = item("Возвращать прежний буфер обмена после вставки", #selector(toggleClipboard), on: Prefs.restoreClipboard)
        clip.toolTip = "Если выключить, надиктованный текст останется в буфере обмена. Менеджеры буфера (Maccy, Raycast, Paste) надиктованное не сохраняют, пока эта опция включена."
        m.addItem(.separator())

        let micRoot = NSMenuItem(title: "Микрофон", action: nil, keyEquivalent: "")
        let mics = NSMenu(); mics.autoenablesItems = false
        let sysName = AudioDevices.defaultDevice(input: true).flatMap(AudioDevices.name(of:)) ?? "—"
        let devices = AudioDevices.inputs()
        let current = Prefs.micUID.flatMap { uid in devices.contains { $0.uid == uid } ? uid : nil }
        let sys = NSMenuItem(title: "Как в системе (\(sysName))", action: #selector(pickMic(_:)), keyEquivalent: "")
        sys.target = self
        sys.state = current == nil ? .on : .off
        mics.addItem(sys)
        mics.addItem(.separator())
        for d in devices {
            let it = NSMenuItem(title: d.name, action: #selector(pickMic(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.uid
            it.state = d.uid == current ? .on : .off
            mics.addItem(it)
        }
        if let uid = Prefs.micUID, current == nil {
            let gone = NSMenuItem(title: "Выбранный микрофон не подключён — используется системный", action: nil, keyEquivalent: "")
            gone.isEnabled = false
            gone.toolTip = uid
            mics.addItem(.separator())
            mics.addItem(gone)
        }
        micRoot.submenu = mics
        m.addItem(micRoot)

        m.addItem(.separator())
        let ne = item(neuralTitle, #selector(toggleNeural), on: Prefs.neuralEngine)
        ne.toolTip = "Тяжёлая часть Whisper считается на Neural Engine — примерно в 5 раз быстрее на M1 и не зависит от загрузки видеокарты другими приложениями. Нужно скачать 1,2 ГБ; затем macOS один раз готовит модель (до ~30 минут), пока диктовка работает как обычно."
        if case .failed = neural.status {
            let retry = item("Повторить подготовку Neural Engine", #selector(retryNeural), on: false)
            retry.indentationLevel = 1
        }
        let unloadRoot = NSMenuItem(title: "Выгружать модель из памяти", action: nil, keyEquivalent: "")
        let un = NSMenu(); un.autoenablesItems = false
        for (mins, title) in [(0, "Никогда (самый быстрый ответ)"), (5, "Через 5 минут простоя"), (15, "Через 15 минут простоя"), (60, "Через час простоя")] {
            let it = NSMenuItem(title: title, action: #selector(pickUnload(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mins
            it.state = Prefs.unloadAfterMinutes == mins ? .on : .off
            un.addItem(it)
        }
        let note = NSMenuItem(title: "После выгрузки первая диктовка чуть дольше", action: nil, keyEquivalent: "")
        note.isEnabled = false
        un.addItem(.separator())
        un.addItem(note)
        unloadRoot.submenu = un
        m.addItem(unloadRoot)
    }

    private var neuralTitle: String {
        guard Prefs.neuralEngine else { return "Ускорение Neural Engine (скачать 1,2 ГБ)…" }
        switch neural.status {
        case .off: return "Ускорение Neural Engine"
        case .downloading(let p): return "Neural Engine: скачивание \(Int(p * 100))%"
        case .unpacking: return "Neural Engine: распаковка…"
        case .preparing: return "Neural Engine: macOS готовит модель (один раз, до ~30 мин)…"
        case .ready: return transcriber.usesNeuralEngine ? "Ускорение Neural Engine — работает" : "Ускорение Neural Engine — подключается…"
        case .failed(let e): return "Neural Engine: ошибка — \(e)"
        }
    }

    @objc private func toggleNeural() {
        if Prefs.neuralEngine {
            Prefs.neuralEngine = false
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Включить ускорение Neural Engine?"
            a.informativeText = "JustTellMe скачает версию модели для Neural Engine (1,2 ГБ). Потом macOS один раз подготовит её — на M1 это до 30 минут с полной загрузкой процессора. Всё это время диктовка работает как обычно, а потом станет примерно в 5 раз быстрее.\n\nПосле обновления JustTellMe подготовка может повториться."
            a.addButton(withTitle: "Включить")
            a.addButton(withTitle: "Отмена")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            Prefs.neuralEngine = true
        }
        if let m = ModelManager.active() { neural.update(for: m.url) }
        neuralChanged()
    }

    @objc private func retryNeural() {
        guard let m = ModelManager.active() else { return }
        neural.retry(for: m.url)
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = Prefs.Trigger(rawValue: raw) { Prefs.trigger = t }
    }
    @objc private func toggleSounds() { Prefs.sounds.toggle() }
    @objc private func toggleMute() { Prefs.muteWhileRecording.toggle() }
    @objc private func toggleClipboard() { Prefs.restoreClipboard.toggle() }
    @objc private func pickMic(_ sender: NSMenuItem) { Prefs.micUID = sender.representedObject as? String }
    @objc private func pickUnload(_ sender: NSMenuItem) {
        Prefs.unloadAfterMinutes = sender.representedObject as? Int ?? 0
        applyUnloadPref()
    }

    private func applyUnloadPref() {
        let m = Prefs.unloadAfterMinutes
        transcriber.idleUnload = m > 0 ? TimeInterval(m * 60) : nil
        transcriber.scheduleIdleUnload()
    }

    func applicationWillTerminate(_ note: Notification) { SystemMute.end() }

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
