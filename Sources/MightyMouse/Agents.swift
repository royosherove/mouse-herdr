import AppKit
import SwiftUI

/// One coding agent running in herdr-core.
struct AgentInfo: Identifiable, Equatable {
    let id: String        // terminal address, e.g. "t7"
    let agent: String     // e.g. "claude-code"
    let status: String    // idle, working, done, blocked, error, or "" when unknown
    let space: String
    let tab: String

    var needsYou: Bool { status == "blocked" || status == "error" }

    var statusWord: String {
        switch status {
        case "blocked": return "needs you"
        case "error": return "error"
        case "working": return "working"
        case "done": return "done"
        case "idle": return "idle"
        default: return "running"
        }
    }

    var color: Color {
        switch status {
        case "blocked": return Palette.accent
        case "error": return .red
        case "working": return Color(red: 0.35, green: 0.62, blue: 1.0)
        case "done": return Color(red: 0.30, green: 0.80, blue: 0.47)
        default: return Color(white: 0.6)
        }
    }

    /// Lower sorts first: the ones that want attention, then finished, then busy.
    var rank: Int {
        switch status {
        case "blocked": return 0
        case "error": return 1
        case "done": return 2
        case "working": return 3
        default: return 4
        }
    }
}

/// Reads agent state from herdr-core (`hc`) and asks the Herdr app to show one.
final class AgentWatcher {
    private let queue = DispatchQueue(label: "mm.agents", qos: .userInitiated)
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "pwsh", "powershell", "dash", "ksh", "tcsh"]
    private(set) var latest: [AgentInfo] = []

    static func tool(_ name: String) -> String? {
        let home = NSHomeDirectory()
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    var isAvailable: Bool { Self.tool("hc") != nil }

    private static func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    static func parse(_ data: Data) -> [AgentInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = root["terminals"] as? [[String: Any]] else { return [] }
        var out: [AgentInfo] = []
        for t in terms {
            guard let id = t["address"] as? String else { continue }
            let agent = t["agent"] as? String ?? ""
            let status = t["status"] as? String ?? ""
            // Plain shells aren't agents unless they report a status.
            if status.isEmpty && (agent.isEmpty || shells.contains(agent)) { continue }
            let place = (t["where"] as? String ?? "").components(separatedBy: " / ")
            out.append(AgentInfo(
                id: id, agent: agent, status: status,
                space: place.first ?? agent, tab: place.count > 1 ? place[1] : ""))
        }
        return out.sorted { ($0.rank, $0.space, $0.tab) < ($1.rank, $1.space, $1.tab) }
    }

    /// Fetch the current agents; the result arrives on the main thread.
    func fetch(_ done: @escaping ([AgentInfo]) -> Void) {
        queue.async {
            var list: [AgentInfo] = []
            if let hc = Self.tool("hc"), let data = Self.run(hc, ["ls", "--json"]) { list = Self.parse(data) }
            DispatchQueue.main.async {
                self.latest = list
                done(list)
            }
        }
    }

    /// Bring this agent's terminal to the front in the Herdr app.
    func focus(_ agent: AgentInfo) {
        Log.write("agents: focusing \(agent.id) (\(agent.space) / \(agent.tab))")
        queue.async {
            if let app = Self.tool("herdr-app") {
                let ok = Self.run(app, ["do", "agent.focus", "{\"terminal\":\"\(agent.id)\"}"]) != nil
                if !ok { Log.write("agents: herdr-app agent.focus failed") }
            }
            // Bring the Herdr window forward. Going through Launch Services works even though
            // MightyMouse itself is a background app; a plain activate() request gets ignored.
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app") else {
                    Log.write("agents: Herdr app not found")
                    return
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                    if let error { Log.write("agents: could not bring Herdr forward: \(error.localizedDescription)") }
                    else {
                        DispatchQueue.main.async {
                            app?.activate(options: [.activateAllWindows])
                            if let w = app, w.isHidden { w.unhide() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The ring

final class RingModel: ObservableObject {
    /// One wedge of the wheel. Angles are radians, 0 pointing right, growing clockwise on screen.
    struct Slice: Identifiable {
        let agent: AgentInfo
        let start: Double
        let end: Double
        let inner: CGFloat
        let outer: CGFloat
        var id: String { agent.id }
        var mid: Double { (start + end) / 2 }
    }

    @Published var slices: [Slice] = []
    @Published var highlighted: String?
    @Published var hidden = 0
    var outerRadius: CGFloat = 250

    func layout(_ agents: [AgentInfo]) {
        let urgent = agents.filter { $0.needsYou }
        let rest = agents.filter { !$0.needsYou }
        hidden = max(0, rest.count - 12)
        let all = urgent + rest.prefix(12)
        outerRadius = all.count > 9 ? 300 : (all.count > 6 ? 275 : 250)
        guard !all.isEmpty else { slices = []; highlighted = nil; return }

        // Agents waiting on you get wider wedges that also reach further in, so they are the closest targets.
        let weights = all.map { $0.needsYou ? 1.45 : 1.0 }
        let unit = min(2 * Double.pi / weights.reduce(0, +), 2 * Double.pi / 3.2)
        let spans = weights.map { $0 * unit }
        let used = spans.reduce(0, +)
        let full = used > 2 * Double.pi - 0.001
        // Start so the first wedge (or the whole group, when it doesn't fill the circle) is centred at the top.
        var angle = -Double.pi / 2 - (full ? spans[0] / 2 : used / 2)
        var result: [Slice] = []
        for (a, span) in zip(all, spans) {
            result.append(Slice(agent: a, start: angle, end: angle + span,
                                inner: a.needsYou ? 60 : 96, outer: a.needsYou ? outerRadius + 16 : outerRadius))
            angle += span
        }
        slices = result
        if let h = highlighted, !result.contains(where: { $0.id == h }) { highlighted = nil }
    }

    /// The agent the pointer is aiming at, given its offset from the centre (y down).
    func target(for p: CGSize) -> String? {
        guard hypot(p.width, p.height) > 46 else { return nil }
        let angle = atan2(Double(p.height), Double(p.width))
        for s in slices {
            var d = (angle - s.start).truncatingRemainder(dividingBy: 2 * .pi)
            if d < 0 { d += 2 * .pi }
            if d < s.end - s.start { return s.id }
        }
        return nil
    }
}

/// A pie wedge between two radii, with a small gap to its neighbours.
struct Wedge: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat = 3.5

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let po = Double(gap / outer), pi = Double(gap / inner)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .radians(start + po), endAngle: .radians(end - po), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(end - pi), endAngle: .radians(start + pi), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct RingView: View {
    @ObservedObject var model: RingModel
    static let side: CGFloat = 800

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.black.opacity(0.50), Color.black.opacity(0.30), .clear],
                                         center: .center, startRadius: 40, endRadius: model.outerRadius + 90))
                ForEach(model.slices) { s in
                    slice(s, on: model.highlighted == s.id, t: t)
                }
                hub
            }
            .frame(width: Self.side, height: Self.side)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.highlighted)
    }

    // MARK: Wedges

    private func slice(_ s: RingModel.Slice, on: Bool, t: Double) -> some View {
        let a = s.agent, urgent = a.needsYou
        let pulse = 0.5 + 0.5 * sin(t * 4.2)
        let pop: CGFloat = on ? 16 : (urgent ? CGFloat(3 * pulse) : 0)
        let shape = Wedge(start: s.start, end: s.end, inner: s.inner, outer: s.outer)
        let rim = Wedge(start: s.start, end: s.end, inner: s.outer - 7, outer: s.outer)
        let fill: AnyShapeStyle = urgent
            ? AnyShapeStyle(RadialGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.40), Palette.accent, Color(red: 0.93, green: 0.30, blue: 0.30)],
                                           center: .center, startRadius: s.inner, endRadius: s.outer))
            : AnyShapeStyle(RadialGradient(colors: [Color(white: on ? 0.36 : 0.20), Color(white: on ? 0.26 : 0.11)],
                                           center: .center, startRadius: s.inner, endRadius: s.outer))
        let radius = s.inner + (s.outer - s.inner) * 0.54
        let arcWidth = CGFloat(s.end - s.start) * radius
        return ZStack {
            shape.fill(fill).opacity(urgent ? 1 : 0.95)
            if !urgent {
                rim.fill(a.color).opacity(a.status == "working" ? 0.55 + 0.45 * pulse : 0.9)
            }
            shape.stroke(on ? Color.white : Color.white.opacity(urgent ? 0.5 : 0.10), lineWidth: on ? 3 : 1)
            label(a, on: on, t: t, width: max(64, min(150, arcWidth - 26)))
                .offset(x: CGFloat(cos(s.mid)) * radius, y: CGFloat(sin(s.mid)) * radius)
        }
        .shadow(color: urgent ? Palette.accent.opacity(0.45 + 0.4 * pulse) : .black.opacity(0.35), radius: urgent ? 16 : 6)
        .offset(x: CGFloat(cos(s.mid)) * pop, y: CGFloat(sin(s.mid)) * pop)
    }

    private func label(_ a: AgentInfo, on: Bool, t: Double, width: CGFloat) -> some View {
        let urgent = a.needsYou
        return VStack(spacing: 3) {
            icon(a, t: t)
                .font(.system(size: urgent ? 30 : 25, weight: .semibold))
                .foregroundStyle(urgent ? Color.white : a.color)
                .frame(height: urgent ? 36 : 30)
            Text(a.space)
                .font(.system(size: urgent ? 15.5 : 14, weight: .bold, design: .rounded))
                .lineLimit(1).truncationMode(.middle)
            Text(a.tab.isEmpty ? a.statusWord : "\(a.tab) · \(a.statusWord)")
                .font(.system(size: 11.5, weight: .medium)).opacity(0.82).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(width: width)
        .scaleEffect(on ? 1.08 : 1)
    }

    /// A little moving picture of what the agent is doing.
    @ViewBuilder
    private func icon(_ a: AgentInfo, t: Double) -> some View {
        switch a.status {
        case "working":
            Image(systemName: "gearshape.fill")
                .rotationEffect(.degrees((t * 150).truncatingRemainder(dividingBy: 360)))
        case "blocked":
            Image(systemName: "hand.raised.fill")
                .rotationEffect(.degrees(12 * sin(t * 6)), anchor: .bottom)
                .scaleEffect(1 + 0.08 * sin(t * 6))
        case "error":
            Image(systemName: "exclamationmark.triangle.fill")
                .opacity(0.6 + 0.4 * abs(sin(t * 5)))
        case "done":
            Image(systemName: "checkmark.circle.fill")
        case "idle":
            Image(systemName: "moon.zzz.fill")
                .offset(y: CGFloat(2 * sin(t * 1.6)))
        default:
            Image(systemName: "terminal.fill")
        }
    }

    // MARK: Hub

    private var hub: some View {
        let waiting = model.slices.filter { $0.agent.needsYou }.count
        let focus = model.slices.first { $0.id == model.highlighted }?.agent
        return VStack(spacing: 1) {
            if model.slices.isEmpty {
                Text("No agents").font(.system(size: 13, weight: .semibold))
                Text("running").font(.system(size: 11)).opacity(0.7)
            } else if let focus {
                Text(focus.statusWord).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(focus.needsYou ? Palette.accent : focus.color)
                Text(focus.agent).font(.system(size: 10.5)).opacity(0.75).lineLimit(1)
                Text("click to open").font(.system(size: 9.5)).opacity(0.5)
            } else if waiting > 0 {
                Text("\(waiting)").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                Text(waiting == 1 ? "needs you" : "need you").font(.system(size: 10.5)).opacity(0.8)
            } else {
                Text("\(model.slices.count + model.hidden)").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("agents").font(.system(size: 10.5)).opacity(0.8)
            }
            if model.hidden > 0 && focus == nil {
                Text("+\(model.hidden) more").font(.system(size: 9.5)).opacity(0.55)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 88, height: 88)
        .background(Circle().fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.08)], center: .top, startRadius: 4, endRadius: 90)))
        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 10)
    }
}

