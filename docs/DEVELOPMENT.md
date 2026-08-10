# Developing claude-many

Developer guide for contributors. The user-facing [README](../README.md)
covers the app itself (mechanism, build, usage, tests, behavior notes); this
file covers the development environment, the repository model, and the
contribution workflow.

## Prerequisites

Development happens on macOS with a Homebrew/cargo toolchain. Reference
versions on the current development machine:

| Tool        | Version            | Location                                      |
|-------------|--------------------|-----------------------------------------------|
| Xcode       | 26.6 / Swift 6.3.3 | Xcode.app (arm64, macOS 26; deploys to 14+)   |
| jj          | 0.44.0             | `/opt/homebrew/bin/jj` (Homebrew)             |
| jjhouse     | v0.1.0             | `~/.cargo/bin/jjhouse` (cargo)                |
| treehouse   | compat shim        | `~/.local/bin/treehouse`                      |
| no-mistakes | —                  | `~/.local/bin/no-mistakes`                    |

### Install

1. **Xcode** — from the Mac App Store or Apple's developer site. No
   developer account is needed: the app is ad-hoc signed
   (`CODE_SIGN_IDENTITY = "-"`).

2. **jj** — the Jujutsu version control CLI:

   ```sh
   brew install jj
   ```

3. **jjhouse** — the jj workspace pool manager that supplies development
   workspaces (see [The jjhouse dev loop](#the-jjhouse-dev-loop)):

   ```sh
   cargo install jjhouse
   # or, from source:
   cargo install --git https://github.com/swissgrammie/jjhouse.git
   ```

   The canonical install text lives in the jjhouse repository's README
   (local checkout: `~/Documents/personal/jjhouse/jjhouse-repo`).

4. **treehouse compatibility shim** — jjhouse ships a `treehouse`-compatible
   shim so orchestrators built for treehouse (e.g. firstmate) drive jjhouse
   unmodified:

   ```sh
   jjhouse shim install
   ```

   This puts a `treehouse` command on PATH (here `~/.local/bin/treehouse`);
   `jjhouse ...` and `treehouse ...` are interchangeable afterwards.

5. **no-mistakes** — the validation pipeline CLI used from the primary
   checkout (see [Validation](#validation)). The repo's `.no-mistakes.yaml`
   declares `no_ci: true` because the repo runs no CI checks.

## Repository model

This is a **colocated jj + git repo**: git and jj share one commit graph
(`jj git init --colocate` layout). Development is done through **jj**; raw
git *write* commands are avoided.

- **Bookmarks, not branches.** jj's bookmarks are the analogue of git
  branches — named pointers to commits — but they do not move with the
  working copy and are the unit of remote sync: `jj git push --bookmark
  fm/<topic>` publishes a bookmark to origin as a git branch. The local
  `main` bookmark is the base of all work.
- **Why not raw git writes.** The jjhouse pool is built on jj's single-writer
  model: every workspace shares one repo store and one append-only operation
  log, and jj merges concurrent operations losslessly. Raw git writes bypass
  that bookkeeping. jjhouse also installs `git`/`jj` shims in each workspace
  that map read-only git commands to their jj equivalents and refuse
  destructive git verbs with the jj equivalent — so reflexive `git` habits
  are caught before they can corrupt the shared store.
- **`jjhouse.toml`** at the repo root sets `base = "main"`: pool workspaces
  are created on and reset to the local `main` bookmark, because the repo has
  no remote default branch until the first PR lands (`trunk()` would resolve
  to the jj root commit and break the git view).
- **Workspace anatomy.** Each pool workspace is a real jj workspace (`.jj`)
  plus a **git view** — a linked git worktree of the colocated primary,
  synced to `base` at each handoff — so git-based read checks still pass. A
  session PATH fronts `git`/`jj` shims, and each workspace contains
  `JJ-AGENT.md` with the workspace invariants.

## The jj workflow

```sh
jj status   # the working copy IS the change; jj snapshots automatically
jj log      # history and bookmarks
```

Start work from a clean base and open a new change:

```sh
jj edit main   # point the working copy at the main bookmark
jj new         # new empty change on top of @
```

Name and label the change:

```sh
jj bookmark create fm/<topic>   # points the bookmark at @ (the default)
jj describe -m "what and why"   # label the change (describes @)
```

Amend while iterating — edits accumulate in `@`, and `jj describe` labels
them in place:

```sh
... edit files ...
jj describe -m "revised message"   # amends @
```

Publish and open a PR from the bookmark:

```sh
jj git push --bookmark fm/<topic>   # pushes to origin; new bookmarks are tracked automatically
gh-axi pr create --base main --head fm/<topic> \
  --title "..." --body "..."        # `gh` works too
```

Iterate: after further `jj describe` edits, `jj git push --bookmark
fm/<topic>` again — the remote bookmark moves (force-with-lease semantics:
the remote is only updated if its state matches what jj last fetched) and the
PR follows. No `--allow-new` flag is needed on current jj (0.44); naming the
bookmark explicitly is enough.

**No-mistakes interleave rule:** while a no-mistakes validation run owns a
branch, do not interleave local commits — the pipeline owns fixes during a
run.

## The jjhouse dev loop

The normal way to contribute to this repo:

```sh
# 1. Get an isolated, disposable workspace from the pool
jjhouse get        # drops you into a subshell; or `jjhouse get --exec <cmd>`
                   # → workspace at ~/.jjhouse/claude-many-<hash>/N/claude-many

# 2. Code with jj (see "The jj workflow")
jj edit main && jj new
... edit files ...
jj bookmark create fm/<topic>
jj describe -m "..."

# 3. Build and test (same commands as the README)
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test

#    The live smoke test is gated; opt in only when you really want two real
#    Claude instances launched against /tmp scratch dirs:
touch /tmp/claude-many-smoke-run
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test

# 4. Publish the bookmark and open the PR
jj git push --bookmark fm/<topic>
gh-axi pr create --base main --head fm/<topic> --title "..." --body "..."

# 5. Return the workspace (unlanded work is discarded; recoverable from the op log)
jjhouse return     # exiting the subshell returns it too
```

Pool management:

- `jjhouse status` — show the pool (run from the repo root; highlights
  leased and in-use workspaces).
- `jjhouse enter <name>` — observer subshell into a workspace; pool state is
  left untouched.
- `jjhouse return --unlanded park` — keep unlanded work under a
  `jjhouse/parked` bookmark instead of discarding it.
- Workspaces are disposable: the pushed bookmark + PR are the durable
  handoff. Every session is recorded in the shared operation log and
  harvested as an evidence ledger on return.

## Validation

- The **no-mistakes** pipeline runs from the **primary checkout**, not from
  pool workspaces: it reviews, tests, lints, pushes, and opens/updates PRs
  there. See the repo's `.no-mistakes.yaml` (`no_ci: true`).
- **ask-user findings** are answered by the project owner, never by an
  implementing agent.
- While a no-mistakes run owns a branch, the pipeline owns fixes during the
  run — do not interleave local commits.
- Never run the live smoke test casually: it launches real Claude Desktop
  instances (they are stopped and the /tmp scratch dirs cleaned afterwards,
  but they do appear on screen).
