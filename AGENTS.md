# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## claude-many notes

- Mechanism: Claude Desktop never calls `requestSingleInstanceLock` and honors
  `CLAUDE_USER_DATA_DIR` (relocates userData + Logs). claude-many spawns
  `/Applications/Claude.app/Contents/MacOS/Claude` with that env var set per
  profile. Evidence + design in README.md ("How it works").
- Layout: profile list in `~/Library/Application Support/Claude-Many/profiles.json`,
  per-profile data dirs under `.../Profiles/<slug>/`. Never touch the shared
  `~/Library/Application Support/Claude` folder.
- Build/test (see README):
  `xcodebuild -project claude-many.xcodeproj -scheme claude-many -destination 'platform=macOS' test`
- Tests: core logic is unit-tested with an injected fake launcher; the live
  smoke test (SmokeTests.swift) is gated behind `touch /tmp/claude-many-smoke-run`.
- Code signing is ad-hoc only (`CODE_SIGN_IDENTITY = "-"`); no dev account needed.