/// Shows the agent ring around the pointer and tracks which agent is aimed at.
final class AgentRing {
    let model = RingModel()
    var onAim: (() -> Void)?
    var onChoose: ((AgentInfo) -> Void)?
    private var panel: NSPanel?
    private var timer: Timer?
    private var centre = CGPoint.zero      // screen coordinates, top-left origin

    var isOpen: Bool { timer != nil }

    func show(_ agents: [AgentInfo]) {
        model.highlighted = nil
        model.layout(agents)
        let side = RingView.side
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x - side / 2, y: mouse.y - side / 2)
        // Keep the ring's busy middle on screen.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let v = screen.visibleFrame, margin: CGFloat = 300
            let cx = min(max(mouse.x, v.minX + margin), v.maxX - margin)
            let cy = min(max(mouse.y, v.minY + margin), v.maxY - margin)
            origin = CGPoint(x: cx - side / 2, y: cy - side / 2)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        centre = CGPoint(x: origin.x + side / 2, y: primaryHeight - (origin.y + side / 2))

        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            p.contentView = NSHostingView(rootView: RingView(model: model))
            panel = p
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFrontRegardless()

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// New data arrived while the ring is open.
    func update(_ agents: [AgentInfo]) {
        guard isOpen else { return }
        model.layout(agents)
    }

    private func track() {
        guard let m = CGEvent(source: nil)?.location else { return }
        let rel = CGSize(width: m.x - centre.x, height: m.y - centre.y)
        if hypot(rel.width, rel.height) > model.outerRadius + 200 { close(); return }
        let aim = model.target(for: rel)
        if aim != model.highlighted {
            model.highlighted = aim
            if aim != nil { onAim?() }
        }
    }

    /// Pick whatever is aimed at (or just close when nothing is).
    func choose() {
        let picked = model.slices.first { $0.id == model.highlighted }?.agent
        close()
        if let picked { onChoose?(picked) }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }
}
