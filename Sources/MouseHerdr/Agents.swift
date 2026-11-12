import AppKit
import SwiftUI

/// One coding agent running in herdr-core.
struct AgentInfo: Identifiable, Equatable {
    let id: String        // terminal address, e.g. "t7"
    let agent: String     // e.g. "claude-code"
    let status: String    // idle, working, done, blocked, error, or "" when unknown
    let space: String
    let tab: String
    var title = ""        // what the session is about
    var message = ""      // what the agent last said it wants (its question, for one that is waiting)
    var kind = ""         // question, permission, auth…
    var typeOption: Int?  // the number of the dialog's "Type something" choice, when it has one
    var hints: [Int: String] = [:]   // the explanation shown under each choice, by choice number (1-based)

    /// The agent's words, split into the question and any choices it offered.
    var speech: (text: String, options: [String]) { speech(full: false) }

    /// `full` keeps the whole question; otherwise it is shortened to a preview.
    func speech(full: Bool) -> (text: String, options: [String]) {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["answer:", "approve:", "permission:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        var options: [String] = []
        // Choices arrive as a trailing "(A · B · C)"; find the bracket that closes at the very end.
        if text.hasSuffix(")") {
            let chars = Array(text)
            var depth = 0, open: Int?
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                if chars[i] == ")" { depth += 1 }
                else if chars[i] == "(" { depth -= 1; if depth == 0 { open = i; break } }
            }
            if let open, open > 0 {
                let parts = String(chars[(open + 1)..<(chars.count - 1)]).components(separatedBy: " · ")
                if parts.count > 1 {
                    options = parts.prefix(4).map { $0.count > 44 ? String($0.prefix(43)) + "…" : $0 }
                    text = String(chars[..<open]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let limit = full ? 1600 : 220
        if text.count > limit { text = String(text.prefix(limit - 1)) + "…" }
        return (text, options)
    }

    /// True when the preview leaves part of the question out.
    var isLongQuestion: Bool { speech(full: true).text.count > 220 }

    var hasSpeech: Bool { !message.isEmpty || !title.isEmpty }

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

/// Whether herdr-core, the thing that knows about the agents, can be reached.
/// Herdr is optional, so every state here is a normal one to be in.
enum HerdrStatus: Equatable {
    case unknown                // not asked yet
    case notInstalled           // no `hc` command on this Mac
    case notRunning             // `hc` is there, but it failed, timed out or made no sense
    case running(agents: Int)   // answered; the count may be zero

    /// A short description for the settings window and the log.
    var summary: String {
        switch self {
        case .unknown: return "checking…"
        case .notInstalled: return "not installed"
        case .notRunning: return "installed, but not running"
        case .running(let n): return n == 0 ? "running, no agents" : "running, \(n) agent\(n == 1 ? "" : "s")"
        }
    }

    var isRunning: Bool { if case .running = self { return true }; return false }

    /// Developer aid: the names the snapshot modes accept after `--state`.
    init?(flag: String) {
        switch flag {
        case "not-installed": self = .notInstalled
        case "not-running": self = .notRunning
        case "empty": self = .running(agents: 0)
        case "unknown": self = .unknown
        default: return nil
        }
    }
}

/// Reads agent state from herdr-core (`hc`) and asks the Herdr app to show one.
final class AgentWatcher {
    private let queue = DispatchQueue(label: "mm.agents", qos: .userInitiated)
    /// Answers and jumps go on their own queue so a slow listing can't hold them up.
    private let actions = DispatchQueue(label: "mm.agents.actions", qos: .userInitiated)
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "pwsh", "powershell", "dash", "ksh", "tcsh"]
    private(set) var latest: [AgentInfo] = []
    /// What the last fetch found out about Herdr itself. Read on the main thread.
    private(set) var status = HerdrStatus.unknown
    /// Jumping to an agent needs the Herdr app; viewing and answering do not.
    private(set) var appInstalled = true
    /// Developer aid: snapshots pin the state so a real fetch can't change the picture.
    var pinned: (status: HerdrStatus, app: Bool)? {
        didSet { if let pinned { status = pinned.status; appInstalled = pinned.app } }
    }

    static let appBundleID = "dev.herdr.app"
    /// How long any one `hc` or `herdr-app` call may take before it is given up on.
    static let timeout: TimeInterval = 4

    static func tool(_ name: String) -> String? {
        // Developer aid: MOUSEHERDR_HC / MOUSEHERDR_HERDR_APP name the exact file to use
        // (or one that doesn't exist), to try out the "not installed" and "not running" cases.
        let key = "MOUSEHERDR_" + name.uppercased().replacingOccurrences(of: "-", with: "_")
        if let forced = ProcessInfo.processInfo.environment[key] {
            return FileManager.default.isExecutableFile(atPath: forced) ? forced : nil
        }
        let home = NSHomeDirectory()
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// True when the Herdr app can be asked to show an agent: its command or the app itself is here.
    static func herdrAppInstalled() -> Bool {
        if tool("herdr-app") != nil { return true }
        // The override above also hides the app, so "no Herdr app" can be tried on a Mac that has it.
        if ProcessInfo.processInfo.environment["MOUSEHERDR_HERDR_APP"] != nil { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) != nil
    }

    /// Run a command and return what it printed, or nil if it failed or took too long.
    /// Never call this on the main thread.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = AgentWatcher.timeout) -> Data? {
        final class Box { var data = Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.write("agents: could not start \(path): \(error.localizedDescription)")
            return nil
        }
        // Read on another thread so a command that never finishes can't keep us waiting.
        let box = Box(), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var ended = finished.wait(timeout: .now() + timeout) == .success
        // It may have closed its output and still be going.
        while ended && p.isRunning { if Date() > deadline { ended = false } else { usleep(20_000) } }
        guard ended else {
            p.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            let name = ([(path as NSString).lastPathComponent] + args.prefix(2)).joined(separator: " ")
            Log.write("agents: \(name) did not answer within \(Int(timeout)) seconds; gave up")
            return nil
        }
        return p.terminationStatus == 0 ? box.data : nil
    }

    static func parse(_ data: Data) -> [AgentInfo] { parseList(data) ?? [] }

    /// The agents in `hc ls --json` output, or nil when that isn't what the data is.
    static func parseList(_ data: Data) -> [AgentInfo]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = root["terminals"] as? [[String: Any]] else { return nil }
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

    /// Read a question dialog off the agent's screen: the explanation under each numbered choice,
    /// and the number of its "Type something" choice if it has one.
    static func parseDialog(_ screen: String) -> (hints: [Int: String], typeOption: Int?) {
        var hints: [Int: String] = [:]
        var typeOption: Int?
        var current: Int?
        for raw in screen.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("─") || line.hasPrefix("Enter to select") || line.hasPrefix("[hc]") { current = nil; continue }
            var body = line
            if body.hasPrefix("❯") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let digits = body.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 2, body.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) {
                let label = body.dropFirst(digits.count + 2)
                if label.lowercased().hasPrefix("type something") { typeOption = n; current = nil }
                else { current = n }
                continue
            }
            guard let n = current, !line.isEmpty, raw.hasPrefix("   ") else {
                if line.isEmpty { current = nil }
                continue
            }
            hints[n] = (hints[n].map { $0 + " " } ?? "") + line
        }
        return (hints, typeOption)
    }

    /// Fill in what each agent is saying (its title and question) from `hc get`.
    private static func addDetails(_ list: [AgentInfo], hc: String) -> [AgentInfo] {
        var out = list
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            guard let data = run(hc, ["get", list[i].id, "--json"]),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let status = obj["status"] as? [String: Any]
            // A waiting agent's dialog may also offer a free-text choice; find its number on the screen.
            var typeOption: Int?
            var hints: [Int: String] = [:]
            if list[i].needsYou, let screen = run(hc, ["read", list[i].id]), let text = String(data: screen, encoding: .utf8) {
                (hints, typeOption) = parseDialog(text)
            }
            lock.lock()
            out[i].typeOption = typeOption
            out[i].hints = hints
            out[i].title = obj["title"] as? String ?? ""
            out[i].message = status?["msg"] as? String ?? ""
            out[i].kind = status?["kind"] as? String ?? ""
            lock.unlock()
        }
        return out
    }

    /// Ask herdr-core what is running. Works out the state of Herdr from how the call went,
    /// so a missing, stopped or stuck herdr-core each come back as an answer rather than a failure.
    static func look(details: Bool) -> (status: HerdrStatus, agents: [AgentInfo]) {
        guard let hc = tool("hc") else { return (.notInstalled, []) }
        // A failed, slow or garbled listing all mean the same to the person: it isn't answering.
        guard let data = run(hc, ["ls", "--json"]), var list = parseList(data) else { return (.notRunning, []) }
        if details { list = addDetails(list, hc: hc) }
        return (.running(agents: list.count), list)
    }

    /// Fetch the current agents; the result arrives on the main thread, with `status` and
    /// `appInstalled` brought up to date first.
    func fetch(details: Bool = false, _ done: @escaping ([AgentInfo]) -> Void) {
        queue.async {
            let found = Self.look(details: details)
            let app = Self.herdrAppInstalled()
            DispatchQueue.main.async {
                if self.pinned == nil {
                    if found.status.summary != self.status.summary, !(found.status.isRunning && self.status.isRunning) {
                        Log.write("agents: herdr-core \(found.status.summary)")
                    }
                    if app != self.appInstalled { Log.write("agents: Herdr app \(app ? "found" : "not installed")") }
                    self.status = found.status
                    self.appInstalled = app
                    self.latest = found.agents
                }
                done(self.latest)
            }
        }
    }

    /// Answer the agent's question by pressing the number of the chosen option in its terminal.
    func answer(_ agent: AgentInfo, option: Int) {
        Log.write("agents: answering \(agent.id) with option \(option + 1)")
        actions.async {
            guard let hc = Self.tool("hc") else { Log.write("agents: can't answer, hc is not installed"); return }
            if Self.run(hc, ["keys", agent.id, "\(option + 1)"]) == nil { Log.write("agents: hc keys failed; the answer was not sent") }
        }
    }

    /// Answer in the person's own words: pick the dialog's free-text choice, then type the text.
    func answer(_ agent: AgentInfo, typed text: String) {
        guard let number = agent.typeOption else {
            Log.write("agents: can't type an answer to \(agent.id), its question has no free-text choice")
            return
        }
        Log.write("agents: answering \(agent.id) with typed text (\(text.count) characters)")
        actions.async {
            guard let hc = Self.tool("hc") else { Log.write("agents: can't answer, hc is not installed"); return }
            if Self.run(hc, ["keys", agent.id, "\(number)"]) == nil { Log.write("agents: hc keys failed; the answer was not sent"); return }
            Thread.sleep(forTimeInterval: 0.7)
            if Self.run(hc, ["send", "--force", agent.id, text]) == nil { Log.write("agents: hc send failed; the answer was not sent") }
        }
    }

    /// Bring this agent's terminal to the front in the Herdr app.
    func focus(_ agent: AgentInfo) {
        Log.write("agents: focusing \(agent.id) (\(agent.space) / \(agent.tab))")
        actions.async {
            guard Self.herdrAppInstalled() else {
                Log.write("agents: can't jump to \(agent.id), the Herdr app is not installed")
                return
            }
            if let app = Self.tool("herdr-app") {
                let ok = Self.run(app, ["do", "agent.focus", "{\"terminal\":\"\(agent.id)\"}"]) != nil
                if !ok { Log.write("agents: herdr-app agent.focus failed") }
            } else {
                Log.write("agents: no herdr-app command, so Herdr opens without picking the agent")
            }
            // Bring the Herdr window forward. Going through Launch Services works even though
            // MouseHerdr itself is a background app; a plain activate() request gets ignored.
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID) else {
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

    /// What the wheel says in its middle when it has no agents to show.
    struct Notice: Equatable {
        var symbol: String
        var title: String
        var detail: String
        var tint = Color(white: 0.75)

        static let notInstalled = Notice(
            symbol: "shippingbox", title: "Herdr isn't installed",
            detail: "This wheel shows the coding agents you run with Herdr. Get it at herdr.dev.\nTo stop this tap, see Haptics & extras.")
        static let notRunning = Notice(
            symbol: "moon.zzz.fill", title: "herdr-core isn't running",
            detail: "It is installed but didn't answer. Start it with “hc\u{00A0}server\u{00A0}start” and your agents will appear here.",
            tint: Palette.accent)
        static let empty = Notice(
            symbol: "circle.dashed", title: "No agents found",
            detail: "herdr-core is running, but there are no coding agents in it right now.",
            tint: Color(red: 0.30, green: 0.80, blue: 0.47))
        static let noApp = Notice(
            symbol: "macwindow.badge.plus", title: "No Herdr app installed",
            detail: "Jumping to an agent needs the Herdr app from herdr.dev. Reading and answering here still work.",
            tint: Palette.accent)
    }

    @Published var slices: [Slice] = []
    @Published var notice: Notice?
    /// True until Herdr has answered for the first time; the hub says it is looking.
    @Published var looking = false
    /// False when the Herdr app is missing, so a wedge can't be jumped to.
    @Published var canJump = true
    var herdr = HerdrStatus.unknown
    /// A notice that stays until the wheel closes, whatever new data says.
    var heldNotice = false
    @Published var highlighted: String?
    @Published var hidden = 0
    /// False while the wheel is off screen, so its animations stop costing anything.
    @Published var active = true
    /// Where the speech bubble for the highlighted agent sits, relative to the wheel's centre.
    @Published var bubble: Bubble?

    struct Bubble: Equatable {
        var offset: CGSize
        var size: CGSize
        var toward: CGSize     // unit vector from the bubble to the agent it belongs to
        var textHeight: CGFloat
        var optionCount: Int
        var expanded = false   // showing the whole question rather than a preview
        var hintOnLeft = false // which side of the bubble has room for a choice's explanation
    }

    /// Which answer button the pointer is over, and which one was just sent.
    @Published var hoveredOption: Int?
    @Published var sentOption: Int?

    // Bubble layout, shared by drawing and hit-testing.
    static let bubbleWidth: CGFloat = 400
    static let pad: CGFloat = 16
    static let headerHeight: CGFloat = 16
    static let optionHeight: CGFloat = 44
    static let optionGap: CGFloat = 8
    static let hintHeight: CGFloat = 20

    static func bubbleMetrics(for a: AgentInfo, expanded: Bool = false) -> (size: CGSize, textHeight: CGFloat, options: Int) {
        let speech = a.speech(full: expanded)
        let body = speech.text.isEmpty ? a.title : speech.text
        // Measure the text the same way it will be drawn.
        let base = NSFont.systemFont(ofSize: 14, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 14) } ?? base
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let box = (body as NSString).boundingRect(
            with: CGSize(width: bubbleWidth - 2 * pad, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: para])
        let textHeight = min(ceil(box.height) + 4, expanded ? 620 : 190)
        let n = a.needsYou ? speech.options.count + (a.typeOption != nil ? 1 : 0) : 0
        var h = pad + headerHeight + 6 + textHeight + pad
        if n > 0 { h += 12 + CGFloat(n) * optionHeight + CGFloat(n - 1) * optionGap + hintHeight }
        return (CGSize(width: bubbleWidth, height: h), textHeight, n)
    }

    /// An answer button's frame, measured from the bubble's top-left corner.
    static func optionRect(_ i: Int, in b: Bubble) -> CGRect {
        let top = pad + headerHeight + 6 + b.textHeight + 12
        return CGRect(x: pad, y: top + CGFloat(i) * (optionHeight + optionGap), width: b.size.width - 2 * pad, height: optionHeight)
    }

    var outerRadius: CGFloat = 250

    func layout(_ agents: [AgentInfo]) {
        if heldNotice { return }
        looking = herdr == .unknown && agents.isEmpty
        switch herdr {
        case .notInstalled: notice = .notInstalled
        case .notRunning: notice = .notRunning
        case .running: notice = agents.isEmpty ? .empty : nil
        case .unknown: notice = nil
        }
        // Without herdr-core there is nothing true to show, so don't leave old wedges up.
        let agents = (herdr == .notInstalled || herdr == .notRunning) ? [] : agents
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
    static let side: CGFloat = 1400

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.black.opacity(0.50), Color.black.opacity(0.30), .clear],
                                         center: .center, startRadius: 40, endRadius: model.outerRadius + 90))
                if let notice = model.notice {
                    noticeCard(notice)
                } else {
                    ForEach(model.slices) { s in
                        slice(s, on: model.highlighted == s.id, t: t)
                    }
                    hub
                }
                if let b = model.bubble, let a = model.slices.first(where: { $0.id == model.highlighted })?.agent {
                    SpeechBubble(agent: a, bubble: b, model: model)
                        .offset(x: b.offset.width, y: b.offset.height)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: Self.side, height: Self.side)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.highlighted)
        .animation(.easeOut(duration: 0.18), value: model.notice)
    }

    // MARK: Notice

    /// The wheel with nothing in it: an empty track where the wedges go, and the reason in the middle.
    private func noticeCard(_ n: RingModel.Notice) -> some View {
        let track: CGFloat = 196
        return ZStack {
            Circle().stroke(Color(white: 0.13).opacity(0.9), lineWidth: 34).frame(width: track * 2, height: track * 2)
            Circle().stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [3, 9]))
                .frame(width: track * 2, height: track * 2)
            VStack(spacing: 7) {
                Image(systemName: n.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(n.tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(n.tint.opacity(0.55), lineWidth: 1.5))
                    .padding(.bottom, 3)
                Text(n.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(n.detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineSpacing(2).opacity(0.78)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Click anywhere to close")
                    .font(.system(size: 10, weight: .medium)).opacity(0.45).padding(.top, 5)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(width: 264)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.08)], center: .top, startRadius: 4, endRadius: 260)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 12)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
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
                // Only seen for a moment: before herdr-core has answered for the first time.
                Text(model.looking ? "Looking for" : "No agents").font(.system(size: 13, weight: .semibold))
                Text(model.looking ? "agents…" : "running").font(.system(size: 11)).opacity(0.7)
            } else if let focus {
                Text(focus.statusWord).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(focus.needsYou ? Palette.accent : focus.color)
                Text(focus.agent).font(.system(size: 10.5)).opacity(0.75).lineLimit(1)
                Text(model.canJump ? "click to open" : "no Herdr app").font(.system(size: 9.5)).opacity(0.5)
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

/// A cartoon speech bubble with the agent's question in it.
struct SpeechBubble: View {
    let agent: AgentInfo
    let bubble: RingModel.Bubble

    private struct Tail: Shape {
        let toward: CGSize
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let tx = toward.width, ty = toward.height
            // Distance from the centre to the bubble's edge in that direction.
            let edge = min(abs(tx) > 0.001 ? rect.width / 2 / abs(tx) : .infinity,
                           abs(ty) > 0.001 ? rect.height / 2 / abs(ty) : .infinity)
            let tip = CGPoint(x: c.x + tx * (edge + 26), y: c.y + ty * (edge + 26))
            let base = CGPoint(x: c.x + tx * (edge - 14), y: c.y + ty * (edge - 14))
            let px = -ty * 15, py = tx * 15
            var p = Path()
            p.move(to: tip)
            p.addLine(to: CGPoint(x: base.x + px, y: base.y + py))
            p.addLine(to: CGPoint(x: base.x - px, y: base.y - py))
            p.closeSubpath()
            return p
        }
    }

    @ObservedObject var model: RingModel

    var body: some View {
        let speech = agent.speech(full: bubble.expanded)
        let ink = Color(white: 0.10)
        let heading = agent.needsYou
            ? (agent.kind.isEmpty ? "Waiting for you" : "Asks: \(agent.kind)")
            : agent.statusWord.capitalized
        return ZStack(alignment: .topLeading) {
            Group {
                Tail(toward: bubble.toward).fill(Color.white)
                Tail(toward: bubble.toward).stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white)
                RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(ink, lineWidth: 2.5)
                // Cover the outline where the tail joins the bubble.
                Tail(toward: bubble.toward).fill(Color.white).scaleEffect(0.86)
            }
            .frame(width: bubble.size.width, height: bubble.size.height)

            HStack(spacing: 6) {
                Circle().fill(agent.needsYou ? Palette.accent : agent.color).frame(width: 8, height: 8)
                Text("\(agent.space.uppercased())  ·  \(heading.uppercased())")
                    .font(.system(size: 10, weight: .heavy)).kerning(0.5)
                    .foregroundStyle(agent.needsYou ? Palette.accent : Color(white: 0.4)).lineLimit(1)
            }
            .frame(width: bubble.size.width - 2 * RingModel.pad, height: RingModel.headerHeight, alignment: .leading)
            .offset(x: RingModel.pad, y: RingModel.pad)

            Text(speech.text.isEmpty ? agent.title : speech.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(ink)
                .lineSpacing(2)
                .frame(width: bubble.size.width - 2 * RingModel.pad, height: bubble.textHeight, alignment: .topLeading)
                .offset(x: RingModel.pad, y: RingModel.pad + RingModel.headerHeight + 6)

            if bubble.optionCount > 0 {
                ForEach(0..<bubble.optionCount, id: \.self) { i in
                    let r = RingModel.optionRect(i, in: bubble)
                    let own = i >= speech.options.count
                    answerButton(i, own ? "Type your own answer…" : speech.options[i], own: own,
                                 hot: model.hoveredOption == i, sent: model.sentOption == i)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                if let i = model.hoveredOption, let hint = agent.hints[i + 1], !hint.isEmpty {
                    let r = RingModel.optionRect(i, in: bubble)
                    hintCard(hint)
                        .offset(x: bubble.hintOnLeft ? -(300 + 14) : bubble.size.width + 14, y: r.minY - 6)
                        .transition(.opacity)
                }
                Text(model.sentOption != nil ? "Sent — waiting for the agent…"
                     : (!bubble.expanded && agent.isLongQuestion) ? "Move onto the bubble to read the whole question"
                     : "Point at an answer and click to send it")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                    .frame(width: bubble.size.width - 2 * RingModel.pad, height: RingModel.hintHeight, alignment: .center)
                    .offset(x: RingModel.pad, y: bubble.size.height - RingModel.pad - RingModel.hintHeight + 6)
            }
        }
        .frame(width: bubble.size.width, height: bubble.size.height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: model.hoveredOption)
        .animation(.easeOut(duration: 0.15), value: model.sentOption)
    }

    /// The explanation for the choice under the pointer, like an item tooltip in a game.
    private func hintCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(width: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.accent, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .frame(width: 300, height: RingModel.optionHeight, alignment: .topLeading)
    }

    /// A chunky, game-style answer button with a key-cap number.
    private func answerButton(_ i: Int, _ text: String, own: Bool, hot: Bool, sent: Bool) -> some View {
        let green = Color(red: 0.20, green: 0.72, blue: 0.42)
        let face: AnyShapeStyle = sent
            ? AnyShapeStyle(LinearGradient(colors: [green.opacity(0.9), green], startPoint: .top, endPoint: .bottom))
            : hot
                ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.60, blue: 0.40), Palette.accent], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.91)], startPoint: .top, endPoint: .bottom))
        let lit = hot || sent
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Color.white : Color(white: 0.14))
                if sent {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(green)
                } else if own {
                    Image(systemName: "pencil").font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(hot ? Palette.accent : Color.white)
                } else {
                    Text("\(i + 1)").font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(hot ? Palette.accent : Color.white)
                }
            }
            .frame(width: 26, height: 26)
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .italic(own)
                .foregroundStyle(lit ? Color.white : Color(white: own ? 0.35 : 0.12))
                .lineLimit(1).minimumScaleFactor(0.78)
            Spacer(minLength: 0)
            if hot && !sent {
                Image(systemName: "arrow.right.circle.fill").font(.system(size: 17)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(face))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(lit ? Color.white.opacity(0.0) : Color(white: 0.10).opacity(0.22), lineWidth: 1.5))
        // A darker lip underneath gives the button some depth.
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(sent ? green.opacity(0.55) : hot ? Color(red: 0.78, green: 0.26, blue: 0.20) : Color(white: 0.72))
            .offset(y: hot ? 2 : 3))
        .offset(y: hot ? 1 : 0)
        .scaleEffect(hot ? 1.025 : 1)
    }
}

