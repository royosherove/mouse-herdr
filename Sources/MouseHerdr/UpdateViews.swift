import SwiftUI

struct SettingsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var updates: UpdateManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("General", systemImage: "slider.horizontal.3").font(.headline)
                    Toggle("Start MouseHerdr when I log in", isOn: Binding(
                        get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 14) {
                    Label("Software updates", systemImage: "arrow.down.circle").font(.headline)
                    if updates.kind == .release {
                        Toggle("Automatically check for and download updates", isOn: $updates.automaticUpdates)
                            .toggleStyle(.checkbox)
                        Text("Checks daily and downloads in the background. Restart when you’re ready, or the update will install when you next quit MouseHerdr.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                    HStack(alignment: .top, spacing: 10) {
                        if updates.phase.busy { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: updates.phase.ready ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(updates.phase.ready ? Color.green : Palette.accent)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(updates.status).font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if let date = updates.lastChecked {
                                Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if updates.phase.ready {
                        Button("Restart to Update", action: updates.restartToUpdate)
                            .buttonStyle(.borderedProminent).tint(Palette.accent)
                        Text(updates.kind == .source ? updates.switchNotes.joined(separator: " ")
                             : "Your mouse assignments and settings stay saved.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if updates.kind == .source {
                        // A build somebody made is replaced only when they say so, knowing what changes.
                        Text("You can replace it with the latest release from GitHub, which then keeps itself up to date. "
                             + updates.switchNotes.joined(separator: " "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(UpdateManager.installReleaseTitle, action: updates.checkForUpdates)
                            .disabled(!updates.canCheck)
                    } else if updates.kind == .release {
                        Button("Check for Updates…", action: updates.checkForUpdates)
                            .disabled(!updates.canCheck)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack {
                    Text(AppVersion.label() ?? "MouseHerdr").font(.system(size: 11))
                        .foregroundStyle(.secondary).help(AppVersion.sentence())
                    Spacer()
                    Button("What’s New…") { updates.showWhatsNew?() }
                }
            }
            .font(.system(size: 13))
            .padding(24)
        }
    }
}

struct UpdateHelpPanel: View {
    var kind = BuildKind.release

    var body: some View {
        let source = kind == .source
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: source ? "hammer" : "shippingbox").font(.system(size: 34)).foregroundStyle(Palette.accent)
            Text(source ? "Yours to update" : "Ready when you are").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(source ? "A build made from source stays as it is until you rebuild it. MouseHerdr never replaces it by itself."
                 : "MouseHerdr keeps working while an update downloads. When it’s ready, you’ll find Restart to Update here and in the menu bar.")
            Text(source ? "Install Latest Release shows the newest release, downloads it when you agree, and restarts MouseHerdr as that release."
                 : "After updating, What’s New shows the changes in your new version. You can open it again from the menu.")
            Divider()
            Text(source ? "The release comes from MouseHerdr’s GitHub releases and is verified before it is installed."
                 : "Updates come from MouseHerdr’s GitHub releases and are verified before installation.")
            Link("Release history on GitHub ↗", destination: URL(string: "https://github.com/royosherove/mouse-herdr/releases")!)
                .foregroundStyle(Palette.accent)
            Spacer()
        }
        .font(.system(size: 13)).foregroundStyle(.secondary)
        .padding(24).padding(.top, 12)
    }
}

struct UpdateFooter: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        if updates.phase.ready {
            Button(action: updates.restartToUpdate) {
                Label("Restart to Update", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
        } else {
            Text(updates.phase.busy ? updates.phase.message : "MouseHerdr runs in your menu bar.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct WhatsNewView: View {
    var notes: String = ReleaseNotes.bundled()
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("What’s New", systemImage: "sparkles")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("MouseHerdr \(AppVersion.number ?? "")").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(notes.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                        if !line.isEmpty { noteLine(line) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Divider()
            HStack {
                Link("Release history ↗", destination: URL(string: "https://github.com/royosherove/mouse-herdr/releases")!)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 560, height: 490)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func noteLine(_ line: String) -> some View {
        let heading = line.hasPrefix("#")
        let text = heading ? line.drop(while: { $0 == "#" || $0 == " " }).description
            : (line.hasPrefix("* ") || line.hasPrefix("- ")) ? "• " + line.dropFirst(2) : line
        return Text(.init(text))
            .font(.system(size: heading ? 15 : 13, weight: heading ? .semibold : .regular))
            .fixedSize(horizontal: false, vertical: true)
    }
}
