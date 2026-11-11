import SwiftUI

enum Palette {
    static let accent = Color(red: 1.0, green: 0.47, blue: 0.33)
    static let accentSoft = Color(red: 1.0, green: 0.47, blue: 0.33).opacity(0.16)
}

/// The picture of the connected mouse, drawn from its profile, with a label for each control.
struct MouseView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // soft floor shadow
            Ellipse()
                .fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.16))
                .frame(width: art.shadow.width, height: art.shadow.height)
                .blur(radius: 22)
                .position(x: art.shadow.midX, y: art.shadow.midY)

            if let wing = art.wing {
                wing.fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                wing.stroke(Color.white.opacity(0.07), lineWidth: 1)
            }

            art.body
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
            art.body
                .fill(RadialGradient(colors: [Color.white.opacity(0.13), .clear], center: UnitPoint(x: 0.42, y: 0.2), startRadius: 4, endRadius: 190))
            art.body.stroke(Color.white.opacity(0.10), lineWidth: 1)
            art.seams.stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            ForEach(state.profile.controls) { control in leader(control) }
            ForEach(state.profile.controls) { control in part(control) }
            ForEach(state.profile.controls) { control in chip(control) }
        }
        .frame(width: art.size.width, height: art.size.height)
    }

    private var art: MouseArt { state.profile.art }

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
    private func part(_ control: MouseControl) -> some View {
        let slot = control.slot
        let r = control.rect
        let on = isSelected(slot)
        Group {
            switch control.shape {
            case .wheel:
                ridged(r, fill: on ? Palette.accent : Color(white: 0.56))
            case .pad(let tilt):
                let fill = on ? Palette.accent : Color(white: 0.30)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(on ? 0.5 : 0.14), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .rotationEffect(.degrees(tilt))
                    .position(x: r.midX, y: r.midY)
            case .button:
                Capsule().fill(on ? Palette.accent : Color(white: 0.56))
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

    private func leader(_ control: MouseControl) -> some View {
        let r = control.rect
        let left = control.chipOnLeft
        let from = CGPoint(x: control.chip.x + (left ? 1 : -1) * MouseArt.chipSize.width / 2, y: control.chip.y)
        let to = CGPoint(x: left ? r.minX - 3 : r.maxX + 3, y: r.midY)
        let on = isSelected(control.slot)
        var p = Path()
        p.move(to: from)
        let elbow = CGPoint(x: from.x + (left ? 18 : -18), y: from.y)
        p.addLine(to: elbow)
        p.addLine(to: to)
        return ZStack {
            p.stroke(on ? Palette.accent : Color.primary.opacity(0.22),
                     style: StrokeStyle(lineWidth: on ? 1.6 : 1, lineCap: .round, lineJoin: .round))
            Circle().fill(on ? Palette.accent : Color.primary.opacity(0.35))
                .frame(width: 5, height: 5).position(to)
        }
    }

    private func chip(_ control: MouseControl) -> some View {
        let slot = control.slot
        let on = isSelected(slot)
        let action = state.action(slot)
        return Button { state.selected = slot } label: {
            HStack(spacing: 9) {
                Image(systemName: Catalog.symbol(action, slot: slot))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(on ? Palette.accent : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(control.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Catalog.title(action, slot: slot))
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
        .position(control.chip)
        .animation(.easeOut(duration: 0.18), value: on)
    }
}
