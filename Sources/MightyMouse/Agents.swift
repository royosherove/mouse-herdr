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
            DispatchQueue.main.async {
                if let herdr = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.herdr.app").first {
                    herdr.activate(options: [.activateAllWindows])
                }
            }
        }
    }
}

// MARK: - The ring

final class RingModel: ObservableObject {
    struct Placed: Identifiable {
        let agent: AgentInfo
        let offset: CGSize       // from the ring's centre, y down
        var id: String { agent.id }
    }

    @Published var placed: [Placed] = []
    @Published var highlighted: String?
    @Published var hidden = 0
    var outerRadius: CGFloat = 200

    func layout(_ agents: [AgentInfo]) {
        let urgent = agents.filter { $0.needsYou }
        var others = agents.filter { !$0.needsYou }
        hidden = max(0, others.count - 12)
        others = Array(others.prefix(12))
        var result: [Placed] = []
        // Agents waiting on you sit on the inner ring, closest to the pointer.
        let inner: CGFloat = urgent.count > 3 ? 118 : 98
        result += Self.circle(urgent, radius: urgent.count == 1 ? 86 : inner)
        let outer: CGFloat = urgent.isEmpty ? (others.count > 8 ? 190 : 150) : (others.count > 8 ? 235 : 215)
        result += Self.circle(others, radius: outer)
        outerRadius = others.isEmpty ? inner : outer
        placed = result
        if let h = highlighted, !result.contains(where: { $0.id == h }) { highlighted = nil }
    }

    private static func circle(_ agents: [AgentInfo], radius: CGFloat) -> [Placed] {
        guard !agents.isEmpty else { return [] }
        return agents.enumerated().map { i, a in
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(agents.count)
            // Stretch sideways a little: chips are wider than they are tall.
            return Placed(agent: a, offset: CGSize(width: cos(angle) * radius * 1.18, height: sin(angle) * radius))
        }
    }

    /// The agent the pointer is aiming at, given its offset from the centre.
    func target(for p: CGSize) -> String? {
        guard hypot(p.width, p.height) > 34 else { return nil }
        let best = placed.min { a, b in
            hypot(a.offset.width - p.width, a.offset.height - p.height) < hypot(b.offset.width - p.width, b.offset.height - p.height)
        }
        guard let best, hypot(best.offset.width - p.width, best.offset.height - p.height) < 120 else { return nil }
        return best.id
    }
}

struct RingView: View {
    @ObservedObject var model: RingModel
    static let side: CGFloat = 760

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.black.opacity(0.62), Color.black.opacity(0.40), .clear],
                                     center: .center, startRadius: 30, endRadius: model.outerRadius * 1.18 + 120))
            centre
            ForEach(model.placed) { item in
                chip(item.agent, on: model.highlighted == item.id)
                    .offset(item.offset)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(.easeOut(duration: 0.12), value: model.highlighted)
    }

    private var centre: some View {
        let waiting = model.placed.filter { $0.agent.needsYou }.count
        let focus = model.placed.first { $0.id == model.highlighted }?.agent
        return VStack(spacing: 2) {
            if model.placed.isEmpty {
                Text("No agents").font(.system(size: 13, weight: .semibold))
                Text("running").font(.system(size: 11)).opacity(0.7)
            } else if let focus {
                Text(focus.statusWord).font(.system(size: 12, weight: .bold)).foregroundStyle(focus.color)
                Text(focus.agent).font(.system(size: 10.5)).opacity(0.75)
            } else if waiting > 0 {
                Text("\(waiting)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                Text(waiting == 1 ? "needs you" : "need you").font(.system(size: 10.5)).opacity(0.8)
            } else {
                Text("\(model.placed.count + model.hidden)").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("agents").font(.system(size: 10.5)).opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 66, height: 66)
        .background(Circle().fill(Color(white: 0.12).opacity(0.92)))
        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    private func chip(_ a: AgentInfo, on: Bool) -> some View {
        let urgent = a.needsYou
        return HStack(spacing: 8) {
            Circle().fill(urgent ? Color.white : a.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.space).font(.system(size: urgent ? 13.5 : 12.5, weight: .semibold)).lineLimit(1)
                Text(a.tab.isEmpty ? a.statusWord : "\(a.tab) · \(a.statusWord)")
                    .font(.system(size: 10.5)).opacity(0.8).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: urgent ? 158 : 138, height: urgent ? 48 : 40)
        .background(
            Capsule().fill(urgent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color(white: on ? 0.30 : 0.16).opacity(0.95)))
        )
        .overlay(Capsule().stroke(on ? Color.white : (urgent ? Color.white.opacity(0.45) : a.color.opacity(0.55)), lineWidth: on ? 2.2 : 1))
        .shadow(color: urgent ? Palette.accent.opacity(0.75) : .black.opacity(0.35), radius: urgent ? 12 : 5)
        .scaleEffect(on ? 1.10 : 1)
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
            let v = screen.visibleFrame, margin: CGFloat = 250
            let cx = min(max(mouse.x, v.minX + margin), v.maxX - margin)
            let cy = min(max(mouse.y, v.minY + margin * 0.8), v.maxY - margin * 0.8)
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
        if hypot(rel.width, rel.height) > model.outerRadius * 1.18 + 190 { close(); return }
        let aim = model.target(for: rel)
        if aim != model.highlighted {
            model.highlighted = aim
            if aim != nil { onAim?() }
        }
    }

    /// Pick whatever is aimed at (or just close when nothing is).
    func choose() {
        let picked = model.placed.first { $0.id == model.highlighted }?.agent
        close()
        if let picked { onChoose?(picked) }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }
}
