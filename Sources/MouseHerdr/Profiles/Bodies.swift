import SwiftUI

extension Path {
    /// A closed, smooth outline through the given points.
    static func outline(_ points: [CGPoint]) -> Path {
        var p = Path()
        let n = points.count
        guard n > 2 else { return p }
        p.move(to: points[0])
        for i in 0..<n {
            let before = points[(i - 1 + n) % n], from = points[i], to = points[(i + 1) % n], after = points[(i + 2) % n]
            p.addCurve(to: to,
                       control1: CGPoint(x: from.x + (to.x - before.x) / 6, y: from.y + (to.y - before.y) / 6),
                       control2: CGPoint(x: to.x - (after.x - from.x) / 6, y: to.y - (after.y - from.y) / 6))
        }
        p.closeSubpath()
        return p
    }

    /// A rectangle with round corners, as an ordinary outline. `Path(roundedRect:)` would be shorter,
    /// but SwiftUI keeps that as a special shape and draws it at the size of the whole canvas once it
    /// has a shadow, which a mouse body does.
    static func box(_ r: CGRect, radius: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
        p.closeSubpath()
        return p
    }

    /// A smooth outline that is the same on both sides of `centre`. `right` runs down the right-hand
    /// side from the nose to the tail, as (distance from the centre line, y).
    static func symmetric(centre: CGFloat, right: [(CGFloat, CGFloat)]) -> Path {
        let rightSide = right.map { CGPoint(x: centre + $0.0, y: $0.1) }
        let leftSide = right.reversed().filter { $0.0 != 0 }.map { CGPoint(x: centre - $0.0, y: $0.1) }
        return outline(rightSide + leftSide)
    }
}

/// A drawn body that many models share, with the places its controls go. Every body is drawn on
/// the same 660 × 520 canvas as the MX Master 4, nose up, with room for labels on both sides.
struct MouseBody {
    var art: MouseArt
    /// The line the body is centred on. Controls left of it are labelled on the left.
    let centre: CGFloat
    var wheel = CGRect.zero        // the scroll wheel
    var top = CGRect.zero          // a small button behind the wheel
    var forward = CGRect.zero      // the front side button
    var back = CGRect.zero         // the rear side button
    var thumb = CGRect.zero        // a button under the thumb
    var thumbWheel = CGRect.zero   // a sideways wheel
    var padLeft = CGRect.zero      // the upper buttons of a finger trackball
    var padRight = CGRect.zero

    static let canvas = CGSize(width: 660, height: 520)

    /// The same body in another colour.
    func finished(_ finish: Finish, ball: Color? = nil) -> MouseBody {
        var copy = self
        copy.art.finish = finish
        if let ball { copy.art.ballColor = ball }
        return copy
    }

    /// The usual lines: the split between the two main buttons above and below the wheel, and the
    /// curve where the buttons end and the palm begins.
    static func seams(centre: CGFloat, top: CGFloat, wheel: CGRect, splitEnd: CGFloat,
                      palmLeft: CGPoint, palmRight: CGPoint, lift: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: centre, y: top)); p.addLine(to: CGPoint(x: centre, y: wheel.minY - 6))
        p.move(to: CGPoint(x: centre, y: wheel.maxY + 6)); p.addLine(to: CGPoint(x: centre, y: splitEnd))
        p.move(to: palmLeft)
        p.addQuadCurve(to: palmRight, control: CGPoint(x: (palmLeft.x + palmRight.x) / 2, y: min(palmLeft.y, palmRight.y) - lift))
        return p
    }
}

