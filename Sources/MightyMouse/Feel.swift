import AppKit
import ApplicationServices

/// The mouse's built-in haptic waveforms we use, by what they mean to us.
enum Wave: UInt8 {
    case grab = 0x00      // sharp state change
    case drop = 0x01      // damp state change
    case edge = 0x02      // sharp collision
    case swipe = 0x03     // damp collision
    case tick = 0x04      // subtle collision
    case hello = 0x05     // happy alert
    case hover = 0x1B     // whisper collision
}

// MARK: - Screen-edge snapping

enum Snap {
    /// If the cursor is pressed against a screen edge or corner, the frame a window should snap to
    /// (in top-left-origin screen coordinates, which is what the accessibility API uses).
    static func zone(for m: CGPoint) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let h = primary.frame.height
        func flip(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height) }
        let frames = NSScreen.screens.map { flip($0.frame) }
        // An edge only counts if there is no other display beyond it.
        func open(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
            !frames.contains { $0.contains(CGPoint(x: m.x + dx, y: m.y + dy)) }
        }
        for sc in NSScreen.screens {
            let full = flip(sc.frame)
            guard full.insetBy(dx: -1, dy: -1).contains(m) else { continue }
            let vis = flip(sc.visibleFrame)
            let e: CGFloat = 5
            let left = m.x <= full.minX + e && open(-12, 0)
            let right = m.x >= full.maxX - e - 1 && open(12, 0)
            let top = m.y <= full.minY + e && open(0, -12)
            let bottom = m.y >= full.maxY - e - 1 && open(0, 12)
            let w = vis.width / 2, hh = vis.height / 2
            if top && left { return CGRect(x: vis.minX, y: vis.minY, width: w, height: hh) }
            if top && right { return CGRect(x: vis.midX, y: vis.minY, width: w, height: hh) }
            if bottom && left { return CGRect(x: vis.minX, y: vis.midY, width: w, height: hh) }
            if bottom && right { return CGRect(x: vis.midX, y: vis.midY, width: w, height: hh) }
            if top { return vis }
            if left { return CGRect(x: vis.minX, y: vis.minY, width: w, height: vis.height) }
            if right { return CGRect(x: vis.midX, y: vis.minY, width: w, height: vis.height) }
            return nil
        }
        return nil
    }
}

/// Translucent preview of where a window will land.
final class SnapOverlay {
    private var window: NSWindow?

    func show(_ zone: CGRect?) {
        guard let zone, let primary = NSScreen.screens.first else { hide(); return }
        let frame = CGRect(x: zone.minX, y: primary.frame.height - zone.maxY, width: zone.width, height: zone.height)
            .insetBy(dx: 6, dy: 6)
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .floating
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let v = NSView(frame: frame)
            v.wantsLayer = true
            let accent = NSColor(red: 1.0, green: 0.47, blue: 0.33, alpha: 1)
            v.layer?.backgroundColor = accent.withAlphaComponent(0.20).cgColor
            v.layer?.borderColor = accent.withAlphaComponent(0.9).cgColor
            v.layer?.borderWidth = 2
            v.layer?.cornerRadius = 14
            w.contentView = v
            window = w
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}

// MARK: - Feeling what is under the cursor

/// Watches what the cursor is over and reports when it lands on something clickable.
final class HoverFeeler {
    var onLand: (() -> Void)?            // delivered on the main thread
    var onCrossWindow: (() -> Void)?     // delivered on the main thread
    private var watchControls = true
    private var watchWindows = true
    private var lastWindow: CGWindowID?
    private var windowKnown = false

    func configure(controls: Bool, windows: Bool) {
        queue.async { self.watchControls = controls; self.watchWindows = windows; self.windowKnown = false }
    }

    /// The frontmost ordinary window whose frame contains the point.
    private func windowID(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width > 40, rect.height > 40, rect.contains(p) else { continue }
            return w[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }
    private let queue = DispatchQueue(label: "mm.hover", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var lastTarget: AXUIElement?
    private let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.08)
        return s
    }()

    private static let clickable: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXDockItem", "AXRadioButton", "AXCheckBox",
        "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXColorWell", "AXToolbarButton",
    ]

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: .milliseconds(40), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.lastTarget = nil }
    }

    private func role(_ e: AXUIElement) -> String? {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
        return r as? String
    }

    /// The clickable thing this element is, or sits directly inside (e.g. the text inside a link).
    private func clickable(from element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<3 {
            if let r = role(current), Self.clickable.contains(r) { return current }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    private func probe() {
        guard let p = CGEvent(source: nil)?.location, p != lastPoint else { return }
        lastPoint = p
        if watchWindows {
            let id = windowID(at: p)
            if windowKnown, id != lastWindow { DispatchQueue.main.async { self.onCrossWindow?() } }
            lastWindow = id
            windowKnown = true
        }
        guard watchControls else { return }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let hit else {
            lastTarget = nil
            return
        }
        let target = clickable(from: hit)
        defer { lastTarget = target }
        guard let target else { return }
        if let last = lastTarget, CFEqual(last, target) { return }
        DispatchQueue.main.async { self.onLand?() }
    }
}
