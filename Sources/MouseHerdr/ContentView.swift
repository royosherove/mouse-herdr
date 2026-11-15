import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if noticeShowing, let notice = state.mouseNotice {
                    MouseNoticeBanner(notice: notice) { state.answerNotice(primary: $0) }
                        .padding(.horizontal, 24).padding(.top, 4)
                } else if setupShowing {
                    permissions.padding(.horizontal, 24).padding(.top, 4)
                }
                switch state.tab {
                case .agents:
                    AgentsPage(state: state)
                case .buttons:
                    let scale: CGFloat = setupShowing || noticeShowing ? 0.84 : 1
                    Spacer(minLength: 0)
                    MouseView(state: state)
                        .scaleEffect(scale)
                        .frame(width: state.profile.art.size.width * scale,
                               height: state.profile.art.size.height * scale)
                        // The corner under the right-hand labels is empty on every mouse.
                        .overlay(alignment: .bottomTrailing) { MousePlate(state: state).padding(.trailing, 6 * scale) }
                    Spacer(minLength: 0)
                case .feel:
                    FeelPage(state: state)
                case .settings:
                    SettingsPage(state: state, updates: state.updates)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backdrop)

            Divider()
            Group {
                switch state.tab {
                case .agents: AgentSidePanel(state: state)
                case .buttons:
                    if state.choosingMouse { MousePickerPanel(state: state) } else { DetailPanel(state: state) }
                case .feel: HapticsSidePanel(state: state)
                case .settings: UpdateHelpPanel(kind: state.updates.kind)
                }
            }
            .frame(width: 310)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
        }
        .frame(width: 1010, height: 690)
    }

    /// A permission is missing. Input Monitoring only counts for a mouse the direct link can reach.
    private var setupShowing: Bool {
        if !state.accessibilityOK || state.needsRelaunch { return true }
        guard state.wantsDirectLink, state.hidStatus != .connected else { return false }
        // With the permission given and no mouse connected, there is nothing left to set up.
        return !(state.inputMonitoringOK && state.mouse == nil)
    }

    /// A newly found mouse is being pointed out. It takes the place of the optional permission until it is answered.
    private var noticeShowing: Bool { state.mouseNotice != nil && state.accessibilityOK && !state.needsRelaunch }

    private var backdrop: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.13, green: 0.13, blue: 0.16), Color(red: 0.08, green: 0.08, blue: 0.10)]
                : [Color(red: 0.99, green: 0.96, blue: 0.93), Color(red: 0.93, green: 0.94, blue: 0.98)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Header

    private var subtitle: String {
        switch state.tab {
        case .agents: return "See and answer your coding agents from the mouse."
        case .buttons: return "Pick a button, then choose what it does."
        case .feel: return "How the mouse talks back to your hand."
        case .settings: return "Keep MouseHerdr ready for your day."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("MouseHerdr").font(.system(size: 22, weight: .bold, design: .rounded))
                        // Which copy this is: the version, and for a build from a checkout, its commit.
                        if let version = AppVersion.label() {
                            Text(version).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .help(AppVersion.sentence())
                        }
                    }
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                statusPill
            }
            tabs
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.agents, "Agents", "circle.hexagongrid.fill")
            tabButton(.buttons, "Buttons", "computermouse.fill")
            tabButton(.feel, "Feel", "waveform")
            tabButton(.settings, "Settings", "gearshape.fill")
        }
        .padding(4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func tabButton(_ tab: AppState.Tab, _ title: String, _ symbol: String) -> some View {
        let on = state.tab == tab
        let waiting = tab == .agents ? state.agentList.filter { $0.needsYou }.count : 0
        return Button {
            state.recording = false
            state.choosingMouse = false
            state.tab = tab
            if tab == .agents { state.refreshAgentList() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                if waiting > 0 {
                    Text("\(waiting)").font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(on ? Color.white.opacity(0.28) : Palette.accent))
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }

    private var statusPill: some View {
        // The battery comes over the direct link, so it is only shown for the mouse on it.
        let connected = state.hidStatus == .connected && state.linkFollowed
        let text: String = !state.accessibilityOK ? "Needs permission"
            : state.mouse != nil ? state.mouseTitle : "No mouse connected"
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
            Text(state.needsRelaunch ? "One more step"
                 : state.accessibilityOK ? (state.profile.hasHaptics ? "One more permission for hold-to-drag" : "One more permission for this mouse's extra buttons")
                 : state.wantsDirectLink ? "Two quick permissions and you're set" : "One quick permission and you're set")
                .font(.system(size: 13, weight: .semibold))
            if state.needsRelaunch {
                HStack {
                    Text("macOS needs MouseHerdr to restart before the new permission takes effect.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart MouseHerdr") { state.relaunch() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                }
            } else {
                permissionRow(
                    ok: state.accessibilityOK, title: "Accessibility",
                    why: "Lets MouseHerdr press shortcuts and move windows for you.",
                    action: state.requestAccessibility)
                // Only a mouse the direct link can reach has a use for the second permission.
                if state.wantsDirectLink {
                    permissionRow(
                        ok: state.inputMonitoringOK, title: "Input Monitoring",
                        why: state.profile.directLinkWhy + " If MouseHerdr isn't in the list, click + there and pick it from Applications.",
                        action: state.requestInputMonitoring)
                }
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
            UpdateFooter(updates: state.updates)
            Spacer()
            if state.tab == .buttons {
                Button("Reset to defaults") { state.resetAll() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 6)
    }
}

// MARK: - Agents page

/// The first page: every agent, what it wants, and a way to answer it.
struct AgentsPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            steps
            HStack {
                Text("YOUR AGENTS").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
                Spacer()
                Text(state.herdr.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            if state.agentList.isEmpty {
                emptyCard
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(state.agentList) { agentRow($0) }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { state.refreshAgentList() }
    }

    // How the wheel works, in three steps, with a way to try it.
    private var steps: some View {
        HStack(alignment: .top, spacing: 10) {
            step("1", "hand.tap.fill", "Open the wheel",
                 state.wheelTriggers.first.map { "\($0) shows your agents around the pointer." }
                    ?? "Give a button the “Show the agent wheel” action, or use the button on the right.")
            step("2", "scope", "Aim at an agent",
                 "Agents waiting on you are orange and closest. Their question appears in a bubble.")
            step("3", "cursorarrow.click.2", "Answer or jump",
                 "Click an answer in the bubble, or click the wedge to open that agent in Herdr.")
        }
    }

    private func step(_ n: String, _ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(n).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 19, height: 19).background(Circle().fill(Palette.accent))
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // What to say when there is nothing to list.
    private var emptyCard: some View {
        let (symbol, title, text): (String, String, String) = {
            switch state.herdr {
            case .notInstalled:
                return ("shippingbox", "Herdr isn't installed",
                        "MouseHerdr shows the coding agents you run with Herdr. Get it at herdr.dev; it will be picked up here without a restart. Button mapping and haptics work without it.")
            case .notRunning:
                return ("moon.zzz", "herdr-core isn't running",
                        "Herdr is installed but didn't answer. Start it with “hc server start” and your agents will appear here.")
            case .unknown:
                return ("hourglass", "Looking for agents…", "Asking Herdr what is running.")
            case .running:
                return ("tray", "No agents found",
                        "Herdr is running, but no coding agents are. Start one in Herdr and it will show up here.")
            }
        }()
        return VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func symbol(for a: AgentInfo) -> String {
        switch a.status {
        case "working": return "gearshape.fill"
        case "blocked": return "hand.raised.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "done": return "checkmark.circle.fill"
        case "idle": return "moon.zzz.fill"
        default: return "terminal.fill"
        }
    }

    private func agentRow(_ a: AgentInfo) -> some View {
        let urgent = a.needsYou
        let speech = a.speech(full: true)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: a)).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(urgent ? Palette.accent : a.color).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.tab.isEmpty ? a.space : "\(a.space)  ·  \(a.tab)")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(urgent || a.title.isEmpty ? a.agent : a.title)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(a.statusWord.uppercased()).font(.system(size: 9.5, weight: .heavy)).kerning(0.4)
                    .foregroundStyle(urgent ? Color.white : a.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(urgent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(a.color.opacity(0.14))))
                Button { state.togglePin(a) } label: {
                    Image(systemName: state.pinnedAgents.contains(a.id) ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.pinnedAgents.contains(a.id) ? Palette.accent : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(state.pinnedAgents.contains(a.id) ? "Unpin from the front of the wheel" : "Pin to the front of the wheel")
                if state.herdrApp {
                    Button { state.focus(a) } label: {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderless).help("Open this agent in Herdr")
                }
            }
            if urgent, !speech.text.isEmpty {
                if let approval = a.permission {
                    Label("Wants to run\(approval.tool.isEmpty ? " this" : " \(approval.tool)"). \(a.prompt.isEmpty ? "Do you want to proceed?" : a.prompt)",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.accent)
                        .padding(.leading, 34)
                }
                Text(speech.text).font(a.permission != nil ? .system(size: 12, weight: .medium, design: .monospaced)
                                                           : .system(size: 12.5, weight: .medium, design: .rounded))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
                if !speech.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(speech.options.enumerated()), id: \.offset) { i, option in
                            Button { state.answer(a, option: i) } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.system(size: 10.5, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white).frame(width: 17, height: 17)
                                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(white: 0.2)))
                                    Text(option).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.accent.opacity(0.55), lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(a.hints[i + 1] ?? "Send this answer")
                        }
                    }
                    .padding(.leading, 34)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(urgent ? AnyShapeStyle(Palette.accentSoft) : AnyShapeStyle(.regularMaterial)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(urgent ? Palette.accent.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: urgent ? 1.5 : 1))
    }
}

/// Beside the Agents page: try the wheel, how it opens, and whether Herdr is there.
struct AgentSidePanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent wheel").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("A wheel of your agents around the pointer, so you can see who needs you and answer without switching windows.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { state.toggleWheel() } label: {
                Label("Show the wheel now", systemImage: "circle.hexagongrid.fill")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.large)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("OPENS WITH").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
                if state.wheelTriggers.isEmpty {
                    Text("Nothing on the mouse opens it yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(state.wheelTriggers, id: \.self) { t in
                        Label(t, systemImage: "hand.tap").font(.system(size: 12.5, weight: .medium))
                    }
                }
                Button("Choose a button for it…") { state.tab = .buttons }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if state.profile.control(.thumbPanel) != nil {
                Toggle("Open with a quick tap on the thumb pad", isOn: $state.ringOnTap)
                    .font(.system(size: 12.5, weight: .medium))
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("ORDER").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
                Picker("", selection: $state.ringOrder) {
                    Text("Most recent").tag(RingOrder.recent)
                    Text("By space").tag(RingOrder.space)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(state.ringOrder == .space
                     ? "Each agent keeps its place, with a space's sessions side by side under its name."
                     : "Whoever was active last comes first.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Agents waiting on you lead, then the ones you pin. Quiet ones fade and shrink until you point at them. Right-click a wedge to pin it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Feel when an agent needs me or finishes", isOn: $state.feelAgents)
                    .font(.system(size: 12.5, weight: .medium)).disabled(!state.hapticsOn || !state.hapticsAvailable)
                Text("A knock in the thumb pad when an agent starts waiting on you, and a pulse when one finishes.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HerdrStatusBox(state: state)
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
        .onAppear { state.checkHerdr() }
    }
}

/// Whether the two parts of Herdr the agent features rely on are there, and what to do if not.
struct HerdrStatusBox: View {
    @ObservedObject var state: AppState

    var body: some View {
        let green = Color(red: 0.30, green: 0.80, blue: 0.47), grey = Color(white: 0.6)
        let core: Color = state.herdr.isRunning ? green : (state.herdr == .notRunning ? Palette.accent : grey)
        return VStack(alignment: .leading, spacing: 5) {
            row("herdr-core", state.herdr.summary, core)
            row("Herdr app", state.herdrApp ? "installed" : "not installed", state.herdrApp ? green : grey)
            if let advice {
                Text(advice).font(.system(size: 11.5)).foregroundStyle(.secondary).tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ name: String, _ value: String, _ dot: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(name).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    /// One short line about the first thing that is missing, or nothing when all is well.
    private var advice: AttributedString? {
        let text: String
        switch state.herdr {
        case .notInstalled: text = "The agent wheel and agent haptics need Herdr, which runs your coding agents. Get it at [herdr.dev](https://herdr.dev); no restart needed."
        case .notRunning: text = "herdr-core is installed but didn't answer. Start it with “hc\u{00A0}server\u{00A0}start”."
        case .unknown: return nil
        case .running:
            if state.herdrApp { return nil }
            text = "You can see and answer agents, but jumping to one needs the Herdr app from [herdr.dev](https://herdr.dev)."
        }
        return try? AttributedString(markdown: text)
    }
}

// MARK: - Feel page

/// The third page: what the mouse lets you feel, and window snapping.
struct FeelPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card("cursorarrow.rays", "Feel buttons and links under the cursor", $state.feelHover, needsHaptics: true,
                 "A faint tick as the pointer lands on something clickable — buttons, links, menu and Dock items.")
            card("macwindow.on.rectangle", "Feel window edges", $state.feelEdges, needsHaptics: true,
                 "A soft bump each time the pointer crosses into or out of a window.")
            card("rectangle.split.2x1", "Snap windows at screen edges", $state.snapWindows, needsHaptics: false,
                 "While dragging a window with a mouse button, push into the left or right edge for half the screen, the top for full screen, or a corner for a quarter.")
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(.horizontal, 24).padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(_ symbol: String, _ title: String, _ isOn: Binding<Bool>, needsHaptics: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().disabled(needsHaptics && (!state.hapticsOn || !state.hapticsAvailable))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Beside the Feel page: the haptic motor's master switch and strength.
struct HapticsSidePanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Haptic feedback").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Small bumps in the thumb pad: when a dragged window reaches a snap edge, when a gesture fires, and for whatever is switched on to the left.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Haptic feedback", isOn: $state.hapticsOn).font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                Text("STRENGTH").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
                Picker("", selection: $state.hapticStrength) {
                    Text("Soft").tag(30); Text("Medium").tag(60); Text("Strong").tag(100)
                }
                .pickerStyle(.segmented).labelsHidden()
                Button("Try it") { state.buzz(.hello) }
            }
            .disabled(!state.hapticsOn || !state.hapticsAvailable)
            if !state.hapticsAvailable {
                Label(state.profile.hasHaptics
                      ? "Needs the mouse connected with Input Monitoring allowed."
                      : "This mouse has no haptic motor.", systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
    }
}

// MARK: - Right-hand panel

struct DetailPanel: View {
    @ObservedObject var state: AppState

    private var slot: Slot { state.editing }
    private var control: MouseControl? { state.profile.control(state.selected) }
    private var current: Action { state.action(slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(control?.title ?? "").font(.system(size: 18, weight: .bold, design: .rounded))
                Text(control?.blurb ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.available.contains(state.selected) {
                    Label(unavailableText, systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    if needsDirectLink && state.wantsDirectLink && state.accessibilityOK && state.hidStatus != .connected {
                        Button("Open Input Monitoring settings…") { state.requestInputMonitoring() }
                            .controlSize(.small).padding(.top, 2)
                    }
                } else if let note = state.profile.note {
                    // Something about this mouse as a whole, such as having no spare button.
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if state.hasGestures(state.selected) {
                    Picker("", selection: $state.gesturePart) {
                        ForEach(Slot.gestureParts) { p in Text(p.partLabel).tag(p) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.top, 6)
                    if slot.isSwipe {
                        Text(slot.swipeTitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
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

    /// The selected control reaches us only over the direct (HID++) link.
    private var needsDirectLink: Bool {
        if case .hidpp = control?.source { return true }
        return false
    }

    private var unavailableText: String {
        if !state.accessibilityOK { return "Works once Accessibility is allowed (see the left side)." }
        if needsDirectLink && !state.wantsDirectLink {
            return "This button only answers over Bluetooth. Pair the mouse by Bluetooth instead of using its USB receiver or cable."
        }
        if !needsDirectLink {
            // An ordinary button, so the direct link has nothing to do with it.
            return "MouseHerdr isn't hearing this mouse's buttons yet. It starts listening a moment after Accessibility is allowed. If this stays, quit and reopen MouseHerdr."
        }
        if let other = state.linkElsewhere {
            return "MouseHerdr can talk directly to one Logitech mouse at a time, and right now that is your \(other). Switch that one off to use this button."
        }
        if state.hidStatus != .connected {
            return "This one button also needs Input Monitoring. In the settings list, switch MouseHerdr on — if it isn't listed, click + and pick MouseHerdr from Applications."
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
        case "dragWindow": return !slot.isSwipe && !state.hasGestures(slot)
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

// MARK: - App icon artwork

struct IconView: View {
    // The icon is always the MX Master 4, whatever mouse is connected.
    private let art = MouseProfile.mxMaster4.art
    private let wheel = MouseProfile.mxMaster4.control(.middle)?.rect ?? .zero

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.62, blue: 0.36), Color(red: 0.98, green: 0.33, blue: 0.38)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            ZStack(alignment: .topLeading) {
                if let wing = art.wing { wing.fill(Color.white.opacity(0.78)) }
                art.body.fill(Color.white)
                art.seams.stroke(Color(red: 0.98, green: 0.4, blue: 0.36).opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Capsule().fill(Color(red: 0.98, green: 0.4, blue: 0.36))
                    .frame(width: wheel.width, height: wheel.height)
                    .position(x: wheel.midX, y: wheel.midY)
            }
            .frame(width: art.size.width, height: art.size.height)
            .offset(x: 12, y: -6)
            .scaleEffect(1.32)
        }
        .frame(width: 1024, height: 1024)
    }
}
