# Release signing

The public repository contains the build and release code. Signing credentials belong
in GitHub Actions environment secrets, never in Git or release assets. The public
certificate and publisher identity are included in the signed app; the private key is not.

## GitHub configuration

Create an environment named `release-signing`. Set its deployment branch policy to
**Selected branches and tags**, allowing only the **main branch**, with no tag rules.
Add these environment secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded PKCS#12 export of the Developer ID Application certificate and its matching private key |
| `MACOS_CERTIFICATE_PASSWORD` | Strong password protecting that PKCS#12 export |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_TEAM_ID` | Developer Program team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | Dedicated app-specific password for notarization, generated in Apple Account settings |
| `SPARKLE_PRIVATE_KEY` | Base64 Ed25519 private key for Sparkle; its public half must match `Resources/SparklePublicKey.txt` |

Enter values through GitHub's secret settings or `gh secret set --env release-signing`
using standard input. Do not place secret values in command arguments, tracked files,
logs, issue comments, or pull requests. Export only the intended signing identity from
Keychain Access, not every key in the login keychain.

Only trusted changes should reach `main`, especially workflow and signing-script changes:
code running in a release job can use that job's secrets. Public pull requests run the
CI workflow without signing credentials. The release workflow accepts successful CI
runs for pushes to this repository's `main`, or a manual run on `main`; its planner also
checks the exact commit and current CI result before publishing.

## What a release does

1. Builds a universal app with ad-hoc signing.
2. Imports the Developer ID identity into a temporary keychain on a GitHub-hosted runner.
3. Signs Sparkle's nested helpers and framework from the inside out, preserving their
   entitlements, then signs the app with the hardened runtime and Apple's secure timestamp.
4. Submits the app to Apple's notary service and requires an `Accepted` result.
5. Staples and validates the notarization ticket, and checks Gatekeeper acceptance.
6. Deletes the temporary keychain and private-key export before packaging and publishing.
7. Verifies the signature, ticket, Gatekeeper result, versions, and architectures in the
   extracted release ZIP.
8. Signs the ZIP and `appcast.xml` with the Sparkle key, verifies the archive against the
   app's embedded public key, and publishes all three assets together. The feed points
   at the immutable version-tagged ZIP, never the moving Latest ZIP.

The workflow generates release notes once, before building. Those notes are embedded
in the signed app for offline What's New, included in the signed feed, and appended
to the GitHub release description.

Missing credentials, rejected or timed-out notarization, and failed verification stop
the release. There is no fallback that publishes an unsigned app. A notary timeout can
leave a submission processing at Apple; retry the release after checking its status.

`scripts/sign_release.py` is a build input, so changing the signing behavior can produce
a release. Documentation and test changes alone do not. Local `./build.sh` behavior is
unchanged; use `SIGNING=adhoc ./build.sh` for disposable test builds.

## Credential maintenance

Keep the original private key in a secure local keychain and maintain an encrypted
backup. Renew the signing certificate before it expires and replace the two PKCS#12
secrets together. Rotate the dedicated app-specific password by replacing its GitHub
secret. Existing published assets are never overwritten.

## Sparkle update signing

Sparkle 2.10.1 is pinned by version and SwiftPM checksum. After `swift package resolve`,
its signing tools are in `.build/artifacts/sparkle/Sparkle/bin`.
Generate a dedicated key with `generate_keys --account mouseherdr`. Keep the private key
in Keychain and an encrypted backup. Only the public key (`generate_keys --account
mouseherdr -p`) belongs in `Resources/SparklePublicKey.txt`.

Export the private key using the tool's `-x` option to a temporary file with mode 0600.
Pass its contents through stdin to `gh secret set SPARKLE_PRIVATE_KEY --env release-signing`,
then delete the export. Do not print it or put it in command arguments. CI passes this
secret only to `sign_update` through stdin; it does not import it into a keychain.
The pipeline rejects a secret that does not match the app's public key.

Both the feed and archive signatures are required before extraction. Developer ID code
signing and notarization still apply. Keep the public app's bundle identifier and Apple
team stable across releases to preserve macOS permissions. The release workflow sets
`RELEASE_BUILD=1`; source builds leave it off, even when signed with Developer ID or
ad-hoc, and never check or download by themselves. Such a build starts the updater only
when its owner chooses **Install Latest Release…**, and refuses every check Sparkle then
schedules. Sparkle lets the release take the place of a build with another signing
identity because the build carries the same public update key, and it still requires the
signed feed and archive. Do not casually replace the Sparkle key: deployed apps trust the
old key, so key rotation requires a planned migration following Sparkle's documentation.

Run `python3 scripts/test_update_feed.py` after resolving packages. This uses temporary
test keys to verify real signatures and reject tampering without touching Keychain.
For a full installer test, use a disposable Mac/VM and two Developer ID signed,
notarized builds with the same identifier, team and Sparkle key. Check background
download, restart, normal quit installation, offline What's New, and retained
Accessibility/Input Monitoring. Do not run an update test against a working mouse setup.

To check that a source build can still be replaced by the published release without
running it, build one with a throwaway `BUNDLE_ID` and `SIGNING=adhoc`, copy
`dist/MouseHerdr.app` to an empty temporary folder, and point Sparkle's command-line
updater (`sparkle-cli` in Sparkle's source, compiled against the resolved framework) at
the copy with `--check-immediately`. It downloads, verifies and installs the release over
the copy and starts nothing. Afterwards the copy should pass `codesign --verify --deep
--strict`, `xcrun stapler validate` and `spctl --assess --type execute`.
