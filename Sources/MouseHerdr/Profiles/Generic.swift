import SwiftUI

extension MouseProfile {
    /// Used when the connected Logitech mouse isn't one we know: only the three buttons
    /// every mouse has, on a plain drawing. It matches nothing; it is the fallback.
    static let generic = MouseProfile(
        id: "generic",
        name: "Generic mouse",
        controls: [
            MouseControl(
                slot: .middle, title: "Wheel click",
                blurb: "Pressing down on the scroll wheel.",
                source: .button(2),
                rect: CGRect(x: 318, y: 118, width: 24, height: 64), shape: .wheel,
                chip: CGPoint(x: 568, y: 150), chipOnLeft: false),
            MouseControl(
                slot: .forward, title: "Forward button",
                blurb: "The front one of the two side buttons.",
                source: .button(4),
                rect: CGRect(x: 233, y: 232, width: 14, height: 32),
                chip: CGPoint(x: 92, y: 214), chipOnLeft: true),
            MouseControl(
                slot: .back, title: "Back button",
                blurb: "The rear one of the two side buttons.",
                source: .button(3),
                rect: CGRect(x: 233, y: 270, width: 14, height: 32),
                chip: CGPoint(x: 92, y: 288), chipOnLeft: true),
        ],
        firstSelected: .middle,
        hasHaptics: false,
        defaults: [
            .middle: .standard,
            .back: Action(kind: "back"),
            .forward: Action(kind: "forward"),
        ],
        directLinkWhy: "Lets MouseHerdr talk to the mouse directly, to show its battery level.",
        art: MouseArt(
            size: CGSize(width: 660, height: 520),
            body: {
                var p = Path()
                p.move(to: CGPoint(x: 330, y: 60))
                p.addCurve(to: CGPoint(x: 420, y: 170), control1: CGPoint(x: 385, y: 60), control2: CGPoint(x: 420, y: 105))
                p.addLine(to: CGPoint(x: 420, y: 350))
                p.addCurve(to: CGPoint(x: 330, y: 460), control1: CGPoint(x: 420, y: 415), control2: CGPoint(x: 385, y: 460))
                p.addCurve(to: CGPoint(x: 240, y: 350), control1: CGPoint(x: 275, y: 460), control2: CGPoint(x: 240, y: 415))
                p.addLine(to: CGPoint(x: 240, y: 170))
                p.addCurve(to: CGPoint(x: 330, y: 60), control1: CGPoint(x: 240, y: 105), control2: CGPoint(x: 275, y: 60))
                p.closeSubpath()
                return p
            }(),
            seams: {
                var p = Path()
                p.move(to: CGPoint(x: 330, y: 62)); p.addLine(to: CGPoint(x: 330, y: 112))
                p.move(to: CGPoint(x: 330, y: 188)); p.addLine(to: CGPoint(x: 330, y: 226))
                p.move(to: CGPoint(x: 241, y: 244))
                p.addQuadCurve(to: CGPoint(x: 419, y: 244), control: CGPoint(x: 330, y: 218))
                return p
            }(),
            shadow: CGRect(x: 215, y: 426, width: 230, height: 56)))
}
