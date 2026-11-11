import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement
import SwiftUI

/// Moves the active window along with the cursor while a button is held.
final class WindowDragger {
    private var window: AXUIElement?
    private var startOrigin = CGPoint.zero
    private var startMouse = CGPoint.zero
    private var last = CGPoint.zero
    private var timer: Timer?

    var isDragging: Bool { timer != nil }

    /// The window an on-screen element belongs to.
    private func window(containing element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<25 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if (role as? String) == (kAXWindowRole as String) { return current }
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXWindowAttribute as CFString, &win) == .success,
               let win, CFGetTypeID(win) == AXUIElementGetTypeID() {
                return (win as! AXUIElement)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    private func windowUnderCursor(_ p: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
        return window(containing: hit)
    }

    private func activeWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var ref: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &ref)
        if err != .success || ref == nil {
            err = AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &ref)
        }
        guard err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    func begin() {
        end()
        let mouse = CGEvent(source: nil)?.location ?? .zero
        // Prefer the window under the cursor (active or not); fall back to the active window.
        let under = windowUnderCursor(mouse)
        guard let win = under ?? activeWindow() else {
            Log.write("drag: no window found")
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        loggedFailure = false
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() else { return }
        var origin = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        window = win
        startOrigin = origin
        last = origin
        startMouse = mouse
        Log.write("drag: grabbed \(under != nil ? "window under cursor" : "active window") of \(owner) at \(Int(origin.x)),\(Int(origin.y))")
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func update() {
        guard let window, let mouse = CGEvent(source: nil)?.location else { return }
        var target = CGPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y)
        guard target != last else { return }
        last = target
        if let v = AXValueCreate(.cgPoint, &target) {
            let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
            if err != .success && !loggedFailure {
                loggedFailure = true
                Log.write("drag: window refused to move (\(err.rawValue))")
            }
        }
    }

    private var loggedFailure = false

    func end() {
        if timer != nil { Log.write("drag: dropped at \(Int(last.x)),\(Int(last.y))") }
        timer?.invalidate()
        timer = nil
        window = nil
    }
}

final class AppState: ObservableObject {
    @Published var assignments: [Slot: Action] = ConfigStore.load()
    @Published var selected: Slot = .thumbPanel
    @Published var gesturePart: Slot = .gesture
    @Published var recording = false

    @Published var hidStatus: HIDPP.Status = .searching
    @Published var deviceName: String?
    @Published var battery: Int?
    @Published var charging = false
    @Published var accessibilityOK = false
    @Published var inputMonitoringOK = false
    @Published var needsRelaunch = false
    @Published var launchAtLogin = false
    @Published var available: Set<Slot> = []
    @Published var directLink = false   // true when the mouse reports real press/hold/release

    let hid = HIDPP()
    let tap = ButtonTap()
    let dragger = WindowDragger()
    private var timer: Timer?
    private var keyMonitor: Any?

    // HID++ control ids
    private var cidForSlot: [Slot: UInt16] = [:]
    private var slotForCID: [UInt16: Slot] = [:]
    private var rawXYCapable: Set<UInt16> = []
    private var pressed: Set<UInt16> = []
    private var gestureHeld = false
    private var gestureFired = false
    private var gestureAcc = CGPoint.zero
    private var grantRestarts = 0
    private var stickyDrag = false
    private var pulseSource = false
    private var dragPressed = Date.distantPast
    private var gestureStart = CGPoint.zero
    private var gestureTimer: Timer?
    /// Buttons macOS reports directly. 5 and 6 are the MX Master 4's extra side buttons.
    private static let tapButtons: [Int: Slot] = [2: .middle, 3: .back, 4: .forward, 5: .gesture, 6: .thumbPanel]

    /// The slot the right-hand panel is editing.
    var editing: Slot { selected == .gesture ? gesturePart : selected }

    // MARK: Start

    func start() {
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
            setLaunchAtLogin(true)
        }