/// Shows the agent ring around the pointer and tracks which agent is aimed at.
final class AgentRing {
    let model = RingModel()
    var onAim: (() -> Void)?
    var onChoose: ((AgentInfo) -> Void)?
    /// The person picked one of the agent's offered answers (by index).
    var onAnswer: ((AgentInfo, Int) -> Void)?
    /// The person wants to type their own answer; the point is where to put the text box (Cocoa screen coordinates).
    var onType: ((AgentInfo, CGPoint) -> Void)?
    private var lastQuestion = ""
    private var pointerOnWheel = false     // the pointer is over a wedge right now
    private var pointerOnBubble = false
    private var expandedFor: String?           // agent whose bubble is showing its whole question
    private var anchor: (x: CGFloat, bottom: CGFloat)?   // keeps the answer buttons still while it grows
    private var panel: NSPanel?
    private var timer: Timer?
    private var centre = CGPoint.zero      // screen coordinates, top-left origin

    var isOpen: Bool { timer != nil }

    func show(_ agents: [AgentInfo], herdr: HerdrStatus, appInstalled: Bool) {
        model.herdr = herdr
        model.canJump = appInstalled
        model.heldNotice = false
        model.highlighted = nil
        pointerOnWheel = false
        pointerOnBubble = false
        expandedFor = nil
        anchor = nil
        model.hoveredOption = nil
        model.sentOption = nil
        model.bubble = nil
        model.active = true
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
    func update(_ agents: [AgentInfo], herdr: HerdrStatus, appInstalled: Bool) {
        guard isOpen else { return }
        model.herdr = herdr
        model.canJump = appInstalled
        model.layout(agents)
        placeBubble()
    }

    private func track() {
        guard let m = CGEvent(source: nil)?.location else { return }
        let rel = CGSize(width: m.x - centre.x, height: m.y - centre.y)
        let r = hypot(rel.width, rel.height)

        // Is the pointer over the bubble, or one of its answer buttons?
        var option: Int?
        var overBubble = false
        if let b = model.bubble {
            let local = CGPoint(x: rel.width - b.offset.width + b.size.width / 2,
                                y: rel.height - b.offset.height + b.size.height / 2)
            overBubble = CGRect(origin: .zero, size: b.size).insetBy(dx: -45, dy: -45).contains(local)
            for i in 0..<b.optionCount where RingModel.optionRect(i, in: b).insetBy(dx: -3, dy: -4).contains(local) { option = i }
        }
        // Moving onto the bubble opens up the whole question. It grows upward from its bottom
        // edge so the answer buttons stay under the pointer.
        if let b = model.bubble, !b.expanded, let id = model.highlighted, expandedFor != id,
           let a = model.slices.first(where: { $0.id == id })?.agent, a.isLongQuestion {
            let local = CGPoint(x: rel.width - b.offset.width + b.size.width / 2,
                                y: rel.height - b.offset.height + b.size.height / 2)
            if CGRect(origin: .zero, size: b.size).insetBy(dx: -6, dy: -6).contains(local) {
                expandedFor = id
                anchor = (b.offset.width, b.offset.height + b.size.height / 2)
                placeBubble()
                return
            }
        }
        if option != model.hoveredOption {
            model.hoveredOption = option
            if option != nil { onAim?() }
        }
        pointerOnBubble = overBubble
        pointerOnWheel = r <= model.outerRadius + 22 && model.target(for: rel) != nil
        // A notice is small, so it lets go sooner than a wheel with bubbles around it.
        if !overBubble && r > (model.notice != nil ? 300 : model.outerRadius + 330) { close(); return }

        // Which wedge is aimed at only changes while the pointer is on the wheel itself,
        // so travelling out to the bubble keeps that agent selected.
        guard r <= model.outerRadius + 22, !overBubble || r <= model.outerRadius else { return }
        let aim = model.target(for: rel)
        if aim != model.highlighted {
            model.highlighted = aim
            model.sentOption = nil
            expandedFor = nil
            anchor = nil
            placeBubble()
            if aim != nil { onAim?() }
        }
    }

    /// Put the speech bubble just outside the highlighted wedge, kept on screen.
    private func placeBubble() {
        guard let s = model.slices.first(where: { $0.id == model.highlighted }), s.agent.hasSpeech else {
            model.bubble = nil
            return
        }
        if s.agent.message != lastQuestion {
            // A new question: start again from the preview.
            lastQuestion = s.agent.message
            model.sentOption = nil
            expandedFor = nil
            anchor = nil
        }
        let expanded = expandedFor == s.id
        let metrics = RingModel.bubbleMetrics(for: s.agent, expanded: expanded)
        let size = metrics.size
        let dx = CGFloat(cos(s.mid)), dy = CGFloat(sin(s.mid))
        let reach = s.outer + 54 + abs(dx) * size.width / 2 + abs(dy) * size.height / 2
        var pos = CGPoint(x: dx * reach, y: dy * reach)
        if expanded, let anchor { pos = CGPoint(x: anchor.x, y: anchor.bottom - size.height / 2) }
        // Keep it inside the screen the wheel is on.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let here = CGPoint(x: centre.x, y: primaryHeight - centre.y)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(here, $0.frame, false) }) {
            let v = screen.visibleFrame
            let minX = v.minX - centre.x + size.width / 2 + 10, maxX = v.maxX - centre.x - size.width / 2 - 10
            let top = primaryHeight - v.maxY, bottom = primaryHeight - v.minY
            let minY = top - centre.y + size.height / 2 + 10, maxY = bottom - centre.y - size.height / 2 - 10
            if minX < maxX { pos.x = min(max(pos.x, minX), maxX) }
            if minY < maxY { pos.y = min(max(pos.y, minY), maxY) }
        }
        // The explanation card goes on whichever side of the bubble has room.
        var hintOnLeft = false
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(here, $0.frame, false) }) {
            hintOnLeft = centre.x + pos.x + size.width / 2 + 330 > screen.visibleFrame.maxX
        }
        // The tail points back at the middle of the wedge.
        let anchor = CGPoint(x: dx * (s.inner + s.outer) / 2, y: dy * (s.inner + s.outer) / 2)
        let vx = anchor.x - pos.x, vy = anchor.y - pos.y
        let len = max(1, hypot(vx, vy))
        model.bubble = RingModel.Bubble(offset: CGSize(width: pos.x, height: pos.y), size: size,
                                        toward: CGSize(width: vx / len, height: vy / len),
                                        textHeight: metrics.textHeight, optionCount: metrics.options, expanded: expanded,
                                        hintOnLeft: hintOnLeft)
    }

    /// Pick whatever is aimed at (or just close when nothing is).
    func choose() {
        // A notice has nothing to pick: any click or tap just closes it.
        if model.notice != nil { close(); return }
        let picked = model.slices.first { $0.id == model.highlighted }?.agent
        // On an answer button: send that answer and stay open for the next question.
        if let option = model.hoveredOption, let picked, picked.needsYou {
            guard model.sentOption == nil else { return }
            if option >= picked.speech.options.count {
                // The free-text choice: swap the wheel for a text box where the bubble was.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let b = model.bubble
                let spot = CGPoint(x: centre.x + (b?.offset.width ?? 0),
                                   y: primaryHeight - (centre.y + (b?.offset.height ?? 0) + (b?.size.height ?? 0) / 2 - 60))
                close()
                onType?(picked, spot)
                return
            }
            model.sentOption = option
            onAnswer?(picked, option)
            return
        }
        // A click on the bubble itself (not on a button) does nothing.
        if pointerOnBubble && !pointerOnWheel { return }
        // Without the Herdr app there is nowhere to jump to; say so rather than closing on a click that did nothing.
        if pointerOnWheel, let picked, !model.canJump {
            Log.write("agents: can't jump to \(picked.id), the Herdr app is not installed")
            model.highlighted = nil
            model.bubble = nil
            model.hoveredOption = nil
            model.slices = []
            model.notice = .noApp
            model.heldNotice = true
            pointerOnWheel = false
            pointerOnBubble = false
            return
        }
        close()
        // Only a click on a wedge opens that agent; clicking anywhere else just dismisses the wheel.
        if pointerOnWheel, let picked { onChoose?(picked) }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        model.active = false
    }
}


