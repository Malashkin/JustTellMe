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
}

/// "Настройки" page of the main window. Mirrors the Настройки submenu of the menu-bar icon.
final class SettingsPane: NSObject {
    weak var host: SettingsHost?

    private(set) lazy var view: NSView = build()
    private let keyPopup = NSPopUpButton()
    private let triggerPopup = NSPopUpButton()
    private let langPopup = NSPopUpButton()
    private let micPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let unloadPopup = NSPopUpButton()
    private let neuralBox = NSButton(checkboxWithTitle: "Ускорение Neural Engine", target: nil, action: nil)
    private let neuralStatus = NSTextField(wrappingLabelWithString: "")
    private let neuralRetry = NSButton(title: "Повторить", target: nil, action: nil)
    private let soundsBox = NSButton(checkboxWithTitle: "Звуки начала и конца записи", target: nil, action: nil)
    private let muteBox = NSButton(checkboxWithTitle: "Приглушать звук компьютера во время диктовки", target: nil, action: nil)
    private let clipBox = NSButton(checkboxWithTitle: "Возвращать прежний буфер обмена после вставки", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Запускать JustTellMe при входе в систему", target: nil, action: nil)

    private static let languages = [("auto", "Авто (ru/en, с уклоном в ru)"), ("ru", "Русский"), ("en", "English")]
    private static let unloadOptions = [(0, "Никогда (самый быстрый ответ)"), (5, "Через 5 минут простоя"), (15, "Через 15 минут простоя"), (60, "Через час простоя")]

    private func build() -> NSView {
        for (p, sel) in [(keyPopup, #selector(keyChanged)), (triggerPopup, #selector(triggerChanged)), (langPopup, #selector(langChanged)),
                         (micPopup, #selector(micChanged)), (modelPopup, #selector(modelChanged)), (unloadPopup, #selector(unloadChanged))] {
            p.target = self
            p.action = sel
        }
        for (b, sel) in [(neuralBox, #selector(neuralChanged)), (neuralRetry, #selector(retryNeural)), (soundsBox, #selector(soundsChanged)),
                         (muteBox, #selector(muteChanged)), (clipBox, #selector(clipChanged)), (loginBox, #selector(loginChanged))] {
            b.target = self
            b.action = sel
        }
        keyPopup.addItems(withTitles: PushToTalkHotkey.Key.allCases.map(\.title))
        triggerPopup.addItems(withTitles: Prefs.Trigger.allCases.map(\.title))
        langPopup.addItems(withTitles: Self.languages.map(\.1))
        unloadPopup.addItems(withTitles: Self.unloadOptions.map(\.1))
        neuralStatus.textColor = .secondaryLabelColor
        neuralStatus.font = .systemFont(ofSize: 11)
        clipBox.toolTip = "Если выключить, надиктованный текст останется в буфере обмена. Менеджеры буфера (Maccy, Raycast, Paste) надиктованное не сохраняют, пока эта опция включена."
        let addModel = NSButton(title: "Добавить из файла…", target: self, action: #selector(addModel))

        let grid = NSGridView(views: [
            [caption("Клавиша диктовки"), keyPopup],
            [caption("Как работает клавиша"), triggerPopup],
            [NSGridCell.emptyContentView, note("Esc — отменить запись или распознавание.")],
            [caption("Язык"), langPopup],
            [caption("Микрофон"), micPopup],
            [caption("Модель"), NSStackView(views: [modelPopup, addModel])],
            [NSGridCell.emptyContentView, note("Скачать другие модели — в меню значка 🎙 → Модель.")],
            [caption("Ускорение"), NSStackView(views: [neuralBox, neuralRetry])],
            [NSGridCell.emptyContentView, neuralStatus],
            [caption("Выгружать модель из памяти"), unloadPopup],
            [NSGridCell.emptyContentView, note("После выгрузки первая диктовка чуть дольше.")],
            [caption("Звук и вставка"), soundsBox],
            [NSGridCell.emptyContentView, muteBox],
            [NSGridCell.emptyContentView, clipBox],
            [caption("Запуск"), loginBox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in [2, 6, 8, 10] { grid.row(at: i).topPadding = -6 }
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
        if let i = Self.languages.firstIndex(where: { $0.0 == (host?.languageCode ?? "auto") }) { langPopup.selectItem(at: i) }
        if let i = Self.unloadOptions.firstIndex(where: { $0.0 == Prefs.unloadAfterMinutes }) { unloadPopup.selectItem(at: i) }

        // Don't rebuild menus while one is open (reload runs on a timer).
        if micPopup.menu?.highlightedItem == nil {
            micPopup.removeAllItems()
            let sysName = AudioDevices.defaultDevice(input: true).flatMap(AudioDevices.name(of:)) ?? "—"
            micPopup.addItem(withTitle: "Как в системе (\(sysName))")
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
                modelPopup.addItem(withTitle: "\(info.name)  (\(info.sizeMB) МБ\(info.bundled ? ", встроенная" : ""))")
                modelPopup.lastItem?.representedObject = info.url.path
                if info.url.path == active { modelPopup.select(modelPopup.lastItem) }
            }
        }

        neuralBox.state = Prefs.neuralEngine ? .on : .off
        neuralStatus.stringValue = Prefs.neuralEngine ? (host?.neuralStatusText ?? "")
            : "Тяжёлая часть Whisper считается на Neural Engine — примерно в 5 раз быстрее на M1. Нужно скачать 1,2 ГБ, затем macOS один раз готовит модель (до ~30 минут), пока диктовка работает как обычно."
        neuralRetry.isHidden = host?.neuralFailed != true
        soundsBox.state = Prefs.sounds ? .on : .off
        muteBox.state = Prefs.muteWhileRecording ? .on : .off
        clipBox.state = Prefs.restoreClipboard ? .on : .off
        loginBox.state = host?.launchAtLogin == true ? .on : .off
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
}
