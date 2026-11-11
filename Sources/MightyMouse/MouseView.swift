import SwiftUI

enum Palette {
    static let accent = Color(red: 1.0, green: 0.47, blue: 0.33)
    static let accentSoft = Color(red: 1.0, green: 0.47, blue: 0.33).opacity(0.16)
}

/// Geometry of the stylised MX Master 4, in a 660 × 520 canvas (nose pointing up).
enum MouseArt {
    static let size = CGSize(width: 660, height: 520)

    static var body: Path {
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
    }

    static var wing: Path {
        var p = Path()
        p.move(to: CGPoint(x: 264, y: 266))
        p.addCurve(to: CGPoint(x: 188, y: 352), control1: CGPoint(x: 232, y: 270), control2: CGPoint(x: 198, y: 305))
        p.addCurve(to: CGPoint(x: 214, y: 450), control1: CGPoint(x: 180, y: 396), control2: CGPoint(x: 187, y: 436))
        p.addCurve(to: CGPoint(x: 300, y: 476), control1: CGPoint(x: 244, y: 464), control2: CGPoint(x: 275, y: 474))
        p.addLine(to: CGPoint(x: 300, y: 266))
        p.closeSubpath()
        return p
    }

    /// Seams between the two main buttons and the palm.
    static var seams: Path {
        var p = Path()
        p.move(to: CGPoint(x: 350, y: 42)); p.addLine(to: CGPoint(x: 350, y: 92))
        p.move(to: CGPoint(x: 350, y: 206)); p.addLine(to: CGPoint(x: 350, y: 240))
        p.move(to: CGPoint(x: 259, y: 258))
        p.addQuadCurve(to: CGPoint(x: 441, y: 258), control: CGPoint(x: 350, y: 232))
        return p
    }

    static let wheel = CGRect(x: 338, y: 96, width: 24, height: 64)
    static let thumbWheel = CGRect(x: 250, y: 118, width: 14, height: 46)

    static func rect(_ slot: Slot) -> CGRect {
        switch slot {
        case .middle: return wheel
        case .modeShift: return CGRect(x: 341, y: 172, width: 18, height: 28)
        case .gesture: return CGRect(x: 249, y: 174, width: 15, height: 28)
        case .forward: return CGRect(x: 248, y: 206, width: 15, height: 28)
        case .back: return CGRect(x: 248, y: 238, width: 15, height: 28)
        case .thumbPanel: return CGRect(x: 203, y: 312, width: 50, height: 108)
        default: return .zero
        }
    }

    /// Where each button's label sits, and which side of the mouse.
    static func chip(_ slot: Slot) -> (center: CGPoint, left: Bool) {
        switch slot {
        case .gesture: return (CGPoint(x: 92, y: 120), true)
        case .forward: return (CGPoint(x: 92, y: 192), true)
        case .back: return (CGPoint(x: 92, y: 264), true)
        case .thumbPanel: return (CGPoint(x: 92, y: 372), true)
        case .middle: return (CGPoint(x: 568, y: 128), false)
        case .modeShift: return (CGPoint(x: 568, y: 204), false)
        default: return (.zero, true)
        }
    }

    static let chipSize = CGSize(width: 172, height: 52)
}

struct MouseView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // soft floor shadow
            Ellipse()
                .fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.16))
                .frame(width: 250, height: 60)
                .blur(radius: 22)
                .position(x: 335, y: 478)

            MouseArt.wing
                .fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            MouseArt.wing.stroke(Color.white.opacity(0.07), lineWidth: 1)

            MouseArt.body
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
            MouseArt.body
                .fill(RadialGradient(colors: [Color.white.opacity(0.13), .clear], center: UnitPoint(x: 0.42, y: 0.2), startRadius: 4, endRadius: 190))
            MouseArt.body.stroke(Color.white.opacity(0.10), lineWidth: 1)
            MouseArt.seams.stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            // thumb wheel (not assignable, drawn for orientation)
            ridged(MouseArt.thumbWheel, fill: Color(white: 0.5))

            ForEach(Slot.buttons) { slot in leader(slot) }
            ForEach(Slot.buttons) { slot in part(slot) }
            ForEach(Slot.buttons) { slot in chip(slot) }
        }
        .frame(width: MouseArt.size.width, height: MouseArt.size.height)
    }

    // MARK: Pieces

    private func isSelected(_ slot: Slot) -> Bool { state.selected == slot }

    private func ridged(_ r: CGRect, fill: Color) -> some View {
        ZStack {
            Capsule().fill(fill)
            VStack(spacing: 3) {
                ForEach(0..<Int(r.height / 6), id: \.self) { _ in
                    Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1.2)
                }
            }
            .padding(.horizontal, 2)
            .clipShape(Capsule())
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    @ViewBuilder
    private func part(_ slot: Slot) -> some View {
        let r = MouseArt.rect(slot)
        let on = isSelected(slot)
        let fill = on ? Palette.accent : Color(white: slot == .thumbPanel ? 0.30 : 0.56)
        Group {
            if slot == .middle {
                ridged(r, fill: fill)
            } else if slot == .thumbPanel {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(on ? 0.5 : 0.14), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .rotationEffect(.degrees(-7))
                    .position(x: r.midX, y: r.midY)
            } else {
                Capsule().fill(fill)
                    .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 0.8))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .shadow(color: on ? Palette.accent.opacity(0.75) : .clear, radius: 9)
        .contentShape(Rectangle().size(width: 0, height: 0))
        .overlay(
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: r.width + 14, height: r.height + 6)
                .position(x: r.midX, y: r.midY)
                .onTapGesture { state.selected = slot }
        )
        .animation(.easeOut(duration: 0.18), value: on)
    }

    private func leader(_ slot: Slot) -> some View {
        let r = MouseArt.rect(slot)
        let c = MouseArt.chip(slot)
        let from = CGPoint(x: c.center.x + (c.left ? 1 : -1) * MouseArt.chipSize.width / 2, y: c.center.y)
        let to = CGPoint(x: c.left ? r.minX - 3 : r.maxX + 3, y: r.midY)
        let on = isSelected(slot)
        var p = Path()
        p.move(to: from)
        let elbow = CGPoint(x: from.x + (c.left ? 18 : -18), y: from.y)
        p.addLine(to: elbow)
        p.addLine(to: to)
        return ZStack {
            p.stroke(on ? Palette.accent : Color.primary.opacity(0.22),
                     style: StrokeStyle(lineWidth: on ? 1.6 : 1, lineCap: .round, lineJoin: .round))
            Circle().fill(on ? Palette.accent : Color.primary.opacity(0.35))
                .frame(width: 5, height: 5).position(to)
        }
    }

    private func chip(_ slot: Slot) -> some View {
        let c = MouseArt.chip(slot)
        let on = isSelected(slot)
        let action = state.action(slot)
        return Button { state.selected = slot } label: {
            HStack(spacing: 9) {
                Image(systemName: Catalog.symbol(action))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(on ? Palette.accent : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Catalog.title(action))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(width: MouseArt.chipSize.width, height: MouseArt.chipSize.height)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(on ? AnyShapeStyle(Palette.accentSoft) : AnyShapeStyle(.regularMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(on ? Palette.accent : Color.primary.opacity(0.10), lineWidth: on ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .position(c.center)
        .animation(.easeOut(duration: 0.18), value: on)
    }
}