// MARK: - Typing an answer

/// A borderless panel that can still take the keyboard.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ReplyView: View {
    let agent: AgentInfo
    let send: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let ink = Color(white: 0.10)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Palette.accent).frame(width: 8, height: 8)
                Text("\(agent.space.uppercased())  ·  YOUR ANSWER")
                    .font(.system(size: 10, weight: .heavy)).kerning(0.5).foregroundStyle(Palette.accent)
            }
            Text(agent.speech.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.35)).lineLimit(3)
            TextField("Type your answer…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(ink)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.94)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.accent, lineWidth: 2))
                .focused($focused)
                .onSubmit { submit() }
            HStack {
                Text("Return to send  ·  Esc to cancel").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color(white: 0.45))
                Spacer()
                Button("Send") { submit() }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(ink, lineWidth: 2.5))
        .padding(14)   // room for the shadow
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .colorScheme(.light)
        .onExitCommand { cancel() }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { send(t) }
    }
}

/// A small text box for answering an agent in your own words.
final class ReplyBox: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var previous: NSRunningApplication?

    var isOpen: Bool { panel != nil }

    func show(for agent: AgentInfo, at spot: CGPoint, send: @escaping (String) -> Void) {
        close(restore: false)
        previous = NSWorkspace.shared.frontmostApplication
        let host = NSHostingView(rootView: ReplyView(agent: agent, send: { [weak self] text in
            send(text)
            self?.close(restore: true)
        }, cancel: { [weak self] in self?.close(restore: true) }))
        let size = host.fittingSize
        var origin = CGPoint(x: spot.x - size.width / 2, y: spot.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(spot, $0.frame, false) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
            origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height - 8)
        }
        let p = KeyPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        p.delegate = self
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// Clicking away cancels.
    func windowDidResignKey(_ notification: Notification) { close(restore: false) }

    func close(restore: Bool) {
        guard let p = panel else { return }
        panel = nil
        p.delegate = nil
        p.orderOut(nil)
        // Hand the keyboard back to whatever was in front.
        if restore, let app = previous, let url = app.bundleURL, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        previous = nil
    }
}
