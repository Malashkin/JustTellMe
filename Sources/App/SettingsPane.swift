import Cocoa

/// Things the settings page changes that need more than writing a preference.
protocol SettingsHost: AnyObject {
    var hotkeyKey: PushToTalkHotkey.Key { get }
    func setHotkey(_ k: PushToTalkHotkey.Key)
    var languageCode: String { get }
    func setLanguage(_ code: String)
    var loadedModelPath: String? { get }
    func selectModel(path: String)
    func addModelFromFile()
    var neuralStatusText: String { get }
    var neuralFailed: Bool { get }
    func toggleNeural()
    func retryNeural()
    func applyUnloadPref()
    var launchAtLogin: Bool { get }
    func toggleLogin()
    var updateStatusText: String { get }
    func checkForUpdatesNow()
}

/// Settings page of the main window. Mirrors the Settings submenu of the menu-bar icon.
final class SettingsPane: NSObject {
    weak var host: SettingsHost?

    private(set) lazy var view: NSView = build()
    private let keyPopup = NSPopUpButton()
    private let triggerPopup = NSPopUpButton()
    private let langPopup = NSPopUpButton()
    private let micPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let unloadPopup = NSPopUpButton()
    private let neuralBox = NSButton(checkboxWithTitle: tr("Neural Engine Acceleration", "Ускорение Neural Engine"), target: nil, action: nil)
    private let neuralStatus = NSTextField(wrappingLabelWithString: "")
    private let neuralRetry = NSButton(title: tr("Retry", "Повторить"), target: nil, action: nil)
    private let soundsBox = NSButton(checkboxWithTitle: tr("Play sounds when recording starts and stops", "Звуки начала и конца записи"), target: nil, action: nil)
    private let muteBox = NSButton(checkboxWithTitle: tr("Mute computer audio while dictating", "Приглушать звук компьютера во время диктовки"), target: nil, action: nil)
    private let clipBox = NSButton(checkboxWithTitle: tr("Restore previous clipboard after pasting", "Возвращать прежний буфер обмена после вставки"), target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: tr("Open JustTellMe at login", "Запускать JustTellMe при входе в систему"), target: nil, action: nil)
    private let updatesBox = NSButton(checkboxWithTitle: tr("Check for updates daily", "Проверять обновления раз в день"), target: nil, action: nil)
    private let checkNow = NSButton(title: tr("Check Now", "Проверить сейчас"), target: nil, action: nil)
    private let updateStatus = NSTextField(labelWithString: "")
    private let themeControl = CapsuleSegments(Prefs.Theme.allCases.map(\.title))

    private static var languages: [(String, String)] {
        [("auto", tr("Auto (Russian/English, prefers Russian)", "Авто (ru/en, с уклоном в ru)")),
         ("ru", tr("Russian", "Русский")), ("en", "English")]
    }
    static var unloadOptions: [(Int, String)] {
        [(0, tr("Never (keep in memory, ~0.7 GB)", "Никогда (держать в памяти ~0,7 ГБ)")),
         (5, tr("After 5 minutes idle", "Через 5 минут простоя")),
         (15, tr("After 15 minutes idle (recommended)", "Через 15 минут простоя (рекомендуется)")),
         (60, tr("After 1 hour idle", "Через час простоя"))]
    }

