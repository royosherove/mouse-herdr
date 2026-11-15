import AppKit
import Combine
import Security
import Sparkle

/// Use Sparkle's preferences so its own dialogs and our settings have one source of truth.
struct UpdatePreferences {
    let defaults: UserDefaults

    var automatic: Bool {
        (defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true)
            && (defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true)
    }

    func setAutomatic(_ enabled: Bool) {
        defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        defaults.set(enabled, forKey: "SUAutomaticallyUpdate")
    }
}

struct ReleaseHistory {
    let defaults: UserDefaults

    /// A fresh install gets onboarding; an upgrade gets What's New once, including an
    /// upgrade from a version that predates the updater. Downgrades don't erase history.
    func recordLaunch(build: String?, previouslyUsedApp: Bool) -> Bool {
        guard let build, let current = UInt64(build), current > 0 else { return false }
        let previous = defaults.string(forKey: "lastLaunchedReleaseBuild").flatMap(UInt64.init)
        if current > (previous ?? 0) {
            defaults.set(build, forKey: "lastLaunchedReleaseBuild")
        }
        return previous.map { current > $0 } ?? previouslyUsedApp
    }
}

/// How this copy was made, which decides how it may be updated.
enum BuildKind: Equatable {
    /// A published release. It checks daily and updates itself.
    case release
    /// Built from a checkout. It never checks by itself, but its owner can have it replaced
    /// by the latest release.
    case source
    /// No app bundle with an update feed, as with a binary run straight from `swift build`.
    case unbundled

    init(_ bundle: Bundle) {
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") is String,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { self = .unbundled; return }
        self = bundle.object(forInfoDictionaryKey: "MouseHerdrReleaseBuild") as? Bool == true
            && BuildKind.hasReleaseIdentity(bundle) ? .release : .source
    }

    /// Only a release looks for updates by itself. Anything else checks when its owner asks.
    func allows(_ check: SPUUpdateCheck) -> Bool { self == .release || check == .updates }

    /// The identifier and kind of signature a release has. macOS ties Accessibility and
    /// Input Monitoring to both, so a copy that has them keeps its permissions as a release.
    static func hasReleaseIdentity(_ bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier == releaseIdentifier else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static let releaseIdentifier = "dev.mouseherdr.app"
}

/// What changes for its owner when a source build is replaced by the release, said before
/// they choose to. Settings shows these under the button.
enum ReleaseSwitch {
    static func notes(for bundle: Bundle = .main) -> [String] {
        notes(keepsPermissions: BuildKind.hasReleaseIdentity(bundle),
              keepsPreferences: bundle.bundleIdentifier == BuildKind.releaseIdentifier,
              path: bundle.bundlePath)
    }

    static func notes(keepsPermissions: Bool, keepsPreferences: Bool, path: String) -> [String] {
        var notes = ["Your button assignments stay saved."]
        if !keepsPermissions {
            notes.append("You’ll need to grant Accessibility and Input Monitoring again, because macOS treats the release as a different app from one signed on this Mac.")
        }
        if !keepsPreferences {
            notes.append("Other preferences, such as haptics, go back to their defaults, because this build has an identifier of its own.")
        }
        // The release takes this copy's place, which matters for one run from a checkout.
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.hasSuffix("/Applications") {
            notes.append("The release replaces this copy where it is, in \((folder as NSString).abbreviatingWithTildeInPath).")
        }
        return notes
    }
}

enum UpdatePhase: Equatable {
    case idle, checking, available(String), downloading(String), preparing(String)
    case ready(String), restarting(String), upToDate, failed(String)

    var message: String {
        switch self {
        case .idle: return "Updates are checked automatically once a day."
        case .checking: return "Checking for updates…"
        case .available(let version): return "MouseHerdr \(version) is available."
        case .downloading(let version): return "Downloading MouseHerdr \(version) in the background…"
        case .preparing(let version): return "Preparing MouseHerdr \(version)…"
        case .ready(let version): return "MouseHerdr \(version) is ready to install."
        case .restarting: return "Restarting to install the update…"
        case .upToDate: return "You’re up to date."
        case .failed(let reason): return reason
        }
    }

    var ready: Bool { if case .ready = self { return true }; return false }
    func menuTitle(for kind: BuildKind) -> String {
        if ready { return "Restart to Update…" }
        if busy { return message }
        if case .available = self { return "Update Available…" }
        return kind == .source ? UpdateManager.installReleaseTitle : "Check for Updates…"
    }
    var busy: Bool {
        switch self {
        case .checking, .downloading, .preparing, .restarting: return true
        default: return false
        }
    }
}

/// Sparkle owns scheduling, validation, staging and installation. Its installer waits
/// for this process to quit, so HID controls are released by the normal shutdown path.
///
/// A release starts Sparkle with the app. A source build leaves it alone until its owner
/// asks for the latest release, and even then lets it check only when asked: a copy
/// somebody built is never replaced behind their back.
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var automaticUpdates: Bool {
        didSet {
            guard automaticUpdates != oldValue else { return }
            if let updater = controller?.updater {
                updater.automaticallyChecksForUpdates = automaticUpdates
                updater.automaticallyDownloadsUpdates = automaticUpdates
            } else {
                preferences.setAutomatic(automaticUpdates)
            }
        }
    }
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?

