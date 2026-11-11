import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var showExtras = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if setupShowing {
                    permissions.padding(.horizontal, 24).padding(.top, 4)
                }
                Spacer(minLength: 0)
                MouseView(state: state)
                    .scaleEffect(setupShowing ? 0.84 : 1)
                    .frame(width: MouseArt.size.width * (setupShowing ? 0.84 : 1),
                           height: MouseArt.size.height * (setupShowing ? 0.84 : 1))
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backdrop)

            Divider()
            DetailPanel(state: state)
                .frame(width: 310)
                .background(.regularMaterial)
        }
        .frame(width: 1010, height: 690)
    }

    private var setupShowing: Bool { !state.accessibilityOK || state.needsRelaunch || state.hidStatus != .connected }

    private var backdrop: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.13, green: 0.13, blue: 0.16), Color(red: 0.08, green: 0.08, blue: 0.10)]
                : [Color(red: 0.99, green: 0.96, blue: 0.93), Color(red: 0.93, green: 0.94, blue: 0.98)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MightyMouse").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Pick a button, then choose what it does.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    }

    private var statusPill: some View {
        let connected = state.hidStatus == .connected
        let text: String = !state.accessibilityOK ? "Needs permission"
            : connected ? (state.deviceName ?? "Mouse connected") : "Ready"
        return HStack(spacing: 7) {
            Circle().fill(state.accessibilityOK ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12, weight: .medium))
            if connected, let b = state.battery {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: state.charging ? "battery.100.bolt" : batterySymbol(b))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("\(b)%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func batterySymbol(_ p: Int) -> String {
        p > 80 ? "battery.100" : p > 55 ? "battery.75" : p > 30 ? "battery.50" : p > 10 ? "battery.25" : "battery.0"
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.needsRelaunch ? "One more step" : state.accessibilityOK ? "One more permission for hold-to-drag" : "Two quick permissions and you're set")
                .font(.system(size: 13, weight: .semibold))
            if state.needsRelaunch {
                HStack {
                    Text("macOS needs MightyMouse to restart before the new permission takes effect.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart MightyMouse") { state.relaunch() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                }
            } else {
                permissionRow(
                    ok: state.accessibilityOK, title: "Accessibility",
                    why: "Lets MightyMouse press shortcuts and move windows for you.",
                    action: state.requestAccessibility)
                permissionRow(
                    ok: state.inputMonitoringOK, title: "Input Monitoring",
                    why: "Lets MightyMouse feel when the haptic panel and top button are held and released. If MightyMouse isn't in the list, click + there and pick it from Applications.",
                    action: state.requestInputMonitoring)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.accent.opacity(0.35), lineWidth: 1))
    }

    private func permissionRow(ok: Bool, title: String, why: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16)).foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ok {
                Text("Allowed").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action).buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.small)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("Start MightyMouse when I log in", isOn: Binding(
                get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.system(size: 12))
            Spacer()
            Button { showExtras.toggle() } label: {
                Label("Haptics & extras", systemImage: "sparkles").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .popover(isPresented: $showExtras, arrowEdge: .top) { ExtrasView(state: state) }
            Button("Reset to defaults") { state.resetAll() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 6)
    }
}

// MARK: - Right-hand panel

struct DetailPanel: View {
    @ObservedObject var state: AppState

