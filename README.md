# claude-many

Run multiple Claude Desktop instances side by side on one Mac, each logged
into a different account. There is no fixed limit — you add one profile per
Claude login you have.

A tiny native macOS app (Swift/SwiftUI) that manages one private data
directory per profile and launches Claude Desktop pointed at it.

## What it is

- **Profile manager** — add, rename, remove, start, and stop profiles. Each
  profile has a label, a Start/Stop control, and a running indicator.
- **Unlimited profiles** — as many as you have accounts. Profiles and their
  data directories persist across app restarts.
- **Isolated logins** — every profile owns a private data directory under
  `~/Library/Application Support/Claude-Many/Profiles/<slug>/`. That
  directory holds that instance's login tokens, cookies, config, and
  sessions, so each instance logs in and stays logged in independently.
- **Native look** — SwiftUI, macOS 14+, arm64. Ad-hoc signed, no developer
  account required.

## How it works

Claude Desktop (`/Applications/Claude.app`) is an Electron app. Two verified
facts about its bundle make this possible:

1. **It never calls Electron's `requestSingleInstanceLock`**, so multiple
   instances of Claude Desktop can run at the same time. (Confirmed by
   searching the entire `app.asar` payload: zero occurrences.)
2. **It honors the `CLAUDE_USER_DATA_DIR` environment variable**, relocating
   its entire userData directory. The bundle contains
   `if (process.env.CLAUDE_USER_DATA_DIR) { app.setPath('userData', e);
   app.setPath('logs', resolve(e, 'Logs')) }` — the directory that holds
   login tokens, cookies, config, and sessions.

So claude-many spawns the binary directly —
`/Applications/Claude.app/Contents/MacOS/Claude` — with `CLAUDE_USER_DATA_DIR`
set to the profile's directory. The first launch of a fresh profile shows a
login screen inside that instance only. From then on, each profile opens
directly into its own logged-in session, window by window, side by side.

Stopping a profile sends SIGTERM to its process (with a SIGKILL fallback
after 5 seconds), terminating only that instance — other profiles and
any separately launched Claude Desktop instances are unaffected.

## Build

Requires Xcode (developed with Xcode 26.6 / Swift 6.3.3 on macOS 26, arm64;
deployment target is macOS 14+).

```sh
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -configuration Debug -destination 'platform=macOS' build
```

The app is **ad-hoc signed** (no developer account, no notarization):

```sh
codesign --force --deep -s - "path/to/build/Products/Debug/claude-many.app"
```

Run it from Xcode, or `open` the built app.

## Usage

1. Launch claude-many and click **+** to add a profile, e.g. "Work".
2. Click **Start** next to the profile. A Claude Desktop window opens for
   that profile and asks you to log in — sign into that account once.
3. Repeat for each additional account: add a profile, start it, log in.
   Each instance is a separate window, side by side, independently logged in.
4. Click **Stop** on a profile to quit that instance (its login is preserved
   for next time).

Other controls: the **⋯** menu renames or deletes a profile. Deleting only
removes it from the list — the data directory stays on disk so nothing is
lost (remove it manually if you truly want to delete the account data).
Settings (⌘,) lets you change the Claude.app path if it is not installed in
`/Applications`.

## Tests

Unit tests cover the profile store and manager logic (add/remove/rename,
persistence, start/stop state transitions) with an injected fake launcher,
so the core is tested without launching Claude:

```sh
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test
```

A **live smoke test** (in `claude-manyTests/SmokeTests.swift`) launches two
real Claude instances against throwaway scratch directories under `/tmp`,
verifies two processes, two windows, and two independently populated data
directories, then stops both and verifies clean termination (a second variant
verifies leftover-instance reconciliation across an app relaunch). It is
gated so ordinary test runs never spawn real applications — either
`CLAUDE_MANY_SMOKE=1` or the flag file below opts in (xcodebuild does not
reliably pass env vars to hosted test processes, so the flag file is the
dependable route):

```sh
touch /tmp/claude-many-smoke-run   # opt in
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test
```

## Developing

Contributions use a jj-based workflow in isolated jjhouse workspaces (no raw
git writes): see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full
developer guide — prerequisites, the repository model (colocated jj + git,
`base = "main"`), the jj bookmark → push → PR loop, and the build/test
commands above (including the gated live smoke test).

## Behavior notes

- **Auto-updates apply to every profile.** The Claude.app bundle is shared;
  an update replaces the binary all profiles launch. Profile data is
  unaffected (it lives in per-profile directories).
- **All account data lives in per-profile directories** under
  `~/Library/Application Support/Claude-Many/Profiles/<slug>/` and never
  leaves the machine. Nothing is ever written to the shared
  `~/Library/Application Support/Claude` folder.
- **No fixed limit** on the number of profiles beyond disk space and memory.
- **Restarting the app never double-starts a profile.** If claude-many is
  quit while instances are still running, the next launch detects each
  profile's live instance (by its data directory), shows it as running, and
  refuses to start a second one into that data directory until the first has
  actually exited. Starting a profile right after stopping it is likewise
  refused until the previous instance has fully shut down.
- Claude Desktop's own settings (theme, etc.) are per profile too, since
  they are part of the userData directory.

## License

MIT — see [LICENSE](LICENSE).
