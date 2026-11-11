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

    var snapEnabled = true
    /// Called when the cursor reaches a screen edge that the window would snap to.
    var onZone: (() -> Void)?
    private var zone: CGRect?
    private let overlay = SnapOverlay()

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
        let z = snapEnabled ? Snap.zone(for: mouse) : nil
        if z != zone {
            zone = z
            overlay.show(z)
            if z != nil { onZone?() }
        }
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

    func end(snap: Bool = true) {
        if !snap { zone = nil }
        if timer != nil { Log.write("drag: dropped at \(Int(last.x)),\(Int(last.y))\(zone != nil ? " (snapped)" : "")") }
        if let window, var origin = zone?.origin, var size = zone?.size {
            // Position, size, then position again — some apps clamp the first move.
            if let p = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
            }
        }
        zone = nil
        overlay.hide()
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
    @Published var hapticsAvailable = false
    @Published var hapticsOn = UserDefaults.standard.object(forKey: "hapticsOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsOn, forKey: "hapticsOn"); applyFeel() }
    }
    @Published var hapticStrength = UserDefaults.standard.object(forKey: "hapticStrength") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(hapticStrength, forKey: "hapticStrength"); applyFeel() }
    }
    @Published var feelHover = UserDefaults.standard.object(forKey: "feelHover") as? Bool ?? true {
        didSet { UserDefaults.standard.set(feelHover, forKey: "feelHover"); applyFeel() }
    }
    @Published var feelEdges = UserDefaults.standard.object(forKey: "feelEdges") as? Bool ?? true {
        didSet { UserDefaults.standard.set(feelEdges, forKey: "feelEdges"); applyFeel() }
    }
    @Published var ringOnTap = UserDefaults.standard.object(forKey: "ringOnTap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ringOnTap, forKey: "ringOnTap") }
    }
    @Published var feelAgents = UserDefaults.standard.object(forKey: "feelAgents") as? Bool ?? true {
        didSet { UserDefaults.standard.set(feelAgents, forKey: "feelAgents") }
    }
    @Published var agentsAvailable = false
    @Published var snapWindows = UserDefaults.standard.object(forKey: "snapWindows") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snapWindows, forKey: "snapWindows"); applyFeel() }
    }
    @Published var directLink = false   // true when the mouse reports real press/hold/release

    let hid = HIDPP()
    let tap = ButtonTap()
    let dragger = WindowDragger()
    let feeler = HoverFeeler()
    let agents = AgentWatcher()
    let ring = AgentRing()
    private var agentStatus: [String: String] = [:]
    private var agentsSeen = false
    private var ticks = 0
    private var ringPress = false
    private var dragStartMouse = CGPoint.zero
    private var wheelAcc = 0.0
    private var wheelLast = Date.distantPast
    private var wheelReady = Date.distantPast
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
            guard let self else { return false }
            // With the agent ring open, a click picks the agent being aimed at.
            if self.ring.isOpen { self.ring.choose(); return true }
            // A normal click drops a window that is being carried.
            guard self.stickyDrag else { return false }
            self.stickyDrag = false
            self.dragger.end()
            return true
        }
        tap.onThumbWheel = { [weak self] delta in self?.thumbWheel(delta) ?? false }
        dragger.onZone = { [weak self] in self?.buzz(.edge) }
        feeler.onLand = { [weak self] in
            guard let self, !self.dragger.isDragging else { return }
            self.buzz(.hover)
        }
        feeler.onCrossWindow = { [weak self] in
            guard let self, !self.dragger.isDragging else { return }
            self.buzz(.tick)
        }
        if accessibilityOK { tap.start() }
        agentsAvailable = agents.isAvailable
        ring.onAim = { [weak self] in self?.buzz(.tick) }
        ring.onChoose = { [weak self] agent in self?.agents.focus(agent) }
        ring.onAnswer = { [weak self] agent, option in
            guard let self else { return }
            self.agents.answer(agent, option: option)
            self.buzz(.tick)
            // The agent may ask its next question; refresh so it can be answered straight away.
            for delay in [1.3, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.ring.isOpen else { return }
                    self.agents.fetch(details: true) { self.ring.update($0) }
                }
            }
        }

        hid.onStatus = { [weak self] s in
            guard let self else { return }
            self.hidStatus = s
            if s != .connected { self.hapticsAvailable = false; self.applyFeel(); self.directLink = false; self.stickyDrag = false; self.pressed = []; self.cidForSlot = [:]; self.slotForCID = [:]; self.updateAvailability() }
            if s == .connected { self.needsRelaunch = false }
        }
        hid.onDevice = { [weak self] name, controls in self?.deviceReady(name, controls) }
        hid.onButtons = { [weak self] cids in self?.buttons(cids) }
        hid.onRawXY = { [weak self] dx, dy in self?.rawXY(dx, dy) }
        hid.onHaptics = { [weak self] ok in self?.hapticsAvailable = ok; self?.applyFeel() }
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
        ticks += 1
        if ticks % 2 == 0 { watchAgents() }
        if accessibilityOK && !tap.isRunning { tap.start(); updateAvailability(); applyFeel() }
        if hidStatus == .notPermitted {
            // macOS sometimes refuses the first attempt right after launch, so keep trying quietly.
            grantRestarts += 1
            if grantRestarts <= 6 || grantRestarts % 5 == 0 { hid.restart() }
            if inputMonitoringOK && grantRestarts > 4 { needsRelaunch = true }
        } else {
            grantRestarts = 0
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

    // MARK: Agents

    /// Notice agents that start waiting on you or finish, and say so through the thumb pad.
    private func watchAgents() {
        guard agentsAvailable, (feelAgents && hapticsOn && hapticsAvailable) || ring.isOpen else { return }
        agents.fetch { [weak self] list in
            guard let self else { return }
            var next: [String: String] = [:]
            var nowWaiting = false, nowDone = false
            for a in list {
                next[a.id] = a.status
                guard self.agentsSeen, let before = self.agentStatus[a.id], before != a.status else { continue }
                if a.needsYou { nowWaiting = true }
                else if a.status == "done" && before == "working" { nowDone = true }
            }
            self.agentStatus = next
            self.agentsSeen = true
            guard self.feelAgents else { return }
            if nowWaiting { Log.write("agents: one needs you"); self.buzz(.knock) }
            else if nowDone { Log.write("agents: one finished"); self.buzz(.finished) }
        }
    }

    private func openRing() {
        ring.show(agents.latest)
        agents.fetch(details: true) { [weak self] list in self?.ring.update(list) }
    }

    // MARK: Haptics and extras

    /// Push the "feel" settings to wherever they take effect.
    func applyFeel() {
        dragger.snapEnabled = snapWindows
        if hapticsOn && hapticsAvailable { hid.setHapticLevel(hapticStrength) }
        feeler.configure(controls: feelHover, windows: feelEdges)
        if hapticsOn && hapticsAvailable && (feelHover || feelEdges) && accessibilityOK { feeler.start() } else { feeler.stop() }
    }

    func buzz(_ wave: Wave) {
        guard hapticsOn, hapticsAvailable else { return }
        hid.haptic(wave.rawValue)
    }

    /// The thumb wheel was rolled. Returns true if we used the movement.
    private func thumbWheel(_ delta: Double) -> Bool {
        let mode = action(.thumbWheel).kind
        let step: Double, pause: Double
        switch mode {
        case "wheelVolume": (step, pause) = (1.0, 0.0)
        case "wheelZoom": (step, pause) = (2.0, 0.05)
        case "wheelTabs": (step, pause) = (2.5, 0.12)
        case "wheelUndo": (step, pause) = (2.5, 0.10)
        case "wheelDesktops": (step, pause) = (4.0, 0.6)
        default: return false
        }
        let now = Date()
        if now.timeIntervalSince(wheelLast) > 0.35 { wheelAcc = 0 }
        wheelLast = now
        wheelAcc += delta
        guard abs(wheelAcc) >= step, now >= wheelReady else { return true }
        let forward = wheelAcc < 0
        wheelAcc = 0
        wheelReady = now.addingTimeInterval(pause)
        switch mode {
        case "wheelVolume": ActionRunner.media(forward ? 0 : 1)
        case "wheelZoom": ActionRunner.key(forward ? 24 : 27, .command)
        case "wheelTabs": ActionRunner.key(48, forward ? .control : [.control, .shift]); buzz(.tick)
        case "wheelUndo": ActionRunner.key(6, forward ? [.command, .shift] : .command); buzz(.tick)
        default: ActionRunner.key(forward ? 124 : 123, .control); buzz(.swipe)
        }
        return true
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
        if tap.isRunning { s.formUnion([.middle, .back, .forward, .gesture, .thumbPanel, .thumbWheel]) }
        if hidStatus == .connected && accessibilityOK { s.formUnion(cidForSlot.keys) }
        available = s
    }

    // MARK: Button handling

    private func press(_ slot: Slot, pulseOnly: Bool = false) {
        pulseSource = pulseOnly
        if slot == .gesture { gestureDown(); return }
        let a = action(slot)
        guard a.isDrag else { ActionRunner.run(a); return }
        if ring.isOpen {                // pressing the pad again picks from the ring
            ringPress = true
            return
        }
        dragStartMouse = CGEvent(source: nil)?.location ?? .zero
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
        guard action(slot).isDrag else { return }
        if ringPress { ringPress = false; ring.choose(); return }
        guard !stickyDrag else { return }
        if pulseSource {
            // A button that can't be held: carry the window until the next click.
            guard dragger.isDragging else { return }
            stickyDrag = true
            Log.write("drag: carrying until next click")
            return
        }
        // A quick press without moving is a tap, not a drag.
        let now = CGEvent(source: nil)?.location ?? dragStartMouse
        let moved = hypot(now.x - dragStartMouse.x, now.y - dragStartMouse.y)
        let quick = Date().timeIntervalSince(dragPressed) < 0.30 && moved < 6
        dragger.end(snap: !quick)
        if quick && ringOnTap && agentsAvailable { openRing() }
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
        buzz(.swipe)
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
        ring.close()
        feeler.stop()
        dragger.end()
        hid.releaseAll()
    }
}