    private var slot: Slot { state.editing }
    private var current: Action { state.action(slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.selected.title).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(state.selected.blurb).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.available.contains(state.selected) {
                    Label(unavailableText, systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    if state.selected == .modeShift && state.accessibilityOK && state.hidStatus != .connected {
                        Button("Open Input Monitoring settings…") { state.requestInputMonitoring() }
                            .controlSize(.small).padding(.top, 2)
                    }
                }
                if state.selected == .gesture {
                    Picker("", selection: $state.gesturePart) {
                        ForEach(Slot.gestureParts) { p in Text(p.partLabel).tag(p) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.top, 6)
                    if slot.isSwipe {
                        Text(slot.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 12)

            Divider()

            ScrollView {
                if slot == .thumbWheel {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionTitle("When rolled")
                        ForEach(Catalog.wheelModes) { p in
                            row(title: p.title, symbol: p.symbol, selected: current.kind == p.id) {
                                state.assign(Action(kind: p.id), to: slot)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 12)
                } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Catalog.groups) { group in
                        let presets = group.presets.filter(allowed)
                        if !presets.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                sectionTitle(group.title)
                                ForEach(presets) { p in
                                    row(title: p.title, symbol: p.symbol, selected: current.kind == p.id) {
                                        state.recording = false
                                        state.assign(Action(kind: p.id), to: slot)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        sectionTitle("Your own")
                        row(title: shortcutTitle, symbol: "keyboard", selected: current.kind == "shortcut" || state.recording) {
                            state.beginRecording()
                        }
                        row(title: current.kind == "app" ? Catalog.title(current) : "Open an app…", symbol: "app.badge",
                            selected: current.kind == "app") {
                            state.recording = false
                            state.chooseApp()
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
                }
            }
        }
    }

    private var unavailableText: String {
        if !state.accessibilityOK { return "Works once Accessibility is allowed (see the left side)." }
        if state.hidStatus != .connected {
            return "This one button also needs Input Monitoring. In the settings list, switch MightyMouse on — if it isn't listed, click + and pick MightyMouse from Applications."
        }
        return "Your mouse didn't report this button, so it can't be changed."
    }

    private var shortcutTitle: String {
        if state.recording { return "Press the keys now… (Esc to cancel)" }
        if current.kind == "shortcut" { return "Shortcut: \(current.label ?? "")" }
        return "Keyboard shortcut…"
    }

    /// Which presets make sense for the slot being edited.
    private func allowed(_ p: Preset) -> Bool {
        switch p.id {
        case "default": return !slot.isSwipe
        case "dragWindow": return !Slot.gestureParts.contains(slot)
        case "middleClick": return slot != .middle
        default: return true
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.bottom, 3)
    }

    private func row(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Palette.accent : .secondary)
                    .frame(width: 22)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6.5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Haptics & extras

struct ExtrasView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Haptics & extras").font(.system(size: 15, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Haptic feedback", isOn: $state.hapticsOn).font(.system(size: 13, weight: .medium))
                Text("A small bump in the thumb pad when a dragged window reaches a snap edge or you finish a gesture.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("", selection: $state.hapticStrength) {
                        Text("Soft").tag(30); Text("Medium").tag(60); Text("Strong").tag(100)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Button("Try") { state.buzz(.hello) }
                }
                .disabled(!state.hapticsOn)
                if !state.hapticsAvailable {
                    Label("Needs the mouse connected with Input Monitoring allowed.", systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Feel buttons and links under the cursor", isOn: $state.feelHover)
                    .font(.system(size: 13, weight: .medium)).disabled(!state.hapticsOn)
                Text("A faint tick as the pointer lands on something clickable — buttons, links, menu and Dock items.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Feel window edges", isOn: $state.feelEdges)
                    .font(.system(size: 13, weight: .medium)).disabled(!state.hapticsOn)
                Text("A soft bump each time the pointer crosses into or out of a window.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Snap windows at screen edges", isOn: $state.snapWindows).font(.system(size: 13, weight: .medium))
                Text("While dragging with the haptic panel, push into the left or right edge for half the screen, the top for full screen, or a corner for a quarter.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(18)
        .frame(width: 340)
    }
}

// MARK: - App icon artwork

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.62, blue: 0.36), Color(red: 0.98, green: 0.33, blue: 0.38)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            ZStack(alignment: .topLeading) {
                MouseArt.wing.fill(Color.white.opacity(0.78))
                MouseArt.body.fill(Color.white)
                MouseArt.seams.stroke(Color(red: 0.98, green: 0.4, blue: 0.36).opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Capsule().fill(Color(red: 0.98, green: 0.4, blue: 0.36))
                    .frame(width: MouseArt.wheel.width, height: MouseArt.wheel.height)
                    .position(x: MouseArt.wheel.midX, y: MouseArt.wheel.midY)
            }
            .frame(width: MouseArt.size.width, height: MouseArt.size.height)
            .offset(x: 12, y: -6)
            .scaleEffect(1.32)
        }
        .frame(width: 1024, height: 1024)
    }
}
