import XCTest
@testable import MouseHerdr

/// Answering an agent from the wheel.
///
/// An answer is a key that herdr-core presses in the agent's terminal. herdr-core holds a key
/// back until that terminal has had about 3 seconds with no input from a person, and pointer
/// movement over the agent's pane is such input when the agent asks its terminal to report it,
/// as Claude Code does. The wheel used to let the pointer through to the pane it was opened
/// over, so every movement on the wheel held the answer back again, while the button showed a
/// green tick from the moment it was clicked. After 10 seconds MouseHerdr gave up and logged
/// that the answer was not sent, although herdr-core still pressed the key later.
///
/// These tests are here so that it is noticed if any of that comes back.
final class WheelAnswerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        // A short path: a herdr-core started in here keeps its socket in it, and socket paths are short.
        scratch = URL(fileURLWithPath: "/tmp/mh-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Nothing a test does is written into the log of the copy that is really running.
        Log.override = scratch.appendingPathComponent("log")
    }

    override func tearDown() {
        unsetenv("MOUSEHERDR_HC")
        Log.drain()
        Log.override = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    /// An agent that is waiting on a person, as the wheel knows it.
    private func asking(_ id: String) -> AgentInfo {
        var a = AgentInfo(id: id, agent: "claude-code", status: "blocked", space: "space", tab: "1")
        a.kind = "question"
        a.message = "answer: Which fruit? (Apple · Banana · Cherry)"
        return a
    }

    private func script(_ name: String, _ text: String) throws -> URL {
        let file = scratch.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// A stand-in for `hc` that takes `seconds` over a call, as herdr-core does over a key it is
    /// holding back, and then answers as herdr-core does or fails. Every call is noted in the
    /// file that comes back.
    private func standIn(seconds: Double = 0, fails: Bool = false) throws -> URL {
        let calls = scratch.appendingPathComponent("calls")
        let hc = try script("hc", """
        #!/bin/sh
        echo "$@" >> '\(calls.path)'
        sleep \(seconds)
        \(fails ? "exit 1" : #"printf '{"status":"blocked","turn":1}'"#)
        """)
        setenv("MOUSEHERDR_HC", hc.path, 1)
        return calls
    }

    /// Let the main thread get on with things until `done` says so, or the time is up.
    private func wait(upTo seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func logged() -> String {
        Log.drain()
        return (try? String(contentsOf: scratch.appendingPathComponent("log"))) ?? ""
    }

    /// What a window on an agent has drawn so far. It is added to from another thread.
    private final class Drawn {
        private var data = Data()
        private let lock = NSLock()

        func add(_ more: Data) {
            lock.lock()
            data.append(more)
            lock.unlock()
        }

        func contains(_ text: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return data.range(of: Data(text.utf8)) != nil
        }
    }

    // MARK: The wheel keeps the pointer from the pane underneath

    func testTheWheelTakesThePointerOverItsWholeCanvas() {
        let panel = AgentRing.makePanel(showing: RingModel())
        // Not passed through to the window underneath. That window may be the pane of the agent
        // being answered, which reports each movement as input, and input holds the answer back.
        XCTAssertFalse(panel.ignoresMouseEvents)
        // The whole canvas, the see-through parts as well: a see-through window that has not been
        // told takes the pointer only where something is drawn on it.
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.frame.size, CGSize(width: AgentRing.canvas, height: AgentRing.canvas))
        // It still never becomes the window in front, so the keyboard stays where it was.
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testAClickThatReachesTheWheelIsActedOn() throws {
        // The button tap picks clicks up before any window sees them. Without it, a wheel that
        // takes the pointer would swallow them.
        let panel = AgentRing.makePanel(showing: RingModel())
        var clicks: [Bool] = []
        panel.onClick = { clicks.append($0) }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        XCTAssertEqual(clicks, [false, true], "a left click, then a right click")
    }

    func testAWheelAskedToCloseStaysForAnAnswerOnItsWayButNotForLong() {
        let opened = Date(timeIntervalSince1970: 1000)
        func after(_ seconds: TimeInterval) -> Date { opened.addingTimeInterval(seconds) }
        // Nothing on its way: it closes at once.
        XCTAssertNil(AgentRing.stayUntil(opened: opened, picked: nil, now: after(1)))
        // Picked soon after the wheel opened: what the pointer did over the pane just before can
        // hold the answer back until herdr-core's 3 seconds are up. Closed now, with the pointer
        // then moving over the pane, the answer would wait for as long as it moved.
        XCTAssertEqual(AgentRing.stayUntil(opened: opened, picked: after(1.5), now: after(2)), after(AgentRing.quietWait))
        XCTAssertGreaterThan(AgentRing.quietWait, 3)
        // Picked long after: the pane has been left alone all that time, so it goes in at once.
        XCTAssertEqual(AgentRing.stayUntil(opened: opened, picked: after(20), now: after(20.2)), after(21))
        // And the wait has an end, whatever is holding the answer.
        XCTAssertNil(AgentRing.stayUntil(opened: opened, picked: after(1.5), now: after(AgentRing.quietWait)))
        XCTAssertLessThan(AgentRing.quietWait, 5)
    }

    // MARK: Picking an answer on the wheel

    /// A wheel that is open on one agent and aimed at it, without being put on the screen.
    /// `onItsWay` is the choice of an answer picked earlier that herdr-core still holds, if any.
    private func wheel(on agent: AgentInfo, onItsWay: Int? = nil) -> AgentRing {
        let ring = AgentRing(onScreen: false)
        ring.answerOnItsWay = { $0 == agent.id ? onItsWay : nil }
        ring.show([agent], herdr: .running(agents: 1), appInstalled: true)
        ring.model.highlighted = agent.id       // aimed at, wherever the pointer happens to be
        // The agents have been looked at since the wheel opened, so the question is the current one.
        ring.update([agent], herdr: .running(agents: 1), appInstalled: true)
        addTeardownBlock { ring.close() }
        return ring
    }

    func testAnAnswerPickedOnTheWheelIsOnItsWayUntilHerdrCoreHasPressedIt() {
        let agent = asking("t7")
        let ring = wheel(on: agent)
        var picks: [Int] = []
        ring.onAnswer = { _, option in picks.append(option) }

        ring.model.hoveredOption = 1
        ring.choose()
        XCTAssertEqual(picks, [1])
        XCTAssertEqual(ring.model.buttonState(1), .sending, "clicked is not the same as delivered")
        XCTAssertTrue(ring.isOpen, "the wheel stays for the next question")

        // Clicking again while it is on its way sends nothing more.
        ring.model.hoveredOption = 0
        ring.choose()
        XCTAssertEqual(picks, [1])

        // What comes back for another agent, or for another choice, changes nothing here.
        ring.answered(asking("t9"), option: 1, .delivered(late: false))
        ring.answered(agent, option: 0, .delivered(late: false))
        XCTAssertEqual(ring.model.buttonState(1), .sending)

        ring.answered(agent, option: 1, .delivered(late: false))
        XCTAssertEqual(ring.model.buttonState(1), .sent)
    }

    func testAnAnswerThatCouldNotBeSentCanBePickedAgainOnTheWheel() {
        let agent = asking("t7")
        let ring = wheel(on: agent)
        var picks: [Int] = []
        ring.onAnswer = { _, option in picks.append(option) }
        ring.model.hoveredOption = 1
        ring.choose()
        ring.answered(agent, option: 1, .failed)
        XCTAssertEqual(ring.model.buttonState(1), .failed)

        ring.model.hoveredOption = 1
        ring.choose()
        XCTAssertEqual(picks, [1, 1])
        XCTAssertEqual(ring.model.buttonState(1), .sending)
    }

    func testAnAnswerStillOnItsWayFromBeforeIsShownAndBlocksAnother() {
        // Picked from a wheel that has since been closed, and still held by herdr-core. The report
        // that led to these tests had exactly this: a second click, from a wheel opened again.
        let agent = asking("t7")
        let ring = wheel(on: agent, onItsWay: 2)
        var picks: [Int] = []
        ring.onAnswer = { _, option in picks.append(option) }
        XCTAssertEqual(ring.model.buttonState(2), .sending)
        XCTAssertFalse(ring.model.canAnswer)

        ring.model.hoveredOption = 0
        ring.choose()
        XCTAssertTrue(picks.isEmpty, "another would be pressed right after it, on whatever is asked next")
    }

    func testAWheelClosedWhileAnAnswerIsOnItsWayStaysUntilItHasGoneIn() {
        let agent = asking("t7")
        let ring = wheel(on: agent)
        ring.model.hoveredOption = 2
        ring.choose()

        // Escape, a moment after picking. Put away now, the pointer would be back on the agent's
        // pane, and moving there holds the answer back.
        ring.dismiss()
        XCTAssertTrue(ring.isOpen)
        XCTAssertTrue(ring.model.leaving)
        XCTAssertEqual(ring.model.answerNote, "Sending… the wheel closes once it has gone in")
        // Nothing more can be picked from a wheel that is on its way out.
        var picks = 0
        ring.onAnswer = { _, _ in picks += 1 }
        ring.model.hoveredOption = 0
        ring.choose()
        XCTAssertEqual(picks, 0)
        XCTAssertTrue(ring.isOpen)

        ring.answered(agent, option: 2, .delivered(late: false))
        XCTAssertEqual(ring.model.buttonState(2), .sent)
        wait(upTo: 3) { !ring.isOpen }
        XCTAssertFalse(ring.isOpen, "and goes once the answer is in")
    }

    func testOpeningAnAgentWaitsForTheAnswerThatIsOnItsWayToIt() {
        // Opening the agent brings its pane under the pointer, as closing the wheel does.
        let agent = asking("t7")
        let ring = wheel(on: agent)
        var opened: [String] = []
        ring.onChoose = { opened.append($0.id) }
        ring.model.hoveredOption = 2
        ring.choose()

        ring.model.hoveredOption = nil
        ring.model.onHub = true         // a click on the middle of the wheel, which stands for the agent
        ring.choose()
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(ring.model.leaving)

        ring.answered(agent, option: 2, .delivered(late: false))
        wait(upTo: 3) { !ring.isOpen }
        XCTAssertEqual(opened, ["t7"])
    }

    func testAWheelWithNoAnswerOnItsWayClosesAtOnce() {
        let ring = wheel(on: asking("t7"))
        ring.dismiss()
        XCTAssertFalse(ring.isOpen)
        // So does one whose answer has gone in.
        let agent = asking("t8")
        let other = wheel(on: agent)
        other.model.hoveredOption = 0
        other.choose()
        other.answered(agent, option: 0, .delivered(late: false))
        other.dismiss()
        XCTAssertFalse(other.isOpen)
    }

    // MARK: The bubble says what is true

    func testAPickedAnswerShowsAsSentOnlyOnceHerdrCoreHasPressedIt() {
        let model = RingModel()
        model.confirmed = true
        XCTAssertTrue(model.canAnswer)
        XCTAssertNil(model.answerNote)

        model.sentOption = 1        // picked
        XCTAssertEqual(model.buttonState(1), .sending, "picked is not delivered")
        XCTAssertEqual(model.buttonState(0), .resting)
        XCTAssertEqual(model.answerNote, "Sending…")
        XCTAssertFalse(model.canAnswer, "another would be pressed right after it, on the next question")

        model.held = true           // herdr-core is holding it back
        XCTAssertEqual(model.buttonState(1), .sending)
        XCTAssertEqual(model.answerNote, "herdr-core sends it once that terminal has been quiet for 3 s…")

        model.delivery = .delivered(late: false)
        XCTAssertEqual(model.buttonState(1), .sent)
        XCTAssertEqual(model.answerNote, "Sent — waiting for the agent…")
        XCTAssertFalse(model.canAnswer, "one answer to a question")
    }

    func testAnAnswerThatCouldNotBeSentSaysSoAndCanBeTriedAgain() {
        let model = RingModel()
        model.confirmed = true
        model.sentOption = 0
        model.delivery = .failed
        XCTAssertEqual(model.buttonState(0), .failed)
        XCTAssertEqual(model.answerNote, "Could not send it — click an answer to try again")
        XCTAssertTrue(model.canAnswer)
    }

    func testAnAnswerHerdrCoreStillHoldsIsNeitherSentNorLost() {
        let model = RingModel()
        model.confirmed = true
        model.sentOption = 2
        model.delivery = .stillHeld
        XCTAssertEqual(model.buttonState(2), .sending)
        XCTAssertEqual(model.answerNote, "Still held by herdr-core until that terminal is quiet")
        XCTAssertFalse(model.canAnswer, "it will still be pressed, and another would follow it")
        // One that went in after the agent had moved on did not answer the question.
        model.delivery = .delivered(late: true)
        XCTAssertEqual(model.answerNote, "Sent, but the agent had already moved on")
    }

    func testAWheelThatIsLeavingSaysItIsWaitingForTheAnswer() {
        let model = RingModel()
        model.confirmed = true
        model.sentOption = 0
        model.leaving = true
        XCTAssertEqual(model.answerNote, "Sending… the wheel closes once it has gone in")
    }

    // MARK: What became of a key

    func testWhatBecameOfAKeyIsReadFromHowHcKeysWent() {
        func said(_ json: String) -> AgentWatcher.Ran { .output(Data(json.utf8)) }
        // herdr-core names the agent's status at the moment the key went in.
        XCTAssertEqual(AgentWatcher.delivery(of: said(#"{"status":"blocked","turn":3}"#)), .delivered(late: false))
        XCTAssertEqual(AgentWatcher.delivery(of: said(#"{"status":"error","turn":3}"#)), .delivered(late: false))
        // An agent that had stopped waiting by then got the key somewhere else than in its question.
        for status in [#""working""#, #""done""#, #""idle""#, "null"] {
            XCTAssertEqual(AgentWatcher.delivery(of: said(#"{"status":\#(status),"turn":4}"#)), .delivered(late: true), status)
        }
        XCTAssertEqual(AgentWatcher.delivery(of: said("")), .delivered(late: true), "pressed, and nothing known about the agent")
        XCTAssertEqual(AgentWatcher.delivery(of: .failed), .failed)
        // Given up on is not "not sent": herdr-core keeps the key and presses it when the terminal goes quiet.
        XCTAssertEqual(AgentWatcher.delivery(of: .gaveUp), .stillHeld)
    }

    func testAnAnswerIsCalledSentOnlyOnceHcKeysHasFinishedAndAnotherIsRefusedMeanwhile() throws {
        let calls = try standIn(seconds: 1.2)       // herdr-core holds the key back for a while
        let watcher = AgentWatcher()
        let agent = asking("t7")
        var outcome: AgentWatcher.Delivery?
        watcher.answer(agent, option: 2) { outcome = $0 }

        // On its way. Nothing is claimed either way, and it is known which answer it is.
        wait(upTo: 0.4) { false }
        XCTAssertNil(outcome, "herdr-core has not pressed the key yet")
        XCTAssertEqual(watcher.answering["t7"], 2)
        // Another to the same agent would be pressed right after it, on whatever is asked next.
        var second: AgentWatcher.Delivery?
        watcher.answer(agent, option: 0) { second = $0 }
        XCTAssertEqual(second, .refused)

        wait(upTo: 6) { outcome != nil }
        XCTAssertEqual(outcome, .delivered(late: false))
        XCTAssertNil(watcher.answering["t7"])
        XCTAssertEqual(try String(contentsOf: calls), "keys t7 3\n", "one key was asked for, the third choice")
        let log = logged()
        // At least as long as the stand-in held it. Starting the stand-in adds to that, by more
        // on a busy machine, so there is no upper bound.
        let held = log.components(separatedBy: "herdr-core held the answer to t7 for ").dropFirst().first
            .flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(held, log), 1.2, log)
        XCTAssertFalse(log.contains("the answer was not sent"), log)
    }

    func testAnAnswerHerdrCoreTurnsDownIsReportedAsNotSent() throws {
        _ = try standIn(fails: true)
        var outcome: AgentWatcher.Delivery?
        AgentWatcher().answer(asking("t7"), option: 0) { outcome = $0 }
        wait(upTo: 6) { outcome != nil }
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(logged().contains("hc keys failed; the answer was not sent"))
    }

    func testWithoutHcAnAnswerIsReportedAsNotSent() {
        setenv("MOUSEHERDR_HC", scratch.appendingPathComponent("no-such-command").path, 1)
        var outcome: AgentWatcher.Delivery?
        AgentWatcher().answer(asking("t7"), option: 0) { outcome = $0 }
        wait(upTo: 6) { outcome != nil }
        XCTAssertEqual(outcome, .failed)
    }

    func testGivingUpOnAKeyDoesNotMeanItWasNotSent() throws {
        // Longer than herdr-core can be expected to hold a key, which is as long as the pointer
        // keeps moving over the agent's pane. The 10 seconds this used to be was not.
        XCTAssertGreaterThanOrEqual(AgentWatcher.keysTimeout, 60)

        _ = try standIn(seconds: 3)
        let agent = asking("t7")
        let done = expectation(description: "the wait for the key is over")
        var outcome: AgentWatcher.Delivery?
        DispatchQueue.global().async {
            outcome = AgentWatcher.press("1", in: agent, timeout: 0.3)
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        XCTAssertEqual(outcome, .stillHeld)
        let log = logged()
        XCTAssertTrue(log.contains("herdr-core still holds the answer to t7"), log)
        XCTAssertFalse(log.contains("the answer was not sent"), log)
    }

    // herdr-core holds an answer back on purpose: a key until the terminal has had about 3 seconds
    // with no input from a person, and typed text for up to 60 seconds after a person's last key
    // while they have a draft there.
    func testAnswersAreWaitedForFarLongerThanALook() {
        XCTAssertGreaterThan(AgentWatcher.sendTimeout, 60)
        // Looking at the agents stays quick, so a stuck herdr-core is noticed soon.
        XCTAssertLessThan(AgentWatcher.timeout, 10)
        XCTAssertLessThan(AgentWatcher.timeout, AgentWatcher.keysTimeout)
    }

    // MARK: With herdr-core itself

    /// The whole of it, against the real herdr-core when it is installed: an agent's pane that
    /// reports pointer movement, a window on it with the pointer moving over it, and an answer
    /// picked meanwhile.
    ///
    /// herdr-core gets a core of its own for this, with its own session name and folders, and the
    /// stand-in agent is spoken to by a name that no real terminal has. Nothing here can reach a
    /// terminal of yours.
    func testWithHerdrCoreAnAnswerIsHeldWhileThePointerMovesOverThePaneAndGoesInOnceItRests() throws {
        unsetenv("MOUSEHERDR_HC")
        guard let real = AgentWatcher.tool("hc") else { throw XCTSkip("herdr-core is not installed") }
        let tag = scratch.lastPathComponent.suffix(8)
        let name = "mh-test-agent-\(tag)"
        let hc = try script("hc", """
        #!/bin/sh
        unset HC_TERMINAL_SOCKET HC_TERMINAL_ID HC_SCOPE HC_SOCKET
        export HC_SESSION='mhtest\(tag)'
        export XDG_CONFIG_HOME='\(scratch.path)/config' XDG_STATE_HOME='\(scratch.path)/state'
        export XDG_DATA_HOME='\(scratch.path)/data' XDG_CACHE_HOME='\(scratch.path)/cache'
        export XDG_RUNTIME_DIR='\(scratch.path)/run'
        mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
        exec '\(real)' "$@"
        """)
        setenv("MOUSEHERDR_HC", hc.path, 1)
        addTeardownBlock {
            _ = AgentWatcher.launch(hc.path, ["kill", name], timeout: 10)
            _ = AgentWatcher.launch(hc.path, ["server", "stop"], timeout: 10)
        }

        // The agent: it tells herdr-core that it is waiting on a person, asks its terminal to
        // report every pointer movement, as Claude Code does, and keeps every byte it is sent.
        let got = scratch.appendingPathComponent("got")
        let standInAgent = try script("agent", #"""
        #!/bin/sh
        stty raw -echo
        printf '\033]7501;state=blocked:kind=question\007\033[?1003h\033[?1006h'
        exec cat > "$1"
        """#)
        guard case .output = AgentWatcher.launch(hc.path, ["run", "--bg", "--name", name, "--", standInAgent.path, got.path], timeout: 20) else {
            throw XCTSkip("this herdr-core would not start a terminal")
        }
        /// What the agent has been sent, without the reports of the pointer moving.
        func typed() -> String {
            let all = (try? String(contentsOf: got, encoding: .isoLatin1)) ?? ""
            return all.replacingOccurrences(of: "\u{1B}\\[<[0-9;]*[Mm]", with: "", options: .regularExpression)
        }
        var asks = false
        wait(upTo: 10) {
            if case .output(let data) = AgentWatcher.launch(hc.path, ["get", name, "--json"]),
               let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? [String: Any] {
                asks = status["state"] as? String == "blocked"
            }
            return asks
        }
        try XCTSkipUnless(asks, "the stand-in agent did not come up asking")

        // A window on the agent, as the Herdr app is one, on a terminal of its own.
        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        try XCTSkipUnless(openpty(&master, &slave, nil, nil, &size) == 0, "no terminal to be had for the window")
        let window = Process()
        window.executableURL = hc
        window.arguments = ["attach", name]
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        window.standardInput = terminal
        window.standardOutput = terminal
        window.standardError = terminal
        try window.run()
        let screen = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let drawn = Drawn()
        screen.readabilityHandler = { drawn.add($0.availableData) }
        addTeardownBlock {
            screen.readabilityHandler = nil
            window.terminate()
        }
        // The window is up once it has been told what the agent asked of its terminal: to report
        // every pointer movement. Until then, what the pointer does goes nowhere.
        wait(upTo: 10) { drawn.contains("\u{1B}[?1003h") }
        try XCTSkipUnless(drawn.contains("\u{1B}[?1003h"), "the window on the agent did not come up")

        // The pointer moves over the pane for a second and a half…
        let moving: TimeInterval = 1.5
        let began = Date()
        var column = 10
        let pointer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard Date().timeIntervalSince(began) < moving else { timer.invalidate(); return }
            column += 1
            screen.write(Data("\u{1B}[<35;\(column);12M".utf8))        // moved, with no button held
        }
        defer { pointer.invalidate() }
        // …and meanwhile the third choice is picked.
        wait(upTo: 0.5) { false }
        var outcome: AgentWatcher.Delivery?
        let picked = Date()
        AgentWatcher().answer(asking(name), option: 2) { outcome = $0 }

        // While the pointer moves, the agent has not got the answer, and nobody says that it has.
        wait(upTo: 0.8) { false }
        XCTAssertFalse(typed().contains("3"), "herdr-core holds the key while the pointer moves over the pane")
        XCTAssertNil(outcome, "an answer that is being held is not sent yet, and has not failed")

        // Once the pointer has rested for about 3 seconds, the answer goes in, and only then is it called sent.
        wait(upTo: 12) { outcome != nil }
        let took = Date().timeIntervalSince(picked)
        XCTAssertEqual(outcome, .delivered(late: false))
        XCTAssertEqual(typed(), "3", "the agent got the answer, once")
        XCTAssertGreaterThan(took, 2.5, "it went in only after the pointer had rested")
        let log = logged()
        XCTAssertTrue(log.contains("herdr-core held the answer to \(name) for "), log)
        XCTAssertFalse(log.contains("the answer was not sent"), log)
    }
}
