import SwiftUI

extension MouseProfile {
    /// Logitech MX Master 4. The picture is a 660 × 520 canvas.
    static let mxMaster4 = MouseProfile(
        id: "mxMaster4",
        name: "MX Master 4",
        productIDs: [0xB042],
        nameContains: ["MX Master 4"],
        controls: [
            MouseControl(
                slot: .middle, title: "Wheel click",
                blurb: "Pressing down on the scroll wheel.",
                source: .button(2),
                rect: CGRect(x: 338, y: 96, width: 24, height: 64), shape: .wheel,
                chip: CGPoint(x: 568, y: 128), chipOnLeft: false),
            MouseControl(
                slot: .modeShift, title: "Top button",
                blurb: "The small button behind the scroll wheel. Out of the box it switches the wheel between ratchet and free-spin.",
                source: .hidpp(cid: 0x00C4),
                rect: CGRect(x: 341, y: 172, width: 18, height: 28),
                chip: CGPoint(x: 568, y: 204), chipOnLeft: false),
            MouseControl(
                slot: .thumbWheel, title: "Thumb wheel",
                blurb: "The little wheel by your thumb. Out of the box it scrolls sideways.",
                source: .thumbWheel,
                rect: CGRect(x: 250, y: 118, width: 14, height: 46), shape: .wheel,
                chip: CGPoint(x: 92, y: 58), chipOnLeft: true),
            MouseControl(
                slot: .gesture, title: "Gesture button",
                blurb: "The side button nearest the front. Click it, or hold it and move the mouse for four more actions.",
                source: .button(5, cid: 0x00C3), gestures: true,
                rect: CGRect(x: 249, y: 174, width: 15, height: 28),
                chip: CGPoint(x: 92, y: 126), chipOnLeft: true),
            MouseControl(
                slot: .forward, title: "Forward button",
                blurb: "The front one of the two thumb buttons.",
                source: .button(4),
                rect: CGRect(x: 248, y: 206, width: 15, height: 28),
                chip: CGPoint(x: 92, y: 194), chipOnLeft: true),
            MouseControl(
                slot: .back, title: "Back button",
                blurb: "The rear one of the two thumb buttons.",
                source: .button(3),
                rect: CGRect(x: 248, y: 238, width: 15, height: 28),
                chip: CGPoint(x: 92, y: 262), chipOnLeft: true),
            MouseControl(
                slot: .thumbPanel, title: "Haptic panel",
                blurb: "The pressable pad under your thumb. With “Drag the window”, point at any window, hold the pad and move the mouse; let go to drop it. A quick tap opens the agent ring.",
                source: .button(6, cid: 0x01A0), pulsesOverTap: true, orAnyUnlistedControl: true,
                rect: CGRect(x: 203, y: 312, width: 50, height: 108), shape: .pad(tilt: -7),
                chip: CGPoint(x: 92, y: 372), chipOnLeft: true),
        ],
        firstSelected: .thumbPanel,
        hasHaptics: true,
        defaults: [
            .middle: .standard,
            .modeShift: .standard,
            .thumbPanel: Action(kind: "dragWindow"),
            .thumbWheel: .standard,
            .back: Action(kind: "back"),
            .forward: Action(kind: "forward"),
            .gesture: Action(kind: "missionControl"),
            .gestureUp: Action(kind: "missionControl"),
            .gestureDown: Action(kind: "appExpose"),
            .gestureLeft: Action(kind: "spaceLeft"),
            .gestureRight: Action(kind: "spaceRight"),
        ],
        directLinkWhy: "Lets MouseHerdr feel when the haptic panel and top button are held and released.",
        art: MouseArt(
            size: CGSize(width: 660, height: 520),
            body: {
                var p = Path()
                p.move(to: CGPoint(x: 350, y: 40))
                p.addCurve(to: CGPoint(x: 438, y: 150), control1: CGPoint(x: 400, y: 40), control2: CGPoint(x: 432, y: 90))
                p.addCurve(to: CGPoint(x: 440, y: 340), control1: CGPoint(x: 444, y: 210), control2: CGPoint(x: 446, y: 280))
                p.addCurve(to: CGPoint(x: 345, y: 492), control1: CGPoint(x: 432, y: 430), control2: CGPoint(x: 400, y: 492))
                p.addCurve(to: CGPoint(x: 258, y: 380), control1: CGPoint(x: 295, y: 492), control2: CGPoint(x: 262, y: 440))
                p.addCurve(to: CGPoint(x: 262, y: 150), control1: CGPoint(x: 254, y: 300), control2: CGPoint(x: 256, y: 210))
                p.addCurve(to: CGPoint(x: 350, y: 40), control1: CGPoint(x: 268, y: 90), control2: CGPoint(x: 300, y: 40))
                p.closeSubpath()
                return p
            }(),
            // The thumb rest.
            wing: {
                var p = Path()
                p.move(to: CGPoint(x: 264, y: 266))
                p.addCurve(to: CGPoint(x: 188, y: 352), control1: CGPoint(x: 232, y: 270), control2: CGPoint(x: 198, y: 305))
                p.addCurve(to: CGPoint(x: 214, y: 450), control1: CGPoint(x: 180, y: 396), control2: CGPoint(x: 187, y: 436))
                p.addCurve(to: CGPoint(x: 300, y: 476), control1: CGPoint(x: 244, y: 464), control2: CGPoint(x: 275, y: 474))
                p.addLine(to: CGPoint(x: 300, y: 266))
                p.closeSubpath()
                return p
            }(),
            // Seams between the two main buttons and the palm.
            seams: {
                var p = Path()
                p.move(to: CGPoint(x: 350, y: 42)); p.addLine(to: CGPoint(x: 350, y: 92))
                p.move(to: CGPoint(x: 350, y: 206)); p.addLine(to: CGPoint(x: 350, y: 240))
                p.move(to: CGPoint(x: 259, y: 258))
                p.addQuadCurve(to: CGPoint(x: 441, y: 258), control: CGPoint(x: 350, y: 232))
                return p
            }(),
            shadow: CGRect(x: 210, y: 448, width: 250, height: 60)))
}
