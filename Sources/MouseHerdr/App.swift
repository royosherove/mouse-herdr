import AppKit
import Combine
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
    private var updateMenuItem: NSMenuItem?
    private var updateWatch: AnyCancellable?
    private var whatsNewWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments

        // Developer aid: say what the Herdr check finds, using the same code as the running app.
        // MOUSEHERDR_HC and MOUSEHERDR_HERDR_APP point it at other (or missing) commands.
        if args.contains("--herdr-status") {
            let started = Date()
            let found = AgentWatcher.look(details: .none)
            print("herdr-core: \(found.status.summary)")
            print("Herdr app: \(AgentWatcher.herdrAppInstalled() ? "installed" : "not installed")")
            print(String(format: "took %.1f seconds", Date().timeIntervalSince(started)))
            exit(0)
        }

        // Developer aid: which copy this is, the way the window says it.
        if args.contains("--version") {
            print(AppVersion.sentence())
            exit(0)
        }

        // Developer aid: the mice MouseHerdr recognises, one per line.
        if args.contains("--list-mice") {
            for p in MouseProfile.all + MouseProfile.fallbacks { print("\(p.id)\t\(p.brand)\t\(p.name)") }
            exit(0)
        }

        // Developer aid: which profile a device with this vendor:product id (in hexadecimal) and name
        // would get. "--buttons N" says how many buttons it declares, which decides the layout of a
        // mouse that is not in the list.
        if let i = args.firstIndex(of: "--identify") {
            let ids = i + 1 < args.count ? args[i + 1].split(separator: ":").map { Int($0, radix: 16) } : []
            guard ids.count == 2, let vendor = ids[0], let product = ids[1] else {
                print("use --identify <vendor>:<product> [name], with the ids in hexadecimal, such as 045e:00cb")
                exit(2)
            }
            var device = MouseDevice(vendorID: vendor, productID: product)
            if i + 2 < args.count, !args[i + 2].hasPrefix("--") { device.name = args[i + 2] }
            if let j = args.firstIndex(of: "--buttons"), j + 1 < args.count { device.buttons = Int(args[j + 1]) ?? 0 }
            print(AppDelegate.describe(device))
            exit(0)
        }

        // Developer aid: the mice connected to this Mac right now and the one MouseHerdr would follow,
        // using the same code as the running app. It reads what the devices say about themselves and
        // opens none of them. "--watch N" keeps looking for N seconds and reports each change.
        if args.contains("--detect-mice") {
            func report(_ devices: [MouseDevice]) {
                let list = MouseChooser.candidates(devices)
                let followed = MouseChooser.active(among: list, pinned: nil)
                print(list.isEmpty ? "No mouse found." : "Mice connected:")
                for d in list {
                    print("\(d.key == followed?.key ? "*" : " ") \(AppDelegate.describe(d)) [\(d.key), \(d.connection), \(d.buttons) buttons, calls itself \"\(d.name)\"]")
                }
                let ignored = Set(devices.filter { $0.kind == .ignored }.map(\.name)).sorted()
                if !ignored.isEmpty { print("Not counted as mice: " + ignored.joined(separator: ", ")) }
                if let followed {
                    let profile = MouseChooser.profile(for: followed, memory: MouseMemory(), firstRun: true)
                    print("MouseHerdr would follow: \(MouseSetup.title(device: followed, profile: profile))")
                }
                fflush(stdout)
            }
            if let j = args.firstIndex(of: "--watch"), j + 1 < args.count, let seconds = Double(args[j + 1]) {
                print("Watching for \(Int(seconds)) seconds. Connect or disconnect a mouse.\n")
                let detector = MouseDetector()
                detector.onChange = { report($0); print(""); fflush(stdout) }
                detector.start()
                // Keep the detector until the wait is over; nothing else refers to it.
                withExtendedLifetime(detector) {
                    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                }
            } else {
                report(MouseDetector.connected())
            }
            exit(0)
        }

        // Developer aid: draw every mouse in the list on one sheet, to check the drawings.
        if let i = args.firstIndex(of: "--snapshot-mice"), i + 1 < args.count {
            let dark = args.contains("--dark")
            let sheet = MouseSheet()
                .background(dark ? Color(red: 0.11, green: 0.11, blue: 0.13) : Color(red: 0.97, green: 0.95, blue: 0.93))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: sheet)
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            NSApp.terminate(nil)
            return
        }

        // Developer aid: `--state not-installed|not-running|empty|unknown` and `--no-app` force
        // what the snapshots below believe about Herdr.
        var forced: HerdrStatus?
        if let i = args.firstIndex(of: "--state"), i + 1 < args.count {
            guard let s = HerdrStatus(flag: args[i + 1]) else {
                print("unknown --state \(args[i + 1]); use not-installed, not-running, empty or unknown")
                exit(2)
            }
            forced = s
        }

        // Developer aid: draw the agent ring to a PNG with sample or live agents.
        if let i = args.firstIndex(of: "--snapshot-ring"), i + 1 < args.count {
            let model = RingModel()
            model.canJump = !args.contains("--no-app")
            // A picture shows the wheel as it is once it has looked; "--unchecked" shows the moment before.
            model.confirmed = !args.contains("--unchecked")
            // "--order space|recent" picks how the wedges are ordered.
            if let j = args.firstIndex(of: "--order"), j + 1 < args.count {
                guard let order = RingOrder(rawValue: args[j + 1]) else {
                    print("unknown --order \(args[j + 1]); use space or recent")
                    exit(2)
                }
                model.order = order
            }
            // "--pin t3,t5" pins those agents.
            if let j = args.firstIndex(of: "--pin"), j + 1 < args.count {
                model.pinned = Set(args[j + 1].components(separatedBy: ","))
            }
            var list: [AgentInfo] = []
            if let forced {
                model.herdr = forced
            } else if args.contains("--live"), let hc = AgentWatcher.tool("hc") {
                let p = Process(); p.executableURL = URL(fileURLWithPath: hc); p.arguments = ["ls", "--json"]
                let out = Pipe(); p.standardOutput = out; try? p.run()
                list = AgentWatcher.parse(out.fileHandleForReading.readDataToEndOfFile())
            } else {
                // Status, space, tab, and how many minutes ago it was last active.
                let sample: [(String, String, String, Double)] = [
                    ("blocked", "payments-api", "review", 0), ("blocked", "mobile-app", "2", 0), ("done", "docs-site", "1", 3),
                    ("working", "mouseherdr", "1", 0), ("working", "search-index", "bench", 0), ("done", "infra", "deploy", 50),
                    ("idle", "playground", "3", 600), ("working", "web-client", "tests", 0), ("done", "mouseherdr", "2", 20),
                ]
                list = AgentWatcher.parse(try! JSONSerialization.data(withJSONObject: ["terminals": sample.enumerated().map { i, s in
                    ["address": "t\(i)", "agent": "claude-code", "status": s.0, "where": "\(s.1) / \(s.2)"]
                }]))
                let now = Date()
                list = list.map { a in
                    var a = a
                    if let i = Int(a.id.dropFirst()) { a.lastActive = now.addingTimeInterval(-sample[i].3 * 60) }
                    if a.space == "mouseherdr" { a.title = a.tab == "1" ? "Group sessions by space" : "Release notes" }
                    if a.id == "t4" { a.helpers = 3 }
                    return a
                }
            }
            if forced != nil {
                // Nothing to fill in: these states have no agents.
            } else if args.contains("--live"), let hc = AgentWatcher.tool("hc") {
                list = list.map { a in
                    var a = a
                    let p = Process(); p.executableURL = URL(fileURLWithPath: hc); p.arguments = ["get", a.id, "--json"]
                    let out = Pipe(); p.standardOutput = out; try? p.run()
                    if let o = try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any] {
                        a.title = o["title"] as? String ?? ""
                        a.lastActive = AgentWatcher.lastActive(o)
                        a.inner = AgentWatcher.busyRecords(o)
                        a.message = (o["status"] as? [String: Any])?["msg"] as? String ?? ""
                        a.kind = (o["status"] as? [String: Any])?["kind"] as? String ?? ""
                        if a.needsYou { a.typeOption = 4 }
                    }
                    return a
                }
            } else if !list.isEmpty {
                list[0].kind = "question"
                let sampleScreen = """
                ❯ 1. Second approver (Recommended)
                     A second person confirms every refund over $500 before it is sent. Catches duplicate refunds,
                     but customers may wait up to a day.
                  2. Keep single step
                     No change. Fastest for customers; duplicates are still possible when a request times out.
                  3. Decide per region
                     Each region picks its own rule.
                  4. Type something.
                ────────
                  5. Chat about this
                """
                let dialog = AgentWatcher.parseDialog(sampleScreen)
                list[0].hints = dialog.hints
                list[0].typeOption = dialog.typeOption
                if args.contains("--short") {
                    // The one-line version of the question, so the whole bubble fits in the picture.
                    list[0].kind = "question"
                    list[0].message = AppDelegate.sampleAgents[0].message
                } else {
                    list[0].message = "answer: Question 4: Refunds over $500 currently go through in one step. Finance flagged three cases last quarter where a refund was issued twice because the first attempt timed out and the agent retried it. A second approver would catch those, but it adds a delay of up to a day for customers in regions where the approver is offline, and support has asked that we do not slow down the common case. Should refunds over $500 need a second approver, or keep the single-step flow we have today? (Second approver (Recommended) · Keep single step · Decide per region)"
                }
                // "--permission" shows a request to approve a risky command instead of a question.
                if args.contains("--permission") {
                    list[0] = AppDelegate.sampleAgents[1]
                }
            }
            if forced == nil { model.herdr = .running(agents: list.count) }
            model.layout(list)
            model.highlighted = model.slices.first?.id
            if args.contains("--clicked"), !model.canJump {
                // What a click on a wedge leaves behind when the Herdr app is missing.
                model.slices = []
                model.bands = []
                model.highlighted = nil
                model.notice = .noApp
            } else if args.contains("--plain") {
                model.highlighted = model.slices.dropFirst(2).first?.id
            } else {
                // "--highlight N|none", "--hover N|none" and "--sent N" pose the wheel for pictures.
                func value(_ flag: String) -> String? {
                    guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
                    return args[j + 1]
                }
                let pick = value("--highlight")
                // "--hub" shows the wheel as it opens: the pointer on the hub, aiming at the hub's agent.
                let onHub = args.contains("--hub")
                let slice = onHub ? model.slices.first { $0.id == model.centre }
                    : pick == "none" ? nil : model.slices.dropFirst(Int(pick ?? "0") ?? 0).first
                model.onHub = onHub && slice != nil
                model.highlighted = slice?.id
                if let s = slice, !args.contains("--no-bubble") {
                    let big = args.contains("--expanded")
                    let m = RingModel.bubbleMetrics(for: s.agent, expanded: big)
                    let dx = CGFloat(cos(s.mid)), dy = CGFloat(sin(s.mid))
                    let reach = s.reach + 54 + abs(dx) * m.size.width / 2 + abs(dy) * m.size.height / 2
                    model.bubble = RingModel.Bubble(offset: CGSize(width: dx * reach, height: dy * reach), size: m.size,
                                                    toward: CGSize(width: -dx, height: -dy), textHeight: m.textHeight, optionCount: m.options, expanded: big)
                    let hover = value("--hover")
                    model.hoveredOption = hover == "none" ? nil : (hover.flatMap { Int($0) } ?? (m.options > 1 ? 1 : nil))
                    // "--sent N" shows an answer that has gone in; "--sending N" one still on its way
                    // (with "--held", held back by herdr-core, or with "--leaving", in a wheel that
                    // was asked to close meanwhile); "--failed N" one that could not be sent.
                    if let n = value("--sent").flatMap({ Int($0) }) {
                        model.sentOption = n
                        model.delivery = .delivered(late: false)
                    } else if let n = value("--sending").flatMap({ Int($0) }) {
                        model.sentOption = n
                        model.held = args.contains("--held")
                        model.leaving = args.contains("--leaving")
                    } else if let n = value("--failed").flatMap({ Int($0) }) {
                        model.sentOption = n
                        model.delivery = .failed
                    }
                    // "--layout" prints where things are (points from the picture's top-left), for animating over it.
                    if args.contains("--layout"), let b = model.bubble {
                        let c = RingView.side / 2
                        let origin = CGPoint(x: c + b.offset.width - b.size.width / 2, y: c + b.offset.height - b.size.height / 2)
                        print("canvas \(Int(RingView.side)) bubble \(Int(origin.x)),\(Int(origin.y)) \(Int(b.size.width))x\(Int(b.size.height))")
                        for k in 0..<b.optionCount {
                            let r = RingModel.optionRect(k, in: b)
                            print("option \(k) centre \(Int(origin.x + r.midX)),\(Int(origin.y + r.midY))")
                        }
                        for sl in model.slices {
                            let rad = (sl.inner + sl.outer) / 2
                            print("slice \(sl.agent.space) centre \(Int(c + CGFloat(cos(sl.mid)) * rad)),\(Int(c + CGFloat(sin(sl.mid)) * rad)) outer \(Int(sl.outer))")
                        }
                    }
                }
            }
            // "--clear" leaves the background transparent, for laying the wheel over other artwork.
            let backdrop = args.contains("--clear") ? Color.clear : Color(white: 0.55)
            let view = ZStack { backdrop; RingView(model: model) }.frame(width: RingView.side, height: RingView.side)
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
            // "--profile generic" draws another mouse's profile instead of the MX Master 4.
            if let j = args.firstIndex(of: "--profile"), j + 1 < args.count {
                guard let profile = MouseProfile.named(args[j + 1]) else {
                    print("unknown profile \(args[j + 1]); --list-mice prints the ones there are")
                    NSApp.terminate(nil)
                    return
                }
                state.use(profile)
            } else {
                // Pictures show the MX Master 4 unless told otherwise, whatever mouse this Mac used last.
                state.use(.mxMaster4)
            }
            if forced != nil || args.contains("--no-app") {
                state.agents.pinned = (forced ?? .running(agents: 3), !args.contains("--no-app"))
                state.herdr = state.agents.status
                state.herdrApp = state.agents.appInstalled
            }
            snapshot(to: args[i + 1], dark: args.contains("--dark"), slot: args.contains("--gesture") ? .gesture : nil)
            NSApp.terminate(nil)
            return
        }

        // Developer aid: ask the running copy to play a haptic waveform.
        if let i = args.firstIndex(of: "--buzz"), i + 1 < args.count {
            DistributedNotificationCenter.default().postNotificationName(
                .init("MouseHerdr.buzz"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MouseHerdr.buzz"), object: nil, queue: .main
        ) { [weak self] note in
            if let s = note.object as? String, let id = UInt8(s) { self?.state.hid.haptic(id) }
        }

        // Developer aid: ask the running copy to jump to an agent, as the ring would.
        if let i = args.firstIndex(of: "--focus"), i + 1 < args.count {
            DistributedNotificationCenter.default().postNotificationName(
                .init("MouseHerdr.focus"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MouseHerdr.focus"), object: nil, queue: .main
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
                DistributedNotificationCenter.default().post(name: .init("MouseHerdr.show"), object: nil)
                NSApp.terminate(nil)
                return
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("MouseHerdr.show"), object: nil, queue: .main
        ) { [weak self] _ in self?.showWindow() }

        Log.write("---- MouseHerdr started ----")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        state.openWindow = { [weak self] in self?.showWindow() }
        state.start()
        state.updates.showWhatsNew = { [weak self] in self?.showWhatsNew() }
        state.updates.start()
        updateWatch = state.updates.$phase.combineLatest(state.updates.$canCheck)
            .receive(on: DispatchQueue.main).sink { [weak self] phase, canCheck in
                guard let self else { return }
                self.updateMenuItem?.title = phase.menuTitle(for: self.state.updates.kind)
                self.updateMenuItem?.isEnabled = phase.ready || canCheck
            }
        // A newly found mouse is pointed out under the menu bar icon while the window is closed.
        noticeWatch = state.$mouseNotice.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.showMouseNotice() }

        // Start quietly in the menu bar. The window opens by itself only the first time,
        // or when a permission still needs granting.
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: "didFirstRun")
        if args.contains("--settings") { state.tab = .settings }
        let updated = ReleaseHistory(defaults: defaults).recordLaunch(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            previouslyUsedApp: !firstRun)
        if firstRun || !state.accessibilityOK || args.contains("--show") {
            defaults.set(true, forKey: "didFirstRun")
            showWindow()
        } else if !defaults.bool(forKey: "didExplainMenuBar") {
            // The first quiet start: point out where the app went, once.
            defaults.set(true, forKey: "didExplainMenuBar")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.explainMenuBar() }
        }
        if updated {
            DispatchQueue.main.async { [weak self] in self?.showWhatsNew() }
        }
    }

    private var notice: NSPopover?
    private var mousePopover: NSPopover?
    private var noticeWatch: AnyCancellable?

    /// Show what there is to say about a newly found mouse under the menu bar icon, unless the
    /// window is open: there it is a banner. It closes when the notice is answered.
    private func showMouseNotice() {
        mousePopover?.close()
        mousePopover = nil
        guard let found = state.mouseNotice, !state.windowVisible, let button = statusItem?.button else { return }
        // One thing at a time under the icon: wait for the "MouseHerdr is running" note to go.
        guard notice == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showMouseNotice() }
            return
        }
        let pop = NSPopover()
        pop.behavior = .applicationDefined
        pop.contentViewController = NSHostingController(rootView: MouseNoticePopover(notice: found) { [weak self] primary in
            self?.state.answerNotice(primary: primary)
        })
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        mousePopover = pop
        // Left alone, it steps aside; the notice then waits in the window. Having been up this
        // long it counts as seen, so it does not come back under the icon another day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self, weak pop] in
            guard let self, let pop, self.mousePopover === pop else { return }
            pop.close()
            self.mousePopover = nil
            self.state.noticeSeen()
        }
    }

    private func explainMenuBar() {
        // A mouse notice under the icon already shows where the app lives.
        guard mousePopover == nil, let button = statusItem?.button else { return }
        let pop = NSPopover()
        pop.behavior = .applicationDefined
        pop.contentViewController = NSHostingController(rootView: MenuBarNotice { [weak self] in
            self?.notice?.close()
            self?.notice = nil
        })
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        notice = pop
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.notice?.close()
            self?.notice = nil
        }
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
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "MouseHerdr")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Open MouseHerdr…", action: #selector(showWindow), keyEquivalent: "").target = self
        // The way to the wheel on a mouse with no spare button, such as a Magic Mouse.
        menu.addItem(withTitle: "Show Agent Wheel", action: #selector(showWheel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(updateApp), keyEquivalent: "")
        update.target = self
        update.isEnabled = false
        updateMenuItem = update
        menu.addItem(withTitle: "What’s New…", action: #selector(showWhatsNew), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MouseHerdr", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showSettings() { state.tab = .settings; showWindow() }

    @objc func updateApp() {
        if state.updates.phase.ready { state.updates.restartToUpdate() }
        else { state.updates.checkForUpdates() }
    }

    @objc func showWhatsNew() {
        if whatsNewWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "What’s New in MouseHerdr"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WhatsNewView { [weak w] in w?.close() })
            w.center()
            whatsNewWindow = w
        }
        whatsNewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWheel() {
        // Once the menu has closed, so the wheel opens around a pointer that is free to aim.
        DispatchQueue.main.async { [weak self] in self?.state.toggleWheel() }
    }

    // MARK: Window

    @objc func showWindow() {
        // In the window the notice is a banner.
        mousePopover?.close()
        mousePopover = nil
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1010, height: 690),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "MouseHerdr"
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
        state.windowVisible = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ note: Notification) {
        state.recording = false
        state.windowVisible = false
        // Keep working quietly from the menu bar.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Snapshot

    private func snapshot(to path: String, dark: Bool, slot: Slot?) {
        state.hidStatus = .connected
        state.battery = 85
        state.accessibilityOK = !CommandLine.arguments.contains("--needs-setup")
        state.inputMonitoringOK = state.accessibilityOK
        state.launchAtLogin = true
        state.available = Set(state.profile.controls.map { $0.slot })
        state.hapticsAvailable = state.profile.hasHaptics
        // "--tab agents|buttons|feel|settings" picks the page; snapshots never start the updater.
        let argv = CommandLine.arguments
        if argv.contains("--update-ready") { state.updates.poseReadyUpdate() }
        if let j = argv.firstIndex(of: "--tab"), j + 1 < argv.count, let t = AppState.Tab(rawValue: argv[j + 1]) { state.tab = t }
        if argv.contains("--wheel") || argv.contains("--gesture") || argv.contains("--profile") { state.tab = .buttons }
        // A made-up device of the profile's own kind, so the window says how it is "connected".
        // "--no-mouse" shows the window with nothing connected.
        let p = state.profile
        var device = MouseDevice(vendorID: p.vendorIDs.sorted().first ?? 0, productID: p.productIDs.sorted().first ?? 0,
                                 name: p.fullName, transport: p.usesDirectLink || p.brand == "Apple" ? "Bluetooth Low Energy" : "USB", buttons: 5)
        if p.kind == .receiver { device.name = "USB Receiver" }
        if p.kind == .fallback { device.name = "2.4G Wireless Mouse" }
        // "--picker" shows the list of mice beside the picture, with two more mice connected; "--search text" narrows it.
        let picking = argv.contains("--picker")
        let others = picking ? [MouseDevice(vendorID: 0x045E, productID: 0x00CB, name: "Microsoft USB Optical Mouse", transport: "USB", buttons: 3),
                                MouseDevice(vendorID: 0x046D, productID: 0xC52B, name: "USB Receiver", transport: "USB", buttons: 16)] : []
        // Not the same mouse twice, should the profile being drawn be one of the two.
        state.pose(p, as: argv.contains("--no-mouse") ? nil : device,
                   among: others.filter { $0.key != device.key && $0.recognised?.id != p.id })
        if picking {
            state.tab = .buttons
            state.choosingMouse = true
            if let j = argv.firstIndex(of: "--search"), j + 1 < argv.count { state.mouseSearch = argv[j + 1] }
        }
        // "--notice" shows what is said when this mouse is found for the first time.
        if argv.contains("--notice"), state.accessibilityOK {
            state.mouseNotice = MouseSetup.notice(for: device, profile: p, triggers: state.wheelTriggers)
        }
        if state.agents.pinned == nil {
            // Pinning keeps the picture from asking the real Herdr anything.
            state.agents.pinned = (.running(agents: Self.sampleAgents.count), true)
            state.herdr = state.agents.status
            state.agentList = Self.sampleAgents
        }
        // Only select what this mouse has.
        let wanted = CommandLine.arguments.contains("--wheel") ? .thumbWheel : slot ?? state.profile.firstSelected
        if state.profile.control(wanted) != nil { state.selected = wanted }
        let whatsNew = argv.contains("--whats-new")
        let host: NSView = whatsNew ? NSHostingView(rootView: WhatsNewView(close: {}))
            : NSHostingView(rootView: ContentView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: whatsNew ? 560 : 1010, height: whatsNew ? 490 : 690)
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

extension AppDelegate {
    /// One line on what MouseHerdr makes of a device: the profile it would get and why.
    static func describe(_ device: MouseDevice) -> String {
        guard device.kind != .ignored else { return "ignored: \(device.name) is not a mouse" }
        let profile = MouseChooser.profile(for: device, memory: MouseMemory(), firstRun: true)
        let how: String
        switch profile.kind {
        case .mouse: how = profile.tested ? "recognised, tested" : "recognised"
        case .receiver: how = "receiver, mouse model unknown"
        case .fallback: how = "not in the list"
        }
        return "\(profile.id): \(MouseSetup.title(device: device, profile: profile)) (\(how))"
    }

    /// Made-up agents for screenshots, so no real session ever ends up in a picture.
    static let sampleAgents: [AgentInfo] = {
        let rows: [(String, String, String)] = [
            ("blocked", "payments-api", "review"), ("blocked", "mobile-app", "2"), ("done", "docs-site", "1"),
            ("working", "mouseherdr", "1"), ("working", "search-index", "bench"), ("idle", "playground", "3"),
        ]
        var list = AgentWatcher.parse(try! JSONSerialization.data(withJSONObject: ["terminals": rows.enumerated().map { i, r in
            ["address": "t\(i)", "agent": "claude-code", "status": r.0, "where": "\(r.1) / \(r.2)"]
        }]))
        if list.count > 1 {
            list[0].kind = "question"
            list[0].message = "answer: Should refunds over $500 need a second approver, or keep the single-step flow we have today? (Second approver (Recommended) · Keep single step · Decide per region)"
            // A request to approve a risky command, as an agent reports it.
            list[1].kind = "permission"
            list[1].message = "approve Bash: psql $STAGING_URL -f migrations/0042_drop_legacy_orders.sql"
            let dialog = AgentWatcher.parseDialog("""
             Do you want to proceed?
             ❯ 1. Yes
               2. Yes, and don't ask again for psql commands in this project
               3. No
             Esc to cancel · Tab to amend
            """)
            list[1].screenOptions = dialog.options
            list[1].prompt = dialog.prompt
            list[1].hints = [2: "Yes, and don't ask again for psql commands in this project"]
        }
        return list
    }()
}

/// Shown once, the first time the app starts without opening its window.
struct MenuBarNotice: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "computermouse.fill").font(.system(size: 18)).foregroundStyle(Palette.accent)
                Text("MouseHerdr is running").font(.system(size: 14, weight: .bold, design: .rounded))
            }
            Text("It now starts quietly and lives here in the menu bar. Click this mouse icon to see your agents or change what your buttons do.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it", action: dismiss).buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}
