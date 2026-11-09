import Carbon
import Cocoa
import CoreAudio

/// User preferences (UserDefaults-backed).
enum Prefs {
    enum Trigger: String, CaseIterable {
        case holdOrTap, holdOnly
        var title: String {
            switch self {
            case .holdOrTap: return "Удерживать или нажать (короткое нажатие — без рук)"
            case .holdOnly: return "Только удерживать"
            }
        }
    }

    private static let d = UserDefaults.standard

    static var trigger: Trigger {
        get { Trigger(rawValue: d.string(forKey: "trigger") ?? "") ?? .holdOrTap }
        set { d.set(newValue.rawValue, forKey: "trigger") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }
    /// Put the previous clipboard back after pasting (otherwise the dictated text stays in the clipboard).
    static var restoreClipboard: Bool {
        get { d.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreClipboard") }
    }
    static var muteWhileRecording: Bool {
        get { d.bool(forKey: "muteWhileRecording") }
        set { d.set(newValue, forKey: "muteWhileRecording") }
    }
    /// Minutes of inactivity before the model is freed from memory; 0 = keep loaded.
    static var unloadAfterMinutes: Int {
        get { d.integer(forKey: "unloadAfterMinutes") }
        set { d.set(newValue, forKey: "unloadAfterMinutes") }
    }
    /// Run Whisper's encoder on the Neural Engine (Core ML) when available.
    static var neuralEngine: Bool {
        get { d.bool(forKey: "neuralEngine") }
        set { d.set(newValue, forKey: "neuralEngine") }
    }
    /// CoreAudio UID of the preferred microphone; nil = system default.
    static var micUID: String? {
        get { d.string(forKey: "micUID") }
        set { d.set(newValue, forKey: "micUID") }
    }
}

// MARK: - CoreAudio helpers

enum AudioDevices {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    static func inputs() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }

    static func muted(_ id: AudioDeviceID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    @discardableResult
    static func setMuted(_ id: AudioDeviceID, _ on: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}

/// Mutes the speakers while dictating and puts them back exactly as they were (never unmutes
/// something the user had muted themselves).
enum SystemMute {
    private static var mutedDevice: AudioDeviceID?

    static func begin() {
        guard mutedDevice == nil, let out = AudioDevices.defaultDevice(input: false),
              AudioDevices.muted(out) == false, AudioDevices.setMuted(out, true) else { return }
        mutedDevice = out
    }

    static func end() {
        guard let d = mutedDevice else { return }
        mutedDevice = nil
        AudioDevices.setMuted(d, false)
    }
}

/// "Secure Event Input": while a password field (or Terminal's Secure Keyboard Entry) holds it,
/// macOS stops delivering key presses to other apps. Our modifier-only hotkey still works,
/// but Esc-to-cancel does not.
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Name of the app holding secure input (from the console user's IORegistry entry), if any.
    static func holder() -> String? {
        guard isOn else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-l", "-w", "0", "-d", "1", "-k", "IOConsoleUsers"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let r = out.range(of: #""kCGSSessionSecureInputPID"=(\d+)"#, options: .regularExpression) else { return nil }
        let pid = pid_t(out[r].split(separator: "=").last.map(String.init) ?? "") ?? 0
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