    private func build() -> NSView {
        for (p, sel) in [(keyPopup, #selector(keyChanged)), (triggerPopup, #selector(triggerChanged)), (langPopup, #selector(langChanged)),
                         (micPopup, #selector(micChanged)), (modelPopup, #selector(modelChanged)), (unloadPopup, #selector(unloadChanged))] {
            p.target = self
            p.action = sel
        }
        for (b, sel) in [(neuralBox, #selector(neuralChanged)), (neuralRetry, #selector(retryNeural)), (soundsBox, #selector(soundsChanged)),
                         (muteBox, #selector(muteChanged)), (clipBox, #selector(clipChanged)), (loginBox, #selector(loginChanged)),
                         (updatesBox, #selector(updatesChanged)), (checkNow, #selector(checkUpdates))] {
            b.target = self
            b.action = sel
        }
        keyPopup.addItems(withTitles: PushToTalkHotkey.Key.allCases.map(\.title))
        triggerPopup.addItems(withTitles: Prefs.Trigger.allCases.map(\.title))
        langPopup.addItems(withTitles: Self.languages.map(\.1))
        unloadPopup.addItems(withTitles: Self.unloadOptions.map(\.1))
        neuralStatus.textColor = .secondaryLabelColor
        neuralStatus.font = .systemFont(ofSize: 11)
        clipBox.toolTip = tr("When off, the dictated text stays on the clipboard. While this is on, clipboard managers (Maccy, Raycast, Paste) don't save dictated text.",
                             "Если выключить, надиктованный текст останется в буфере обмена. Менеджеры буфера (Maccy, Raycast, Paste) надиктованное не сохраняют, пока эта опция включена.")
        let addModel = NSButton(title: tr("Add from File…", "Добавить из файла…"), target: self, action: #selector(addModel))

        themeControl.onChange = { Prefs.theme = Prefs.Theme.allCases[$0] }
        let grid = NSGridView(views: [
            [caption(tr("Appearance", "Оформление")), themeControl],
            [caption(tr("Dictation key", "Клавиша диктовки")), keyPopup],
            [caption(tr("How the key works", "Как работает клавиша")), triggerPopup],
            [NSGridCell.emptyContentView, note(tr("Esc cancels recording or transcription.", "Esc — отменить запись или распознавание."))],
            [caption(tr("Language", "Язык")), langPopup],
            [caption(tr("Microphone", "Микрофон")), micPopup],
            [caption(tr("Model", "Модель")), NSStackView(views: [modelPopup, addModel])],
            [NSGridCell.emptyContentView, note(tr("To download other models, use the 🎙 menu → Model.", "Скачать другие модели — в меню значка 🎙 → Модель."))],
            [caption(tr("Acceleration", "Ускорение")), NSStackView(views: [neuralBox, neuralRetry])],
            [NSGridCell.emptyContentView, neuralStatus],
            [caption(tr("Unload model from memory", "Выгружать модель из памяти")), unloadPopup],
            [NSGridCell.emptyContentView, note(tr("The model reloads while you speak; on the GPU this takes under a second.", "Модель загружается заново, пока вы говорите: на видеокарте это меньше секунды."))],
            [caption(tr("Sound and pasting", "Звук и вставка")), soundsBox],
            [NSGridCell.emptyContentView, muteBox],
            [NSGridCell.emptyContentView, clipBox],
            [NSGridCell.emptyContentView, note(tr("⌃⌥V pastes the last dictation again.", "⌃⌥V — вставить последнее надиктованное ещё раз."))],
            [caption(tr("Startup", "Запуск")), loginBox],
            [caption(tr("Updates", "Обновления")), NSStackView(views: [updatesBox, checkNow])],
            [NSGridCell.emptyContentView, updateStatus],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 0).rowAlignment = .none
        for i in [3, 7, 9, 11, 15, 18] { grid.row(at: i).topPadding = -6 }
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        neuralStatus.preferredMaxLayoutWidth = 440

        let stack = NSStackView(views: [grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        return l
    }

    /// Refresh every control from the current preferences and app state.
    func reload() {
        _ = view
        if let k = host?.hotkeyKey, let i = PushToTalkHotkey.Key.allCases.firstIndex(of: k) { keyPopup.selectItem(at: i) }
        if let i = Prefs.Trigger.allCases.firstIndex(of: Prefs.trigger) { triggerPopup.selectItem(at: i) }
        themeControl.selected = Prefs.Theme.allCases.firstIndex(of: Prefs.theme) ?? 0
        if let i = Self.languages.firstIndex(where: { $0.0 == (host?.languageCode ?? "auto") }) { langPopup.selectItem(at: i) }
        if let i = Self.unloadOptions.firstIndex(where: { $0.0 == Prefs.unloadAfterMinutes }) { unloadPopup.selectItem(at: i) }

        // Don't rebuild menus while one is open (reload runs on a timer).
        if micPopup.menu?.highlightedItem == nil {
            micPopup.removeAllItems()
            let sysName = AudioDevices.defaultDevice(input: true).flatMap(AudioDevices.name(of:)) ?? "—"
            micPopup.addItem(withTitle: tr("System Default (\(sysName))", "Как в системе (\(sysName))"))
            micPopup.lastItem?.representedObject = nil
            let devices = AudioDevices.inputs()
            for d in devices {
                micPopup.addItem(withTitle: d.name)
                micPopup.lastItem?.representedObject = d.uid
            }
            let current = Prefs.micUID.flatMap { uid in devices.firstIndex { $0.uid == uid } }
            micPopup.selectItem(at: current.map { $0 + 1 } ?? 0)
        }
        if modelPopup.menu?.highlightedItem == nil {
            modelPopup.removeAllItems()
            let active = host?.loadedModelPath ?? ModelManager.active()?.url.path
            for info in ModelManager.available() {
                modelPopup.addItem(withTitle: "\(info.name)  (\(info.sizeMB) \(tr("MB", "МБ"))\(info.bundled ? tr(", built-in", ", встроенная") : ""))")
                modelPopup.lastItem?.representedObject = info.url.path
                if info.url.path == active { modelPopup.select(modelPopup.lastItem) }
            }
        }

        neuralBox.state = Prefs.neuralEngine ? .on : .off
        neuralStatus.stringValue = Prefs.neuralEngine ? (host?.neuralStatusText ?? "")
            : tr("Runs the heavy part of Whisper on the Neural Engine, about 5 times faster on M1. Requires a 1.2 GB download, then macOS prepares the model once (up to ~30 minutes) while dictation keeps working as usual.",
                 "Тяжёлая часть Whisper считается на Neural Engine — примерно в 5 раз быстрее на M1. Нужно скачать 1,2 ГБ, затем macOS один раз готовит модель (до ~30 минут), пока диктовка работает как обычно.")
        neuralRetry.isHidden = host?.neuralFailed != true
        soundsBox.state = Prefs.sounds ? .on : .off
        muteBox.state = Prefs.muteWhileRecording ? .on : .off
        clipBox.state = Prefs.restoreClipboard ? .on : .off
        loginBox.state = host?.launchAtLogin == true ? .on : .off
        updatesBox.state = Prefs.checkUpdates ? .on : .off
        updateStatus.stringValue = host?.updateStatusText ?? tr("Version \(Updater.currentVersion) installed.", "Установлена версия \(Updater.currentVersion).")
    }

    @objc private func keyChanged() { host?.setHotkey(PushToTalkHotkey.Key.allCases[keyPopup.indexOfSelectedItem]) }
    @objc private func triggerChanged() { Prefs.trigger = Prefs.Trigger.allCases[triggerPopup.indexOfSelectedItem] }
    @objc private func langChanged() { host?.setLanguage(Self.languages[langPopup.indexOfSelectedItem].0) }
    @objc private func micChanged() { Prefs.micUID = micPopup.selectedItem?.representedObject as? String }
    @objc private func modelChanged() {
        if let path = modelPopup.selectedItem?.representedObject as? String { host?.selectModel(path: path) }
        reload()
    }
    @objc private func addModel() { host?.addModelFromFile(); reload() }
    @objc private func unloadChanged() {
        Prefs.unloadAfterMinutes = Self.unloadOptions[unloadPopup.indexOfSelectedItem].0
        host?.applyUnloadPref()
    }
    @objc private func neuralChanged() { host?.toggleNeural(); reload() }
    @objc private func retryNeural() { host?.retryNeural(); reload() }
    @objc private func soundsChanged() { Prefs.sounds = soundsBox.state == .on }
    @objc private func muteChanged() { Prefs.muteWhileRecording = muteBox.state == .on }
    @objc private func clipChanged() { Prefs.restoreClipboard = clipBox.state == .on }
    @objc private func loginChanged() { host?.toggleLogin(); reload() }
    @objc private func updatesChanged() { Prefs.checkUpdates = updatesBox.state == .on }
    @objc private func checkUpdates() { host?.checkForUpdatesNow(); reload() }
}
