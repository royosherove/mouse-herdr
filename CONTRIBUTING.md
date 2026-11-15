# Contributing to MouseHerdr

Bug reports, setup improvements and tested mouse profiles are welcome. Use
[GitHub issues](https://github.com/royosherove/mouse-herdr/issues) for bugs and suggestions,
and pull requests for changes. For a vulnerability, follow [SECURITY.md](SECURITY.md).

## Build and test

Use macOS and Swift 5.9 or newer. From the repository:

```bash
swift test
python3 scripts/test_release.py
python3 scripts/test_sign_release.py
python3 scripts/test_update_feed.py
SIGNING=adhoc ./build.sh
MOUSEHERDR_TEST_BINARY=dist/MouseHerdr.app/Contents/MacOS/MouseHerdr python3 scripts/test_setup.py
```

The setup tests use Python 3's standard library. They exercise failed builds with an old
binary present, Herdr being missing, failing, empty or unresponsive, and how the packaged
app recognises mice of several makers from the ids and names they report. They use
temporary mock commands, do not connect to your real Herdr sessions, and do not start mouse
remapping or request privacy permissions. Swift tests cover agent data parsing, mouse
profiles and their drawings, which connected mouse is followed and what is said about it,
answering an agent from the wheel, and saved settings; they write only to temporary
folders. Use `shellcheck build.sh` if ShellCheck is installed.

One Swift test, in `WheelAnswerTests`, checks answering against herdr-core itself: that an
answer is held back while the pointer moves over the agent's pane, goes in once it rests,
and is called sent only then. It runs when `hc` is installed, takes a few seconds, and is
skipped otherwise. It starts a herdr-core of its own under `/tmp`, with its own session
name and a stand-in agent, and stops it afterwards; it does not connect to your real Herdr
sessions.

GitHub Actions runs the tests and packages an ad-hoc signed app on Intel and Apple silicon
macOS runners. These checks do not validate Bluetooth hardware, privacy permission prompts
or behavior on every macOS release. For normal use, run `./build.sh install` with local
signing as described in the [README](README.md).

## Releases

After CI passes for a push to `main`, the Release workflow compares the app with the last
published release. Changes under `Sources/` or `Resources/`, or to `Package.swift`,
`Package.resolved`, `build.sh`, or `VERSION`, qualify. Markdown and other documentation
edits, tests, and CI-only changes do not publish. The comparison covers all unreleased
commits, so a documentation commit after a code change does not hide that change.

The workflow builds one universal app, verifies both architectures and the extracted
ZIP's signature, runs the setup checks against the extracted app, then publishes
`MouseHerdr.zip`, its SHA-256 checksum, and the signed Sparkle `appcast.xml`. The asset filename stays constant so the
README's latest-download link keeps working.

The version is the contents of `VERSION` followed by the total commit count on `main`
(for example `1.0.42`). Keep `VERSION` in `major.minor` form; raise it for a new major or
minor version, or to release a packaging workflow change that otherwise has no app changes.
Manual runs from the Actions tab use the same change filter and require passing CI for
the current `main` commit. Stale runs and already published versions are skipped. An
interrupted draft upload can be retried for the same commit.

To reproduce a release build locally:

```bash
UNIVERSAL=1 SIGNING=adhoc VERSION=1.0.0 BUILD_NUMBER=1 ./build.sh
```

That local test build is ad-hoc signed and, like every source build, never updates by
itself: it only offers **Install Latest Release…** in Settings. Published
releases are Developer ID signed and notarized; see [release signing](docs/release-signing.md)
for the credentials, nested Sparkle signing, and update feed. Keep the public bundle
identifier, Apple team and Sparkle key stable. PR tests require no release credentials.

Update tests cover persistent opt-out, explicit restart, once-per-upgrade notes, a source
build that checks only when asked, nested signing order, and archive/feed signature
rejection using temporary test keys. Packaged
tests also check the embedded framework and offline notes. To inspect the new screens
without starting mouse capture or the updater, use `--snapshot` with `--tab settings
--update-ready`, or with `--whats-new`, and a temporary `CFFIXED_USER_HOME`.

## Verify changes with a mouse

For changes to remapping, HID++, installation or permissions, include the Mac, macOS
version, mouse model and connection type you tested. Check the relevant behaviors:

- First install: grant Accessibility and Input Monitoring and relaunch.
- Remapping: click, hold/release, gestures, thumb wheel, and ordinary left/right clicks.
- Window dragging: move, drop, snap and cancel without leaving a window attached.
- Reconnection: mouse off/on, Bluetooth disconnect/reconnect, and Mac sleep/wake.
- Other mice: run `--detect-mice --watch 60` and plug a second mouse in and out; it should
  be listed within a second and dropped when it leaves. In the app, check that the mouse is
  named and drawn on the Buttons page, that the notice appears once, that its wheel click
  opens the agent wheel, that **Change…** can follow another connected mouse and pick a
  model by hand, and that an MX Master 4's buttons work again when it is followed again.
- Quit: ordinary mouse behavior returns; reopen and check saved assignments.
- Agent features: missing/stopped Herdr, no agents, viewing a question, sending an answer
  and focusing a terminal. Use a disposable agent session when sending test answers.
- Update: reinstall with the same signing identity and check that permissions persist.

Do not describe untested mice or macOS versions as supported. The project tells two kinds
of mouse apart, and so should a pull request:

- A **tested** mouse has a profile of its own, `tested: true`, and evidence from the actual
  device: the output of `--detect-mice`, the log's `control cid=…` lines if it speaks
  HID++, and the checks above.
- A **recognised** mouse is a line in `Profiles/Catalog.swift`, built from published device
  ids or the name the mouse reports. It may claim only what macOS reports for any mouse
  (the wheel click, back and forward), or controls a Logitech mouse lists itself over
  HID++. Say where each id comes from. The README calls these recognised, never supported
  or tested.

See [Adding a mouse](README.md#adding-a-mouse).

## Screenshots

Use the built-in sample data to avoid exposing live sessions:

```bash
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-window.png
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-buttons.png --tab buttons
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-feel.png --tab feel
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-generic.png --profile generic
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-other-mouse.png --profile msBasicOptical --notice
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot /tmp/mouseherdr-picker.png --picker
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot-mice /tmp/mouseherdr-mice.png
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot-ring /tmp/mouseherdr-agents.png
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot-ring /tmp/mouseherdr-wheel-opening.png --hub
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot-ring /tmp/mouseherdr-no-herdr.png --state not-installed --no-app
dist/MouseHerdr.app/Contents/MacOS/MouseHerdr --snapshot-ring /tmp/mouseherdr-by-space.png --order space
```

Avoid `--live` for public screenshots unless you have reviewed all visible session data.
Review window snapshots too: they can use your saved button assignments and app paths. To
draw them with the defaults instead, and leave your own settings and log alone, give the
command an empty home folder: `CFFIXED_USER_HOME=/tmp/empty-home dist/…/MouseHerdr --snapshot …`.

## App icon

Builds use the tracked `Resources/AppIcon.png`, so packaging works on machines without a
Metal-capable graphics device. After editing `IconView` in `ContentView.swift`, regenerate
the artwork on a desktop Mac:

```bash
swift build -c release
"$(swift build -c release --show-bin-path)/MouseHerdr" --icon Resources/AppIcon.png
./build.sh
```

Commit the updated PNG with the drawing changes. The `--icon` and snapshot developer
commands use SwiftUI rendering and need a working graphics session.

## Keep contributions portable

Keep changes focused and describe the user-visible behavior and validation in the pull
request. Do not commit `local.env`, `signing/`, build outputs, personal logs, credentials
or private agent transcripts. The project is licensed under [MIT](LICENSE); submit code
and assets you have permission to contribute under that license.