    static let installReleaseTitle = "Install Latest Release…"

    /// How this copy may be updated. Both are worked out when first asked for: telling how
    /// a copy is signed means reading all of it, which the developer tools have no need of.
    private(set) lazy var kind = givenKind ?? BuildKind(.main)
    private(set) lazy var switchNotes = ReleaseSwitch.notes()
    private let givenKind: BuildKind?
    var showWhatsNew: (() -> Void)?
    private let preferences: UpdatePreferences
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var installReadyUpdate: (() -> Void)?

    init(defaults: UserDefaults = .standard, kind: BuildKind? = nil) {
        preferences = UpdatePreferences(defaults: defaults)
        automaticUpdates = preferences.automatic
        givenKind = kind
        super.init()
    }

    /// What Settings says when nothing is going on, and what is going on when something is.
    var status: String {
        guard phase == .idle else { return phase.message }
        switch kind {
        case .release:
            return automaticUpdates ? phase.message : "Automatic updates are off. You can still check manually."
        case .source: return "This is a source build, so it doesn’t update itself."
        case .unbundled: return "This is a source build. Automatic updates are available in releases downloaded from GitHub."
        }
    }

    /// Only normal app startup calls this. Developer tools, snapshots and tests never
    /// start an updater or register its installer.
    func start() {
        guard controller == nil else { return }
        switch kind {
        case .release: startUpdater()
        case .source: canCheck = true
        case .unbundled: break
        }
    }

    @discardableResult
    private func startUpdater() -> Bool {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Coalesce notifications: changing our checkbox writes two Sparkle properties.
        func changed() {
            DispatchQueue.main.async { [weak self, weak updater] in
                guard let self, let updater else { return }
                self.canCheck = updater.canCheckForUpdates
                self.lastChecked = updater.lastUpdateCheckDate
                self.automaticUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
            }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { _, _ in changed() },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { _, _ in changed() }
        ]
        do {
            try updater.start()
            return true
        } catch {
            phase = .failed("Updates couldn’t start. \(error.localizedDescription)")
            Log.write("updater: failed to start: \(error.localizedDescription)")
            return false
        }
    }

    /// Looks for a newer release and offers it. In a source build this is the one way to an
    /// update: the latest release, downloaded, verified and put in this copy's place.
    func checkForUpdates() {
        guard canCheck else { return }
        if controller == nil {
            guard kind == .source, startUpdater() else { return }
            Log.write("updater: started in a source build, to install the latest release")
        }
        guard let updater = controller?.updater else { return }
        if !updater.sessionInProgress { phase = .checking }
        updater.checkForUpdates()
    }

    func restartToUpdate() {
        guard case .ready(let version) = phase, let installReadyUpdate else { return }
        phase = .restarting(version)
        installReadyUpdate()
    }

    /// Sparkle asks before every check. Its schedule runs once a source build has started
    /// it, so this is what keeps such a build from fetching a release nobody asked for.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try permit(updateCheck)
    }

    func permit(_ check: SPUUpdateCheck) throws {
        guard kind.allows(check) else {
            throw NSError(domain: "MouseHerdr.Updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "A source build installs a release only when asked to."])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        phase = .available(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        phase = .downloading(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        phase = .preparing(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // Keep the app running. Return true to own the restart button and keep Sparkle
        // from presenting repeated dialogs while this already verified update waits.
        readyToInstall(version: item.displayVersionString, install: immediateInstallationBlock)
        return true
    }

    func readyToInstall(version: String, install: @escaping () -> Void) {
        installReadyUpdate = install
        phase = .ready(version)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finished(updateCheck, error: error)
    }

    func finished(_ check: SPUUpdateCheck, error: Error?) {
        // A check that was refused never began, so it has nothing to report.
        guard kind.allows(check) else { return }
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                phase = .upToDate
            } else if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
                phase = .idle
            } else {
                phase = .failed("Update couldn’t finish. \(error.localizedDescription)")
                Log.write("updater: \(error.localizedDescription)")
            }
            installReadyUpdate = nil
        } else if !phase.ready {
            phase = .idle
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        // If an update needs interaction (e.g. an informational release), expose it in
        // settings and the menu. Manual checks still use Sparkle's standard dialogs.
        if !handleShowingUpdate { phase = .available(update.displayVersionString) }
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        showWhatsNew?()
    }

    /// Deterministic screenshots without network traffic or a running update service.
    func poseReadyUpdate() { phase = .ready("1.1.0") }
}

enum ReleaseNotes {
    static func bundled(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "md"),
              let notes = try? String(contentsOf: url, encoding: .utf8), !notes.isEmpty else {
            return "See the release history on GitHub for the changes in this version."
        }
        return notes
    }
}