extension MouseBody {
    /// The everyday office mouse: the same on both sides, a little wider at the palm.
    static let plain: MouseBody = {
        let wheel = CGRect(x: 318, y: 118, width: 24, height: 64)
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .symmetric(centre: 330, right: [(0, 60), (42, 64), (74, 92), (86, 150), (88, 230), (90, 310), (86, 372), (68, 424), (38, 454), (0, 462)]),
                seams: seams(centre: 330, top: 62, wheel: wheel, splitEnd: 230,
                             palmLeft: CGPoint(x: 242, y: 246), palmRight: CGPoint(x: 418, y: 246), lift: 26),
                shadow: CGRect(x: 215, y: 426, width: 230, height: 56)),
            centre: 330, wheel: wheel,
            top: CGRect(x: 321, y: 194, width: 18, height: 26),
            forward: CGRect(x: 235, y: 224, width: 14, height: 32),
            back: CGRect(x: 235, y: 262, width: 14, height: 32))
    }()

    /// A small travel mouse.
    static let compact: MouseBody = {
        let wheel = CGRect(x: 319, y: 150, width: 22, height: 56)
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .symmetric(centre: 330, right: [(0, 96), (40, 100), (68, 126), (80, 180), (82, 250), (82, 318), (72, 374), (44, 412), (0, 424)]),
                seams: seams(centre: 330, top: 98, wheel: wheel, splitEnd: 250,
                             palmLeft: CGPoint(x: 248, y: 264), palmRight: CGPoint(x: 412, y: 264), lift: 22),
                shadow: CGRect(x: 228, y: 392, width: 204, height: 50)),
            centre: 330, wheel: wheel,
            top: CGRect(x: 322, y: 216, width: 16, height: 24),
            forward: CGRect(x: 242, y: 238, width: 13, height: 30),
            back: CGRect(x: 242, y: 272, width: 13, height: 30))
    }()

    /// A right-handed mouse with a thumb rest: the MX Master's shape.
    static let sculpted = MouseBody(
        art: MouseProfile.mxMaster4.art,
        centre: 350,
        wheel: CGRect(x: 338, y: 96, width: 24, height: 64),
        top: CGRect(x: 341, y: 172, width: 18, height: 28),
        forward: CGRect(x: 248, y: 188, width: 15, height: 30),
        back: CGRect(x: 248, y: 224, width: 15, height: 30),
        thumb: CGRect(x: 205, y: 368, width: 46, height: 56),
        thumbWheel: CGRect(x: 250, y: 118, width: 14, height: 46))

    /// A right-handed gaming mouse: narrow at the nose, flared at the back, with a groove for the thumb.
    static let gaming: MouseBody = {
        let wheel = CGRect(x: 323, y: 110, width: 24, height: 64)
        let outline: [(CGFloat, CGFloat)] = [
            (335, 46), (380, 52), (414, 82), (428, 140), (432, 210), (440, 290), (438, 360), (416, 426), (378, 468),
            (335, 480), (292, 470), (256, 432), (238, 372), (236, 300), (246, 232), (252, 170), (256, 110), (276, 70), (304, 50),
        ]
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .outline(outline.map { CGPoint(x: $0.0, y: $0.1) }),
                seams: seams(centre: 335, top: 48, wheel: wheel, splitEnd: 238,
                             palmLeft: CGPoint(x: 244, y: 252), palmRight: CGPoint(x: 436, y: 252), lift: 24),
                shadow: CGRect(x: 218, y: 442, width: 240, height: 58),
                finish: .black),
            centre: 335, wheel: wheel,
            top: CGRect(x: 326, y: 190, width: 18, height: 24),
            forward: CGRect(x: 241, y: 172, width: 14, height: 34),
            back: CGRect(x: 238, y: 212, width: 14, height: 34))
    }()

    /// A gaming mouse that is the same on both sides, pinched at the waist.
    static let ambi: MouseBody = {
        let wheel = CGRect(x: 318, y: 112, width: 24, height: 62)
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .symmetric(centre: 330, right: [(0, 50), (40, 54), (74, 84), (86, 140), (80, 214), (84, 290), (92, 360), (82, 420), (50, 462), (0, 476)]),
                seams: seams(centre: 330, top: 52, wheel: wheel, splitEnd: 236,
                             palmLeft: CGPoint(x: 248, y: 248), palmRight: CGPoint(x: 412, y: 248), lift: 24),
                shadow: CGRect(x: 216, y: 440, width: 228, height: 56),
                finish: .black),
            centre: 330, wheel: wheel,
            top: CGRect(x: 321, y: 186, width: 18, height: 24),
            forward: CGRect(x: 241, y: 174, width: 13, height: 34),
            back: CGRect(x: 241, y: 214, width: 13, height: 34))
    }()

    /// A vertical mouse seen from above: a ridge along the top, the wheel on the outer slope.
    static let vertical: MouseBody = {
        let wheel = CGRect(x: 372, y: 118, width: 22, height: 58)
        let outline: [(CGFloat, CGFloat)] = [
            (318, 58), (364, 62), (402, 92), (424, 150), (432, 230), (430, 310), (414, 386), (380, 440),
            (334, 462), (288, 452), (254, 410), (238, 340), (236, 260), (244, 180), (262, 110), (288, 72),
        ]
        var seams = Path()
        // The ridge the hand wraps around.
        seams.move(to: CGPoint(x: 300, y: 74))
        seams.addQuadCurve(to: CGPoint(x: 290, y: 448), control: CGPoint(x: 258, y: 252))
        // The split between the two finger buttons, above and below the wheel.
        seams.move(to: CGPoint(x: 382, y: 80)); seams.addLine(to: CGPoint(x: 383, y: wheel.minY - 6))
        seams.move(to: CGPoint(x: 383, y: wheel.maxY + 6))
        seams.addQuadCurve(to: CGPoint(x: 392, y: 268), control: CGPoint(x: 391, y: 226))
        // Where the buttons end.
        seams.move(to: CGPoint(x: 280, y: 292))
        seams.addQuadCurve(to: CGPoint(x: 431, y: 290), control: CGPoint(x: 360, y: 260))
        return MouseBody(
            art: MouseArt(size: canvas, body: .outline(outline.map { CGPoint(x: $0.0, y: $0.1) }), seams: seams,
                          shadow: CGRect(x: 212, y: 424, width: 240, height: 56)),
            centre: 334, wheel: wheel,
            top: CGRect(x: 298, y: 148, width: 18, height: 28),
            forward: CGRect(x: 241, y: 196, width: 14, height: 32),
            back: CGRect(x: 237, y: 234, width: 14, height: 32))
    }()

    /// A trackball worked by the thumb, like the MX Ergo.
    static let thumbBall: MouseBody = {
        let wheel = CGRect(x: 340, y: 100, width: 24, height: 62)
        let outline: [(CGFloat, CGFloat)] = [
            (352, 56), (398, 62), (430, 96), (442, 160), (446, 240), (442, 320), (424, 396), (388, 448), (340, 470),
            (292, 462), (252, 432), (224, 388), (208, 330), (204, 270), (214, 214), (238, 170), (262, 124), (296, 76),
        ]
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .outline(outline.map { CGPoint(x: $0.0, y: $0.1) }),
                seams: seams(centre: 352, top: 58, wheel: wheel, splitEnd: 222,
                             palmLeft: CGPoint(x: 290, y: 232), palmRight: CGPoint(x: 445, y: 238), lift: 26),
                shadow: CGRect(x: 196, y: 432, width: 256, height: 58),
                ball: CGRect(x: 196, y: 238, width: 74, height: 74),
                ballColor: Color(red: 0.42, green: 0.47, blue: 0.56)),
            centre: 340, wheel: wheel,
            top: CGRect(x: 282, y: 190, width: 18, height: 26),
            forward: CGRect(x: 277, y: 100, width: 13, height: 30),
            back: CGRect(x: 262, y: 136, width: 13, height: 30))
    }()

    /// A trackball worked by the fingers: a large ball in the middle with a scroll ring and four buttons around it.
    static let fingerBall: MouseBody = {
        var seams = Path()
        seams.move(to: CGPoint(x: 330, y: 86)); seams.addLine(to: CGPoint(x: 330, y: 184))
        seams.move(to: CGPoint(x: 330, y: 352)); seams.addLine(to: CGPoint(x: 330, y: 450))
        seams.move(to: CGPoint(x: 216, y: 268)); seams.addLine(to: CGPoint(x: 246, y: 268))
        seams.move(to: CGPoint(x: 414, y: 268)); seams.addLine(to: CGPoint(x: 444, y: 268))
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .box(CGRect(x: 214, y: 84, width: 232, height: 368), radius: 60),
                seams: seams,
                shadow: CGRect(x: 204, y: 424, width: 252, height: 58),
                ball: CGRect(x: 270, y: 208, width: 120, height: 120),
                ring: true,
                finish: .black),
            centre: 330,
            padLeft: CGRect(x: 230, y: 100, width: 86, height: 84),
            padRight: CGRect(x: 344, y: 100, width: 86, height: 84))
    }()

    /// Apple's Magic Mouse: one smooth surface with no wheel and no visible buttons.
    static let magic = MouseBody(
        art: MouseArt(
            size: canvas,
            body: .box(CGRect(x: 262, y: 76, width: 136, height: 372), radius: 62),
            seams: Path(),
            shadow: CGRect(x: 238, y: 414, width: 184, height: 48),
            finish: .white),
        centre: 330,
        wheel: CGRect(x: 316, y: 122, width: 28, height: 46))

    /// Microsoft's Arc mice: a slim flat body with a touch strip where a wheel would be.
    static let arc: MouseBody = {
        var seams = Path()
        // The touch strip, and the line the body bends along.
        seams.addPath(.box(CGRect(x: 312, y: 104, width: 36, height: 108), radius: 13))
        seams.move(to: CGPoint(x: 270, y: 256)); seams.addLine(to: CGPoint(x: 390, y: 256))
        return MouseBody(
            art: MouseArt(
                size: canvas,
                body: .box(CGRect(x: 268, y: 62, width: 124, height: 398), radius: 50),
                seams: seams,
                shadow: CGRect(x: 240, y: 426, width: 180, height: 48),
                finish: .black),
            centre: 330,
            wheel: CGRect(x: 318, y: 132, width: 24, height: 52))
    }()
}

