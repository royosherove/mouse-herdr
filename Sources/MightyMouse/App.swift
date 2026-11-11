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

        // Developer aid: draw the window to a PNG without touching the mouse.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], dark: args.contains("--dark"), slot: args.contains("--gesture") ? .gesture : .thumbPanel)
            NSApp.terminate(nil)
            return
        }

        // Only one copy should run.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
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
        let host = NSHostingView(rootView: ContentView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 1010, height: 690)
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
