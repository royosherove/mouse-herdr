import AppKit
import CoreGraphics

/// Turns an Action into something that actually happens on the Mac.
enum ActionRunner {
    /// Stamped on events we create so our own button tap ignores them.
    static let marker: Int64 = 0x4D4D_4F55

    static func run(_ action: Action) {
        switch action.kind {
        case "shortcut":
            guard let code = action.keyCode else { return }
            key(code, NSEvent.ModifierFlags(rawValue: action.modifiers ?? 0))
        case "app":
            if let p = action.appPath { open(p) }
        default:
            guard let preset = Catalog.byID[action.kind] else { return }
            switch preset.effect {
            case .passthrough, .nothing, .dragWindow: break
            case .key(let code, let flags): key(code, flags)
            case .media(let k): media(k)
            case .dock(let name): dock(name)
            case .middleClick: middleClick()
            case .open(let path): open(path)
            }
        }
    }

    // MARK: Keyboard

    static func key(_ code: Int, _ flags: NSEvent.ModifierFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let mods: [(NSEvent.ModifierFlags, CGKeyCode, CGEventFlags)] = [
            (.control, 59, .maskControl), (.option, 58, .maskAlternate),
            (.shift, 56, .maskShift), (.command, 55, .maskCommand),
        ]
        let active = mods.filter { flags.contains($0.0) }
        var current: CGEventFlags = []
        func post(_ vk: CGKeyCode, _ down: Bool) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down) else { return }
            e.flags = current
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        // Press the modifiers for real, then the key, then let go — the most widely accepted form.
        for m in active { current.insert(m.2); post(m.1, true) }
        post(CGKeyCode(code), true)
        post(CGKeyCode(code), false)
        for m in active.reversed() { current.remove(m.2); post(m.1, false) }
    }

    // MARK: Media keys

    static func media(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: Int((key << 16) | (state << 8)), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Mission Control and friends

    private typealias DockNotify = @convention(c) (CFString, UnsafeRawPointer?) -> Void
    private static let dockNotify: DockNotify? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: DockNotify.self)
    }()

    static func dock(_ name: String) {
        if let f = dockNotify { f(name as CFString, nil); return }
        // Fallback: the Mission Control app accepts a mode argument.
        let args: [String]
        switch name {
        case "com.apple.expose.front.awake": args = ["2"]
        case "com.apple.showdesktop.awake": args = ["1"]
        default: args = []
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        p.arguments = args
        do { try p.run() } catch { Log.write("mission control launch failed: \(error)") }
    }

    // MARK: Mouse

    static func middleClick() {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: .center) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Watches the standard extra mouse buttons (wheel click, back, forward) and lets us replace them.
final class ButtonTap {
    /// Called on button-down. Return true to swallow the click.
    var onPress: ((Int) -> Bool)?
    /// Whether a button is currently remapped (so its release and drags are swallowed too).
    var isMapped: ((Int) -> Bool)?
    /// Called when a remapped button is let go.
    var onRelease: ((Int) -> Void)?
    /// Called for ordinary left/right clicks. Return true to swallow the click.
    var onPlainClick: (() -> Bool)?
    private var swallowUp = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                let me = Unmanaged<ButtonTap>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handle(type, event)
            }, userInfo: ctx)
        else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.write("button tap started")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == ActionRunner.marker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            swallowUp = onPlainClick?() ?? false
            return swallowUp ? nil : Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp || type == .rightMouseUp {
            if swallowUp { swallowUp = false; return nil }
            return Unmanaged.passUnretained(event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseDown {
            return (onPress?(button) ?? false) ? nil : Unmanaged.passUnretained(event)
        }
        guard isMapped?(button) ?? false else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseUp { onRelease?(button) }
        return nil
    }
}