// MARK: - Building a profile from a body

extension MouseProfile {
    /// The buttons a mouse has beyond left and right, in the terms MouseHerdr can use.
    enum Buttons {
        /// Nothing macOS hears about: no wheel to press and no spare button.
        case none
        /// A wheel that clicks.
        case wheel
        /// A wheel that clicks, and one side button.
        case wheelAndBack
        /// A wheel that clicks, and back and forward buttons.
        case wheelAndSides
        /// A middle click and side buttons, on a mouse whose middle click is not its wheel.
        case middleAndSides
        /// The MX Master line: wheel click, top button, thumb wheel, gesture button, back and forward.
        case mxMaster
        /// Wheel click, back and forward, and a button behind the wheel that only answers over HID++.
        case sidesAndTop(cid: UInt16, title: String, blurb: String)
        /// Wheel click, back and forward, and a thumb button that only answers over HID++.
        case sidesAndThumb(cid: UInt16)
        /// A finger trackball's two upper buttons.
        case upperPair
    }

    /// One control before it is given a place for its label.
    private struct Part {
        let slot: Slot, title: String, blurb: String
        var source: MouseControl.Source
        let rect: CGRect
        var shape = MouseControl.Shape.button
        var gestures = false
        var virtual = false
    }

    /// Smart Shift, the button behind the wheel on Logitech's MX mice.
    private static let smartShift: UInt16 = 0x00C4
    /// The gesture button under the thumb on the MX Master line.
    private static let gestureButton: UInt16 = 0x00C3

