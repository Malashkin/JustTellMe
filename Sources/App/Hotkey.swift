import Cocoa

/// Global push-to-talk on a single modifier key (Fn/🌐 or Right Option) via a listen-only CGEventTap.
/// Needs Accessibility (or Input Monitoring) permission; `install()` returns false until granted.
final class PushToTalkHotkey {
    enum Key: String, CaseIterable {
        case fn, rightOption

        var title: String {
            switch self {
            case .fn: return "Fn (🌐)"
            case .rightOption: return "Правый ⌥ Option"
            }
        }
        /// Short form for status lines: "удерживайте Fn".
        var short: String {
            switch self {
            case .fn: return "Fn"
            case .rightOption: return "правый ⌥"
            }
        }
        fileprivate var keycode: Int64 {
            switch self {
            case .fn: return 63           // kVK_Function
            case .rightOption: return 61  // kVK_RightOption
            }
        }
        fileprivate var flagMask: UInt64 {
            switch self {
            case .fn: return CGEventFlags.maskSecondaryFn.rawValue // NX_SECONDARYFNMASK
            case .rightOption: return 0x40                         // NX_DEVICERALTKEYMASK
            }
        }
    }

    var key: Key {
        didSet { if held { held = false; DispatchQueue.main.async { self.onCombo?() } } }
    }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Called when another key is pressed while the hotkey is held (a shortcut, not dictation).
    var onCombo: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false

    init(key: Key) { self.key = key }

    var isInstalled: Bool { tap != nil }

    func install() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<PushToTalkHotkey>.fromOpaque(refcon!).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: me)
        else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keycode else { return }
            let down = (event.flags.rawValue & key.flagMask) != 0
            if down && !held { held = true; DispatchQueue.main.async { self.onDown?() } }
            else if !down && held { held = false; DispatchQueue.main.async { self.onUp?() } }
        case .keyDown:
            if held { DispatchQueue.main.async { self.onCombo?() } }
        default: break
        }
    }
}
