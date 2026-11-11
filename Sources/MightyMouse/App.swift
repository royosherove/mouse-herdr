import AppKit
import SwiftUI

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            renderIcon(to: args[i + 1]); return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    @MainActor
    static func renderIcon(to path: String) {
        let r = ImageRenderer(content: IconView())
        r.scale = 1
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments

        // Developer aid: draw the agent ring to a PNG with sample or live agents.
        if let i = args.firstIndex(of: "--snapshot-ring"), i + 1 < args.count {
            let model = RingModel()
            var list: [AgentInfo] = []
            if args.contains("--live"), let hc = AgentWatcher.tool("hc") {
                let p = Process(); p.executableURL = URL(fileURLWithPath: hc); p.arguments = ["ls", "--json"]
                let out = Pipe(); p.standardOutput = out; try? p.run()
                list = AgentWatcher.parse(out.fileHandleForReading.readDataToEndOfFile())
            } else {
                let sample: [(String, String, String)] = [
                    ("blocked", "payments-api", "review"), ("blocked", "mobile-app", "2"), ("done", "docs-site", "1"),
                    ("working", "mightymouse", "1"), ("working", "search-index", "bench"), ("done", "infra", "deploy"),
                    ("idle", "playground", "3"), ("working", "web-client", "tests"),
                ]
                list = AgentWatcher.parse(try! JSONSerialization.data(withJSONObject: ["terminals": sample.enumerated().map { i, s in
                    ["address": "t\(i)", "agent": "claude-code", "status": s.0, "where": "\(s.1) / \(s.2)"]
                }]))
            }
            if args.contains("--live"), let hc = AgentWatcher.tool("hc") {
                list = list.map { a in
                    var a = a
                    let p = Process(); p.executableURL = URL(fileURLWithPath: hc); p.arguments = ["get", a.id, "--json"]
                    let out = Pipe(); p.standardOutput = out; try? p.run()
                    if let o = try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
                        a.title = o["title"] as? String ?? ""
                        a.message = (o["status"] as? [String: Any])?["msg"] as? String ?? ""
                        a.kind = (o["status"] as? [String: Any])?["kind"] as? String ?? ""
                    }
                    return a
                }
            } else if !list.isEmpty {
                list[0].kind = "question"
                list[0].message = "answer: Question 4: Refunds over $500 currently go through in one step. Finance flagged three cases last quarter where a refund was issued twice because the first attempt timed out and the agent retried it. A second approver would catch those, but it adds a delay of up to a day for customers in regions where the approver is offline, and support has asked that we do not slow down the common case. Should refunds over $500 need a second approver, or keep the single-step flow we have today? (Second approver (Recommended) · Keep single step · Decide per region)"
            }
            model.layout(list)
            model.highlighted = model.slices.first?.id
            if let s = model.slices.first {
                let big = args.contains("--expanded")
                let m = RingModel.bubbleMetrics(for: s.agent, expanded: big)
                let dx = CGFloat(cos(s.mid)), dy = CGFloat(sin(s.mid))
                let reach = s.outer + 54 + abs(dx) * m.size.width / 2 + abs(dy) * m.size.height / 2
                model.bubble = RingModel.Bubble(offset: CGSize(width: dx * reach, height: dy * reach), size: m.size,
                                                toward: CGSize(width: -dx, height: -dy), textHeight: m.textHeight, optionCount: m.options, expanded: big)
                model.hoveredOption = m.options > 1 ? 1 : nil
            }
            let view = ZStack { Color(white: 0.55); RingView(model: model) }.frame(width: RingView.side, height: RingView.side)
            let r = ImageRenderer(content: view)
            r.scale = 1.5
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            NSApp.terminate(nil)
            return
        }

        // Developer aid: draw the window to a PNG without touching the mouse.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], dark: args.contains("--dark"), slot: args.contains("--gesture") ? .gesture : .thumbPanel)
            NSApp.terminate(nil)
            return
        }

        // Developer aid: ask the running copy to play a haptic waveform.
        if let i = args.firstIndex(of: "--buzz"), i + 1 < args.count {
            DistributedNotificationCenter.default().postNotificationName(
                .init("MightyMouse.buzz"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MightyMouse.buzz"), object: nil, queue: .main
        ) { [weak self] note in
            if let s = note.object as? String, let id = UInt8(s) { self?.state.hid.haptic(id) }
        }

        // Developer aid: ask the running copy to jump to an agent, as the ring would.
        if let i = args.firstIndex(of: "--focus"), i + 1 < args.count {
            DistributedNotificationCenter.default().postNotificationName(
                .init("MightyMouse.focus"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MightyMouse.focus"), object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.state.agents.focus(AgentInfo(id: id, agent: "", status: "", space: "test", tab: ""))
        }

        // Only one copy should run (an older copy that is still shutting down doesn't count).
        if let id = Bundle.main.bundleIdentifier {
            func others() -> [NSRunningApplication] {
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            }
            var tries = 0
            while !others().isEmpty && tries < 8 { usleep(250_000); tries += 1 }
            if !others().isEmpty {
                DistributedNotificationCenter.default().post(name: .init("MightyMouse.show"), object: nil)
                NSApp.terminate(nil)
                return
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MightyMouse.show"), object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow() }

        Log.write("---- MightyMouse started ----")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        state.start()

        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let needsSetup = !state.accessibilityOK || !state.inputMonitoringOK
        if !launchedAtLogin || needsSetup || args.contains("--show") { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ note: Notification) {
        if statusItem != nil { state.shutdown() }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "MightyMouse")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open MightyMouse…", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MightyMouse", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Window

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1010, height: 690),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "MightyMouse"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ContentView(state: state))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ note: Notification) {
        state.recording = false
        // Keep working quietly from the menu bar.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Snapshot

    private func snapshot(to path: String, dark: Bool, slot: Slot) {
        state.deviceName = "MX Master 4"
        state.hidStatus = .connected
        state.battery = 85
        state.accessibilityOK = !CommandLine.arguments.contains("--needs-setup")
        state.inputMonitoringOK = state.accessibilityOK
        state.launchAtLogin = true
        state.available = Set(Slot.buttons)
        state.selected = slot
        state.hapticsAvailable = true
        let extras = CommandLine.arguments.contains("--extras")
        if CommandLine.arguments.contains("--wheel") { state.selected = .thumbWheel }
        let host: NSView = extras
            ? NSHostingView(rootView: ExtrasView(state: state))
            : NSHostingView(rootView: ContentView(state: state))
        host.frame = extras ? NSRect(origin: .zero, size: host.fittingSize) : NSRect(x: 0, y: 0, width: 1010, height: 690)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