    /// A profile for a mouse that is drawn from a shared body and has only the usual buttons.
    static func make(_ id: String, brand: String, name: String, vendors: Set<Int> = [], ids: Set<Int> = [], names: [String] = [],
                     body: MouseBody, buttons: Buttons, kind: Kind = .mouse, note: String? = nil) -> MouseProfile {
        let wheel = Part(slot: .middle, title: "Wheel click", blurb: "Pressing down on the scroll wheel.",
                         source: .button(2), rect: body.wheel, shape: .wheel)
        var forward = Part(slot: .forward, title: "Forward button", blurb: "The front one of the two side buttons.",
                           source: .button(4), rect: body.forward)
        var back = Part(slot: .back, title: "Back button", blurb: "The rear one of the two side buttons.",
                        source: .button(3), rect: body.back)

        var parts: [Part]
        switch buttons {
        case .none:
            parts = [Part(slot: .middle, title: "Middle click",
                          blurb: "This mouse cannot send a middle click by itself. If a helper app such as BetterTouchTool or MiddleClick turns a gesture into one, give that click an action here.",
                          source: .button(2), rect: body.wheel, virtual: true)]
        case .wheel:
            parts = [wheel]
        case .wheelAndBack:
            parts = [wheel, Part(slot: .back, title: "Side button", blurb: "The button under your thumb. Out of the box it goes back.",
                                 source: .button(3), rect: body.back)]
        case .wheelAndSides:
            parts = [wheel, forward, back]
        case .middleAndSides:
            parts = [Part(slot: .middle, title: "Middle click", blurb: "The middle click, as this mouse sends it to the Mac.",
                          source: .button(2), rect: body.wheel, shape: .wheel), forward, back]
        case .mxMaster:
            // Logi Options+ captures the side buttons over HID++, and then macOS never reports them.
            forward.source = .button(4, cid: 0x0056)
            back.source = .button(3, cid: 0x0053)
            parts = [
                wheel,
                Part(slot: .modeShift, title: "Top button",
                     blurb: "The small button behind the scroll wheel. Out of the box it switches the wheel between ratchet and free-spin.",
                     source: .hidpp(cid: smartShift), rect: body.top),
                Part(slot: .thumbWheel, title: "Thumb wheel", blurb: "The little wheel by your thumb. Out of the box it scrolls sideways.",
                     source: .thumbWheel, rect: body.thumbWheel, shape: .wheel),
                forward, back,
                Part(slot: .gesture, title: "Gesture button",
                     blurb: "The button under your thumb, in the thumb rest. Click it, or hold it and move the mouse for four more actions.",
                     source: .hidpp(cid: gestureButton), rect: body.thumb, shape: .pad(tilt: -7), gestures: true),
            ]
        case .sidesAndTop(let cid, let title, let blurb):
            parts = [wheel, Part(slot: .modeShift, title: title, blurb: blurb, source: .hidpp(cid: cid), rect: body.top), forward, back]
        case .sidesAndThumb(let cid):
            parts = [wheel, forward, back,
                     Part(slot: .gesture, title: "Thumb button",
                          blurb: "The button under your thumb. Click it, or hold it and move the mouse for four more actions.",
                          source: .hidpp(cid: cid), rect: body.thumb, shape: .pad(tilt: -7), gestures: true)]
        case .upperPair:
            parts = [
                Part(slot: .middle, title: "Top left button", blurb: "The upper left of the four buttons. Out of the box it is a middle click.",
                     source: .button(2), rect: body.padLeft, shape: .pad(tilt: 0)),
                Part(slot: .back, title: "Top right button", blurb: "The upper right of the four buttons. Out of the box it goes back.",
                     source: .button(3), rect: body.padRight, shape: .pad(tilt: 0)),
            ]
        }

        // Labels go beside the mouse on the side their control is on, spread so they don't overlap.
        // A wheel in the middle is labelled on the right.
        let onLeft = parts.map { $0.rect.midX < body.centre - ($0.slot == .middle ? 30 : 0) }
        var chipY = [CGFloat](repeating: 0, count: parts.count)
        for side in [true, false] {
            let mine = parts.indices.filter { onLeft[$0] == side }.sorted { parts[$0].rect.midY < parts[$1].rect.midY }
            for (i, y) in zip(mine, spread(mine.map { parts[$0].rect.midY })) { chipY[i] = y }
        }
        let controls = parts.indices.map { i -> MouseControl in
            let p = parts[i]
            return MouseControl(slot: p.slot, title: p.title, blurb: p.blurb, source: p.source, gestures: p.gestures, virtual: p.virtual,
                                rect: p.rect, shape: p.shape, chip: CGPoint(x: onLeft[i] ? 92 : 568, y: chipY[i]), chipOnLeft: onLeft[i])
        }

        var defaults: [Slot: Action] = [:]
        for p in parts {
            switch p.slot {
            case .middle: defaults[.middle] = p.virtual ? .standard : Action(kind: "agentWheel")
            case .forward: defaults[.forward] = Action(kind: "forward")
            case .back: defaults[.back] = Action(kind: "back")
            case .gesture:
                defaults[.gesture] = Action(kind: "missionControl")
                defaults[.gestureUp] = Action(kind: "missionControl")
                defaults[.gestureDown] = Action(kind: "appExpose")
                defaults[.gestureLeft] = Action(kind: "spaceLeft")
                defaults[.gestureRight] = Action(kind: "spaceRight")
            default: defaults[p.slot] = .standard
            }
        }

        let direct = parts.filter { if case .hidpp = $0.source { return true } else { return false } }.map { $0.title.lowercased() }
        let why = direct.isEmpty
            ? "Lets MouseHerdr talk to the mouse directly, to show its battery level."
            : "Lets MouseHerdr talk to the mouse directly, so its \(direct.joined(separator: " and ")) can be given actions."

        return MouseProfile(id: id, name: name, brand: brand, kind: kind, vendorIDs: vendors, productIDs: ids, nameContains: names,
                            controls: controls, firstSelected: .middle, hasHaptics: false, defaults: defaults,
                            directLinkWhy: why, art: body.art, note: note)
    }

    /// Where to put labels whose controls are at these heights (sorted): each as near its control as
    /// it can be while keeping `gap` between neighbours and staying on the canvas.
    static func spread(_ ideal: [CGFloat], gap: CGFloat = 66, range: ClosedRange<CGFloat> = 40...480) -> [CGFloat] {
        // Labels that would overlap are stacked as one group, centred on the middle of where they wanted to be.
        var groups: [(sum: CGFloat, count: Int)] = []
        func top(_ g: (sum: CGFloat, count: Int)) -> CGFloat {
            let span = CGFloat(g.count - 1) * gap
            let centre = min(max(g.sum / CGFloat(g.count), range.lowerBound + span / 2), range.upperBound - span / 2)
            return centre - span / 2
        }
        for y in ideal {
            groups.append((y, 1))
            while groups.count > 1 {
                let below = groups[groups.count - 1], above = groups[groups.count - 2]
                guard top(below) - (top(above) + CGFloat(above.count - 1) * gap) < gap else { break }
                groups.removeLast(2)
                groups.append((above.sum + below.sum, above.count + below.count))
            }
        }
        return groups.flatMap { g in (0..<g.count).map { top(g) + CGFloat($0) * gap } }
    }
}
