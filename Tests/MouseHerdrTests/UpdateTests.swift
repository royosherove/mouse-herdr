import Sparkle
import XCTest
@testable import MouseHerdr

final class UpdateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "MouseHerdr.UpdateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testAutomaticUpdatesDefaultOnAndOptOutPersistsAcrossLaunches() {
        let first = UpdateManager(defaults: defaults)
        XCTAssertTrue(first.automaticUpdates)
        first.automaticUpdates = false
        let second = UpdateManager(defaults: defaults)
        XCTAssertFalse(second.automaticUpdates)
        XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
        XCTAssertFalse(defaults.bool(forKey: "SUAutomaticallyUpdate"))
        second.automaticUpdates = true
        XCTAssertTrue(UpdateManager(defaults: defaults).automaticUpdates)
        XCTAssertTrue(defaults.bool(forKey: "SUAutomaticallyUpdate"))
    }

    func testDisablingDownloadsInSparkleIsRespected() {
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        XCTAssertFalse(UpdatePreferences(defaults: defaults).automatic)
    }

    func testDownloadedUpdateDoesNotRestartUntilAskedAndCannotRestartTwice() {
        let manager = UpdateManager(defaults: defaults)
        var installs = 0
        manager.restartToUpdate()
        XCTAssertEqual(installs, 0)
        manager.readyToInstall(version: "1.0.50") { installs += 1 }
        XCTAssertEqual(manager.phase, .ready("1.0.50"))
        XCTAssertEqual(installs, 0)
        // Opting out affects future background checks, not an already staged update.
        manager.automaticUpdates = false
        XCTAssertTrue(manager.phase.ready)
        manager.restartToUpdate()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(manager.phase, .restarting("1.0.50"))
        manager.restartToUpdate()
        XCTAssertEqual(installs, 1)
    }

    func testFreshInstallDoesNotShowWhatsNewThenUpgradeShowsExactlyOnce() {
        let history = ReleaseHistory(defaults: defaults)
        XCTAssertFalse(history.recordLaunch(build: "48", previouslyUsedApp: false))
        XCTAssertFalse(history.recordLaunch(build: "48", previouslyUsedApp: true))
        XCTAssertTrue(history.recordLaunch(build: "49", previouslyUsedApp: true))
        XCTAssertFalse(history.recordLaunch(build: "49", previouslyUsedApp: true))
    }

    func testUpgradeFromBeforeUpdaterShowsWhatsNewWithoutOldVersionKey() {
        let history = ReleaseHistory(defaults: defaults)
        XCTAssertTrue(history.recordLaunch(build: "48", previouslyUsedApp: true))
        XCTAssertFalse(history.recordLaunch(build: "48", previouslyUsedApp: true))
    }

    func testDowngradesAndInvalidBuildsDoNotEraseWhatsNewHistory() {
        let history = ReleaseHistory(defaults: defaults)
        XCTAssertFalse(history.recordLaunch(build: "50", previouslyUsedApp: false))
        for build in ["1", "49", "50", "invalid", "0", ""] {
            XCTAssertFalse(history.recordLaunch(build: build, previouslyUsedApp: true))
        }
        XCTAssertFalse(history.recordLaunch(build: nil, previouslyUsedApp: true))
        XCTAssertEqual(defaults.string(forKey: "lastLaunchedReleaseBuild"), "50")
        XCTAssertTrue(history.recordLaunch(build: "51", previouslyUsedApp: true))
    }

    func testCreatingManagerDoesNotStartNetworkOrUpdateService() {
        let manager = UpdateManager(defaults: defaults)
        XCTAssertFalse(manager.canCheck)
        XCTAssertNil(manager.lastChecked)
        XCTAssertEqual(manager.phase, .idle)
        manager.checkForUpdates()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(manager.kind, .unbundled)
        XCTAssertEqual(BuildKind(Bundle(for: Self.self)), .unbundled)
        manager.start()
        XCTAssertFalse(manager.canCheck, "a copy with no feed has nothing to check")
    }

    func testKindComesFromTheBundleAndClaimingToBeAReleaseIsNotEnough() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MouseHerdr.UpdateTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func kind(_ name: String, _ info: [String: Any]) throws -> BuildKind {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return BuildKind(try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent())))
        }
        let built: [String: Any] = ["CFBundleIdentifier": BuildKind.releaseIdentifier, "SUPublicEDKey": "key",
                                    "SUFeedURL": "https://example.com/appcast.xml", "MouseHerdrReleaseBuild": false]
        XCTAssertEqual(try kind("source", built), .source)
        // Not signed with a Developer ID, so it must not update itself whatever it says.
        XCTAssertEqual(try kind("claimed", built.merging(["MouseHerdrReleaseBuild": true]) { $1 }), .source)
        XCTAssertEqual(try kind("no-feed", ["CFBundleIdentifier": BuildKind.releaseIdentifier]), .unbundled)
    }

    func testSourceBuildOffersTheLatestReleaseOnceTheAppHasStarted() {
        let manager = UpdateManager(defaults: defaults, kind: .source)
        XCTAssertFalse(manager.canCheck, "snapshots and developer tools never start it")
        XCTAssertEqual(manager.status, "This is a source build, so it doesn’t update itself.")
        XCTAssertEqual(manager.phase.menuTitle(for: manager.kind), "Install Latest Release…")
        XCTAssertEqual(manager.phase.menuTitle(for: .release), "Check for Updates…")
        manager.start()
        XCTAssertTrue(manager.canCheck)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.lastChecked, "offering the release does not start the updater")
    }

    func testSourceBuildChecksOnlyWhenItsOwnerAsks() {
        let checks: [SPUUpdateCheck] = [.updates, .updatesInBackground, .updateInformation]
        XCTAssertEqual(checks.map(BuildKind.source.allows), [true, false, false])
        XCTAssertEqual(checks.map(BuildKind.release.allows), [true, true, true])
        let source = UpdateManager(defaults: defaults, kind: .source)
        XCTAssertNoThrow(try source.permit(.updates))
        XCTAssertThrowsError(try source.permit(.updatesInBackground))
        XCTAssertNoThrow(try UpdateManager(defaults: defaults, kind: .release).permit(.updatesInBackground))
        // Sparkle asks only a delegate that answers to this exact name. Without it a source
        // build would follow the daily schedule and replace itself.
        XCTAssertTrue(source.responds(to: #selector(SPUUpdaterDelegate.updater(_:mayPerform:))))
    }

    func testCheckASourceBuildRefusedReportsNothingAndOneItsOwnerAskedForDoes() {
        let manager = UpdateManager(defaults: defaults, kind: .source)
        manager.finished(.updatesInBackground, error: NSError(domain: "MouseHerdr.Updates", code: 1))
        XCTAssertEqual(manager.phase, .idle)
        manager.finished(.updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        XCTAssertEqual(manager.phase, .upToDate)
        manager.finished(.updates, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        guard case .failed = manager.phase else { return XCTFail("a failed download is shown") }
        manager.finished(.updates, error: nil)
        XCTAssertEqual(manager.phase, .idle)
    }

    func testStatusSaysHowThisCopyIsUpdated() {
        let release = UpdateManager(defaults: defaults, kind: .release)
        XCTAssertEqual(release.status, "Updates are checked automatically once a day.")
        release.automaticUpdates = false
        XCTAssertEqual(release.status, "Automatic updates are off. You can still check manually.")
        release.readyToInstall(version: "1.0.50") {}
        XCTAssertEqual(release.status, "MouseHerdr 1.0.50 is ready to install.")
        XCTAssertTrue(UpdateManager(defaults: defaults, kind: .unbundled).status.hasPrefix("This is a source build."))
    }

    func testSwitchingToTheReleaseSaysOnlyWhatChanges() {
        XCTAssertEqual(ReleaseSwitch.notes(keepsPermissions: true, keepsPreferences: true, path: "/Applications/MouseHerdr.app"),
                       ["Your button assignments stay saved."])
        XCTAssertEqual(ReleaseSwitch.notes(keepsPermissions: true, keepsPreferences: true,
                                           path: NSHomeDirectory() + "/Applications/MouseHerdr.app").count, 1)
        let notes = ReleaseSwitch.notes(keepsPermissions: false, keepsPreferences: false,
                                        path: "/Volumes/Work/mouse-herdr/dist/MouseHerdr.app")
        XCTAssertEqual(notes.count, 4)
        XCTAssertTrue(notes[1].contains("Accessibility and Input Monitoring"))
        XCTAssertTrue(notes[2].contains("go back to their defaults"))
        XCTAssertTrue(notes[3].hasSuffix("in /Volumes/Work/mouse-herdr/dist."))
    }
}
