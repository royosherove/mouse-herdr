# Security and privacy

Use **Security → Report a vulnerability** on GitHub when that option is available.
Otherwise, open an issue asking for a private reporting channel, without disclosing the
vulnerability. Share the affected commit, macOS version, reproduction steps and likely
impact through that private channel. Do not include private keys, API keys or unrelated
agent transcripts, or post vulnerability details in a public issue.

Security fixes are developed on `main`. There are no separate supported release branches.

## Access and local data

MouseHerdr needs Accessibility to generate shortcuts and inspect or move windows, and
Input Monitoring to communicate with the mouse. Only grant these permissions to a build
you trust. The app does not run a network listener or include telemetry.

Agent integration invokes locally installed `hc` and `herdr-app` commands. Those commands
must be trusted: they can read agent sessions and deliver input to them. Questions and
terminal text are read into memory; typed answers are sent only when you choose to reply.
Logs may contain application and workspace names, local paths and action metadata.

The build creates a self-signed development identity under `signing/`. Its keychain uses a
fixed local-development password; it is not a production certificate store. The directory
is restricted to its owner and excluded from Git. Never put other credentials in this
keychain, share its private key, or distribute it with source archives. Use
`SIGNING=adhoc` for disposable builds that do not need persistent permissions.

## Before making the repository public

Scan the complete Git history as well as the current files for secrets, review screenshots,
and verify a clean source build. The tracked `.gitignore` excludes local signing material,
environment files and build outputs. Keep those files excluded when adding future
packaging or release automation. Published binary releases need a separate distribution
signing and notarization process; the current build script is for local source installs.
Enable GitHub's private vulnerability reporting when the repository becomes public.