        tap.onPress = { [weak self] button in
            guard let self, let slot = Self.tapButtons[button] else {
                Log.write("unmapped mouse button \(button) pressed")
                return false
            }
            Log.write("mouse button \(button) pressed → \(slot.rawValue)")
            guard self.isRemapped(slot) else { return false }
            // Without the direct connection the haptic panel only sends a short pulse, so it can't be "held".
            self.press(slot, pulseOnly: slot == .thumbPanel)
            return true
        }
        tap.isMapped = { [weak self] button in
            guard let self, let slot = Self.tapButtons[button] else { return false }
            return self.isRemapped(slot)
        }
        tap.onRelease = { [weak self] button in
            guard let self, let slot = Self.tapButtons[button] else { return }
            Log.write("mouse button \(button) released")
            self.release(slot)
        }
        tap.onPlainClick = { [weak self] in
            // A normal click drops a window that is being carried.
            guard let self, self.stickyDrag else { return false }
            self.stickyDrag = false
            self.dragger.end()
            return true
        }
        if accessibilityOK { tap.start() }

        hid.onStatus = { [weak self] s in
            guard let self else { return }
            self.hidStatus = s
            if s != .connected { self.directLink = false; self.stickyDrag = false; self.pressed = []; self.cidForSlot = [:]; self.slotForCID = [:]; self.updateAvailability() }
            if s == .connected { self.needsRelaunch = false }
        }
        hid.onDevice = { [weak self] name, controls in self?.deviceReady(name, controls) }
        hid.onButtons = { [weak self] cids in self?.buttons(cids) }
        hid.onRawXY = { [weak self] dx, dy in self?.rawXY(dx, dy) }
        hid.onBattery = { [weak self] p, c in self?.battery = p; self?.charging = c }
        hid.start()
        updateAvailability()

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.hid.reapply() }
        }
    }

    private func tick() {
        refreshPermissions()
        if accessibilityOK && !tap.isRunning { tap.start(); updateAvailability() }
        if inputMonitoringOK && hidStatus == .notPermitted {
            if grantRestarts < 2 { grantRestarts += 1; hid.restart() } else { needsRelaunch = true }
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if ax != accessibilityOK { accessibilityOK = ax }
        if im != inputMonitoringOK { inputMonitoringOK = im }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func requestInputMonitoring() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func relaunch() {
        hid.releaseAll()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\" --args --show", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Log.write("launch at login: \(launchAtLogin)")
    }

    // MARK: Assignments

    func action(_ slot: Slot) -> Action { assignments[slot] ?? .standard }

    func assign(_ action: Action, to slot: Slot) {
        assignments[slot] = action
        ConfigStore.save(assignments)
        pushDiversions()
    }

    func resetAll() {
        assignments = ConfigStore.defaults
        ConfigStore.save(assignments)
        pushDiversions()
    }

    private func isRemapped(_ slot: Slot) -> Bool {
        slot == .gesture ? gestureWanted : !action(slot).isDefault
    }

    private var gestureWanted: Bool {
        !action(.gesture).isDefault
            || [Slot.gestureUp, .gestureDown, .gestureLeft, .gestureRight].contains { !action($0).isNothing && !action($0).isDefault }
    }

    private func pushDiversions() {
        var diverts: [UInt16: Bool] = [:]
        if let cid = cidForSlot[.gesture], gestureWanted { diverts[cid] = rawXYCapable.contains(cid) }
        for slot in [Slot.modeShift, .thumbPanel] {
            if let cid = cidForSlot[slot], !action(slot).isDefault { diverts[cid] = false }
        }
        hid.setDiversions(diverts, managed: Array(cidForSlot.values))
    }

    // MARK: Device

    private func deviceReady(_ name: String, _ controls: [HIDPP.Control]) {
        deviceName = name
        cidForSlot = [:]
        rawXYCapable = Set(controls.filter { $0.rawXY }.map { $0.cid })
        let usable = controls.filter { $0.divertable && !$0.isVirtual }
        let ids = Set(usable.map { $0.cid })
        if ids.contains(0x00C3) { cidForSlot[.gesture] = 0x00C3 }
        if ids.contains(0x00C4) { cidForSlot[.modeShift] = 0x00C4 }
        // The haptic panel is whichever capturable control is left once the well-known ones are accounted for.
        let known: Set<UInt16> = [0x0050, 0x0051, 0x0052, 0x0053, 0x0056, 0x00C3, 0x00C4, 0x00D7]
        let extras = usable.filter { !known.contains($0.cid) }
        if let panel = extras.first(where: { $0.cid == 0x01A0 }) ?? extras.first { cidForSlot[.thumbPanel] = panel.cid }
        slotForCID = Dictionary(uniqueKeysWithValues: cidForSlot.map { ($0.value, $0.key) })
        Log.write("slots: " + cidForSlot.map { "\($0.key.rawValue)=\(String(format: "0x%04x", $0.value))" }.sorted().joined(separator: " "))
        updateAvailability()
        pushDiversions()
        directLink = cidForSlot[.thumbPanel] != nil
    }

    private func updateAvailability() {
        var s = Set<Slot>()
        if tap.isRunning { s.formUnion([.middle, .back, .forward, .gesture, .thumbPanel]) }
        if hidStatus == .connected && accessibilityOK { s.formUnion(cidForSlot.keys) }
        available = s
    }

    // MARK: Button handling

    private func press(_ slot: Slot, pulseOnly: Bool = false) {
        pulseSource = pulseOnly
        if slot == .gesture { gestureDown(); return }
        let a = action(slot)
        guard a.isDrag else { ActionRunner.run(a); return }
        if stickyDrag {                 // second press drops the window
            stickyDrag = false
            dragger.end()
        } else {
            dragPressed = Date()
            dragger.begin()
        }
    }

    private func release(_ slot: Slot) {
        if slot == .gesture { gestureUp(); return }
        guard action(slot).isDrag, dragger.isDragging, !stickyDrag else { return }
        if pulseSource {
            // A quick tap (or a button that can't be held): carry the window until the next click.
            stickyDrag = true
            Log.write("drag: carrying until next click")
        } else {
            dragger.end()
        }
    }

    private func gestureDown() {
        gestureHeld = true; gestureFired = false; gestureAcc = .zero
        gestureStart = CGEvent(source: nil)?.location ?? .zero
        gestureTimer?.invalidate()
        // Watch how far the cursor travels while the button is held.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.gestureHeld, !self.gestureFired, let m = CGEvent(source: nil)?.location else { return }
            self.swipe(m.x - self.gestureStart.x, m.y - self.gestureStart.y, threshold: 70)
        }
        RunLoop.main.add(t, forMode: .common)
        gestureTimer = t
    }

    private func gestureUp() {
        gestureTimer?.invalidate(); gestureTimer = nil
        guard gestureHeld else { return }
        gestureHeld = false
        if !gestureFired { ActionRunner.run(action(.gesture)) }
    }

    private func swipe(_ dx: CGFloat, _ dy: CGFloat, threshold: CGFloat) {
        guard max(abs(dx), abs(dy)) > threshold else { return }
        let slot: Slot = abs(dx) > abs(dy) ? (dx > 0 ? .gestureRight : .gestureLeft) : (dy > 0 ? .gestureDown : .gestureUp)
        gestureFired = true
        ActionRunner.run(action(slot))
    }

    private func buttons(_ cids: Set<UInt16>) {
        let newly = cids.subtracting(pressed), released = pressed.subtracting(cids)
        pressed = cids
        for cid in newly {
            if let slot = slotForCID[cid] { press(slot) }
        }
        for cid in released {
            if let slot = slotForCID[cid] { release(slot) }
        }
    }

    private func rawXY(_ dx: Int, _ dy: Int) {
        guard gestureHeld, !gestureFired else { return }
        gestureAcc.x += CGFloat(dx); gestureAcc.y += CGFloat(dy)
        swipe(gestureAcc.x, gestureAcc.y, threshold: 140)
    }

    // MARK: Shortcut recording

    func beginRecording() {
        recording = true
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                guard let self, self.recording else { return ev }
                self.recording = false
                if ev.keyCode == 53 { return nil }   // Esc cancels
                let flags = ev.modifierFlags.intersection([.command, .shift, .option, .control])
                let label = Catalog.shortcutLabel(keyCode: Int(ev.keyCode), flags: flags, characters: ev.charactersIgnoringModifiers)
                self.assign(Action(kind: "shortcut", keyCode: Int(ev.keyCode), modifiers: flags.rawValue, label: label), to: self.editing)
                return nil
            }
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            assign(Action(kind: "app", appPath: url.path), to: editing)
        }
    }

    func shutdown() {
        dragger.end()
        hid.releaseAll()
    }
}
