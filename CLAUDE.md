# CLAUDE.md — Project context for Claude Code

This file orients a Claude Code session working on **ClaudeProjectHub**. It captures the design decisions, the lessons learned the hard way, and the current state of milestones so a fresh session can contribute without re-deriving everything.

Claude Code auto-loads this file as context when you open a session in this repo's root. Don't move it.

---

## Mission

A native macOS app that unifies management of Claude Code sessions across whichever terminal or IDE launches them — Terminal.app, iTerm2, VSCode, Rider, Ghostty, etc. — without reinventing terminal rendering.

The unifying insight: every CLI-launched `claude` session writes a JSONL transcript to `~/.claude/projects/<encoded-cwd>/` and a per-process metadata file to `~/.claude/sessions/<pid>.json`. Both are the same regardless of which terminal/IDE invoked `claude`. The hub treats those files as the source of truth and binds host windows via Accessibility (AX) so it can focus / close / track them.

## Tech stack

- Swift + SwiftUI + AppKit
- macOS 14+ deployment target (developed against macOS 26 / Xcode 16)
- Non-sandboxed (uses Accessibility + Automation/Apple Events)
- Direct distribution / Homebrew (not App Store)
- Personal Apple ID code-signing — see "Personal Team signing" below
- xcodegen for `.xcodeproj` generation

---

## UI shape

Two-pane `NavigationSplitView`:

- **Left**: Sessions sidebar. One row per session, running or closed.
- **Right**: Tabbed area. One tab per *running* session. Closed sessions don't get tabs.

Tab/sidebar click = focus the session's external host window via AX (raise + activate). The host stays in its own free-standing window — the hub does **not** dock external windows into its frame in v1. (Tab-area docking is a deferred milestone.)

Right-click menu:

- Running session: **Show**, **Rename…**, **Close**
- Closed session: **Resume…**, **Rename…**, **Remove from List**

Sort order: `working` → `idle` → `closed`, newest within each group.

---

## Session model

Sessions are **persistent records**, not transient PID-tied things. Stored as JSON at `~/Library/Application Support/ClaudeProjectHub/sessions.json`.

Fields (`Sources/Models/Session.swift`):

- `id`: hub-internal UUID
- `name`: optional user label (defaults to cwd basename)
- `cwd`: absolute path
- `hostID`: string referencing a `HostConfig` in the registry
- `claudeSessionId`: Claude's conversation UUID (the JSONL filename) — set ONCE at first launch and never overwritten (see "claude --resume" below)
- `status`: `idle` / `working` / `closed`
- `pid`: claude process PID (transient; cleared on close/load)
- `hostWindowID`: CGWindowID (transient; cleared on close/load)
- `createdAt`, `lastActivityAt`

Codable backwards-compat: legacy persisted records used `hostKind: HostKind` (an enum). The custom `init(from:)` accepts both `hostID` and legacy `hostKind` keys; encoding always writes `hostID`.

On hub launch, `SessionStore.load()` downgrades any persisted `idle`/`working` records to `closed` — we don't yet have process re-attachment, so live sessions from a previous hub run are treated as already-closed.

---

## Host registry

Every host is driven by a single AppleScript file. There's no built-in vs process distinction in the code — `ScriptedHostLauncher` is the only launcher, and a host's launch behavior lives entirely in its `.applescript`.

Two locations:

- **Bundled defaults** ship with the app at `Resources/Scripts/`: `terminal-app.applescript`, `iterm2.applescript`, and `_template.applescript` (a starter for user-added hosts). Copied into the user dir on first launch if not already present.
- **User scripts** at `~/Library/Application Support/ClaudeProjectHub/scripts/`. User edits are never overwritten — once a script is in this dir it stays. (See "Smart bundled-script updates" in the Deferred section for the planned hash-sidecar fix.)

Host metadata is in `~/Library/Application Support/ClaudeProjectHub/hosts.json`. Schema:

```json
{
  "id": "iterm2",
  "displayName": "iTerm2",
  "bundleIdentifier": "com.googlecode.iterm2",
  "launchScript": "iterm2.applescript"
}
```

Edits go through Settings (Cmd+, → Hosts tab) or directly to the JSON; both paths read/write the same file.

Placeholder substitution applied to the script before execution:

| Token | Value |
|---|---|
| `{cwd}` | absolute path of the working directory |
| `{claude}` | shell command — `claude` or `claude --resume <id>` |
| `{marker}` | unique tag (e.g. set as a tab title for AX matching) |
| `{mode}` | `"newWindow"` or `"newTab"` |
| `{targetWindowID}` | CGWindowID of the user-picked target window for newTab mode (`0` otherwise) |

Substituted strings are AppleScript-escaped (`\\` and `\"`), so `"{cwd}"` is safe inside a string literal.

Script return value: a positive integer is treated as the new window's CGWindowID — Swift binds the AX element directly via `AXSupport.waitForWindow(matching:in:)`. Returning `0` falls back to AX-diff discovery (snapshot of windows-before vs after). Use the direct path when the host's AppleScript dictionary exposes the window id; use the diff fallback for hosts driven by `do shell script` whose CLI doesn't return one.

For newTab mode, Swift AX-raises the user's target window before running the script, so `tell current window` / System Events keystrokes inside the script land on the right window without each script reinventing that dance.

`HostConfig.supportsNewTab` returns `true` for hosts whose default script handles newTab mode — currently a heuristic on `launchScript` filename (terminal-app, iterm2). Other hosts default to new-window-only.

---

## Lessons learned (the hard ones)

These took real debugging to find. Trust them.

### `claude --resume <id>` does NOT reuse the conversation's sessionId

The resumed `claude` process gets a **new** sessionId in `~/.claude/sessions/<pid>.json`, but the conversation continues to be appended to the **original** session's JSONL. So there are two distinct identifiers in play after a resume: the *process* sessionId (in the per-pid sessions file — useless for resume) and the *conversation* sessionId (the JSONL filename, what `--resume` expects).

**Implication:** capture the conversation id ONCE at first launch (write to `Session.claudeSessionId`) and never overwrite from the post-resume sessions file. `SessionLauncherService.discoverAndBind` uses set-once semantics:

```swift
store.update(id: sessionID) {
    if $0.claudeSessionId == nil {
        $0.claudeSessionId = sessionFile.sessionId
    }
}
```

There's also a recovery heuristic: if a session's stored `claudeSessionId` doesn't have a JSONL on disk (because of an earlier overwrite bug), and the cwd's encoded directory has *exactly one* JSONL, use it and persist the correction. We don't guess if there's more than one.

### Empty conversations can't be resumed

Claude assigns a sessionId at process startup but only writes the JSONL once a message is exchanged. A session opened and closed without typing anything has a captured sessionId but no JSONL. `SessionLauncherService.resume(_:)` pre-checks JSONL existence and surfaces a friendly hub-side error instead of dumping the user into a Terminal where `claude --resume` errors with "No conversation found."

### Hardened runtime requires the apple-events entitlement

With Hardened Runtime enabled but no `com.apple.security.automation.apple-events = true` entitlement, macOS **silently denies** all Apple Events from the app and refuses to even prompt the user. Symptom in `tccd` logs: `"Policy disallows prompt for com.bgentry.ClaudeProjectHub"`.

Fix lives in `Resources/ClaudeProjectHub.entitlements`. `project.yml` references it via `CODE_SIGN_ENTITLEMENTS: Resources/ClaudeProjectHub.entitlements`.

### Personal Team signing is sticky; ad-hoc isn't

With `CODE_SIGN_IDENTITY: "-"` (ad-hoc), every build re-signs with a new signature, breaking Accessibility / Automation grants on each rebuild — TCC ties grants to signatures. Switching to a stable Personal Team (`G5GR8NMG5U`) makes grants persist across rebuilds. The team ID lives in `project.yml`. Each contributor needs to set their own team — `security find-identity -v -p codesigning` shows it for paid teams; Personal Teams (free Apple ID) don't show in `find-identity` but exist in Xcode → Settings → Accounts.

### `~/.claude/sessions/<pid>.json` is the canonical per-process source

Schema:

```json
{
  "pid": 20198,
  "sessionId": "b60c1e74-73ff-470e-b7ab-ea3dd22cbb59",
  "cwd": "/Users/me/proj",
  "startedAt": 1777064286356,
  "version": "2.1.119",
  "kind": "interactive",
  "entrypoint": "cli",
  "status": "busy",
  "updatedAt": 1777300002654
}
```

Use this — not JSONL polling — for sessionId capture. The same source unlocks **idle/working detection** (its `status` field: `"busy"` → working, anything else → idle) and **external session adoption** (enumerate the directory to find every running claude on the machine, including ones the hub didn't launch). `Sources/Services/ClaudeSessionFile.swift` has both sync (`read(pid:)`) and async-with-retry (`read(pid:timeout:)`) readers.

### Terminal's AppleScript `make new tab/window` is non-functional

Listed in the dictionary, throws `AppleEvent handler failed (error -10000)` at runtime. Apple seems to have deliberately disabled them.

For Terminal's launcher:
- **Cold start (Terminal not running)**: `do script` lazily creates the startup window — one window with our command in it, no second window.
- **Warm start**: send System Events keystroke (Cmd-T or Cmd-N) AFTER an AX raise of the target window. AppleScript's `set index to 1` updates Terminal's internal ordering but **not** OS-level focus, which is what System Events keystrokes target. Without the AX raise, keystrokes fire into whichever window WindowServer still considers front.
- **Polling guard**: snapshot every Terminal window's tab count, fire the keystroke, then poll for ANY window whose count went up. If the keystroke went to the wrong window, don't run `do script` — that would inject `cd && claude` into an existing claude session.

### iTerm2's `id of current window` IS the CGWindowID

Verified empirically: `CGWindowListCopyWindowInfo` returns iTerm2 as owner when queried with the AppleScript-returned id. So `ITerm2Launcher` skips marker-in-title matching and pre/post-window diff entirely — the AppleScript returns the new window's id, Swift looks up the matching AX element directly via `AXSupport.waitForWindow(matching:in:)`.

iTerm2's AppleScript dictionary properly supports `create window` / `create tab`, so the launcher is much simpler than Terminal's — no System Events keystroke trickery.

### Window title doesn't survive shell/claude

For both Terminal and iTerm2, setting the tab/window title via AppleScript works *briefly* but the shell's first prompt and claude's startup print escape sequences that overwrite it within ~1 second. Don't rely on titles for AX binding when the host returns a window id directly. Use marker-in-title as a fallback only when no better option exists.

### `_AXUIElementGetWindow` is private but stable

Maps `AXUIElement` → `CGWindowID`. Used to bridge between AX-discovered windows and AppleScript-returned ids. Widely used by automation tools, stable across macOS versions, and **distinct from SkyLight private APIs** (which we deliberately avoid). See the declaration in `Sources/Services/AXSupport.swift`.

---

## Project layout

```
Sources/
├── App/
│   └── ClaudeProjectHubApp.swift           @main + scene + environment objects
├── Models/
│   ├── Session.swift                       persistent session record + Codable migration
│   ├── SessionStatus.swift                 idle / working / closed + sortRank
│   ├── HostConfig.swift                    id / displayName / bundleIdentifier / launchScript
│   ├── WindowMode.swift                    newWindow / newTab
│   └── DockState.swift                     docked(tabIndex) / undocked (future)
├── Stores/
│   ├── SessionStore.swift                  JSON persistence + selection state
│   └── HostRegistry.swift                  hosts.json + bundled-script copy on first run
├── Services/
│   ├── AccessibilityService.swift          AX trust check + prompt
│   ├── AXSupport.swift                     AX helpers (windows, title, raise, close, CGWindowID)
│   ├── AppleScriptRunner.swift             NSAppleScript wrapper
│   ├── ClaudeSessionFile.swift             reader for ~/.claude/sessions/<pid>.json
│   ├── SessionLauncherService.swift        orchestrates launch + resume + post-launch discovery
│   ├── SessionLifecycleMonitor.swift       2s poll while sessions running; updates status
│   └── WindowManager.swift                 AX bindings per session; focus, close
├── Launchers/
│   ├── SessionLauncher.swift               protocol + LaunchResult + LauncherError
│   ├── ShellCommand.swift                  shell-quoting + `claude` invocation builder
│   └── ScriptedHostLauncher.swift          the only launcher: substitutes + runs the host's script
└── UI/
    ├── MainView.swift                      NavigationSplitView wrapper
    ├── SessionsSidebar.swift               List with right-click menus + sheets
    ├── SessionRow.swift                    status dot + title + relative/static time
    ├── TabbedHostArea.swift                tab bar + detail card
    ├── NewSessionDialog.swift              + button → this sheet
    ├── ResumeSessionDialog.swift           Resume… right-click → this sheet
    ├── RenameSessionDialog.swift           Rename… right-click → this sheet
    ├── SettingsView.swift                  General + Hosts tabs (Cmd+,)
    ├── GeneralSettingsView.swift           appearance preferences
    ├── HostsSettingsView.swift             host list with native selection + double-click edit
    ├── HostEditorView.swift                add/edit a host (Display Name → Choose App → auto slug)
    ├── HostIconView.swift                  bundle-id-keyed icon resolution
    └── HelpPopover.swift                   (i) info-circle popover next to confusing labels
Resources/
├── Info.plist                              generated by xcodegen
├── ClaudeProjectHub.entitlements           apple-events entitlement
└── Scripts/                                bundled default scripts copied to user dir on first run
    ├── terminal-app.applescript
    ├── iterm2.applescript
    └── _template.applescript               starter for user-added hosts
project.yml                                  xcodegen config (commit; .xcodeproj is gitignored)
```

---

## Build workflow

`.xcodeproj/` is gitignored. `Resources/Info.plist` is also gitignored — both are regenerated from `project.yml`.

```bash
brew install xcodegen
xcodegen
open ClaudeProjectHub.xcodeproj
```

When you add or remove files in `Sources/`, re-run `xcodegen` so the project picks them up. Modifying existing files only requires a rebuild in Xcode, no xcodegen.

`project.yml` is the source of truth for project settings: deployment target, signing identity + team, entitlements path, recommended-settings opt-ins. Edit it rather than poking at the regenerated `.xcodeproj`.

If Xcode shows a "Update to recommended settings" prompt after `xcodegen`, the new build setting needs to be added to `project.yml`. We've already set `DEAD_CODE_STRIPPING`, `LOCALIZATION_PREFERS_STRING_CATALOGS`, and `STRING_CATALOG_GENERATE_SYMBOLS` for Xcode 16; add others as they appear.

## Permissions on first run

The hub requires:

1. **Accessibility** — System Settings → Privacy & Security → Accessibility. Prompted via `AXIsProcessTrustedWithOptions(prompt: true)`. Required for window focus / close / position.
2. **Automation/Apple Events**, per host — System Settings → Privacy & Security → Automation. Prompted on demand the first time each host is targeted via AppleScript.

If a permission seems stuck after granting:
- Quit and relaunch the app. TCC sometimes only re-evaluates trust on process start.
- Check for stale entries in System Settings — old build signatures can leave dead entries. Remove and re-grant if needed (less common with Personal Team signing in place).
- For TCC debugging: `tccutil reset AppleEvents com.bgentry.ClaudeProjectHub` resets the hub's Automation grants and forces fresh prompts. To debug *why* a denial is happening:

```bash
log stream --predicate 'process == "tccd" AND (eventMessage CONTAINS "ClaudeProjectHub" OR eventMessage CONTAINS "iTerm" OR eventMessage CONTAINS "Terminal")'
```

---

## Conventions

- **Terse code style.** Don't add docstrings to obvious things. Inline comments only when the *why* isn't obvious — typically explaining a workaround for a specific OS/library quirk we've documented in the "Lessons learned" section above.
- **No emojis** in code or commit messages unless explicitly asked.
- **Prefer cutting scope over expanding.** v1 has been deliberately trimmed multiple times. A working core beats an aspirational one.
- **One concept per commit** with a clear message body explaining *why*. Look at `git log` for the established style.
- **No AI attribution in commit messages.** Don't add `Co-Authored-By: Claude …` trailers or any other AI attribution. Commit bodies should read like normal human-authored messages. (Older commits in this repo's history have attribution from before this convention was set; that's fine, just don't add new ones.)
- **No CLAUDE.md edits without intent.** This file is ground truth for fresh sessions; keep it consistent with reality. Update it when you ship a milestone or learn a new gotcha.

---

## Milestones

### Done

- **M1–M4**: skeleton, launch, focus, lifecycle (auto-close on PID exit + manual Close)
- **M5**: Terminal warm-start AX raise + Cmd-T/N keystroke + tab-count-diff polling
- **M6**: JSON host registry — `HostConfig` + `HostRegistry` + strategy-based dispatch
- **M7 (partial)**: iTerm2 shipped as first non-Terminal host (direct CGWindowID lookup)
- **M7 — script-driven hosts** (2026-04-28): collapsed `TerminalAppLauncher` / `ITerm2Launcher` / `ProcessLauncher` into a single `ScriptedHostLauncher`. Every host is now one `.applescript` file in `~/Library/Application Support/ClaudeProjectHub/scripts/`; defaults ship in the bundle. New hosts are added through Settings → Hosts (Display Name + Choose Application + auto-slug), and the user can drop in any host with a script — no Swift code change needed. Dropped `HostStrategy` / `BuiltinKind` from the model.
- Resume from closed sessions (with stale-`claudeSessionId` recovery + empty-conversation guard)
- Idle/working status detection from `~/.claude/sessions/<pid>.json`
- Auto-select new session on launch
- Rename action (right-click → Rename…)
- Lifecycle monitor pauses when no sessions are running
- Settings UI (Cmd+, or gear icon in toolbar): General tab (appearance) + Hosts tab (CRUD editor for the registry)

### Open

#### Docking (current focus, branch `docking`) — 2026-04-29

The hub's central value prop and the next major focus, promoted out
of the deferred list. Foreign windows pinned to a hub-owned dock area
via AX (no SkyLight, no reparenting). Detailed plan and UX scenarios
in [DOCKING.md](DOCKING.md). Phase 0 starts with auditing what's
already in `WindowManager.swift` / `AXSupport.swift` and reviewing
the previous deferred docking work in git history.

#### M7 remainder

The "big 3 IDEs" we want to support:

- **VSCode**: `code <dir>` CLI + the Claude extension's "start session" command. Trigger mechanism is the open question (URL scheme, keyboard synthesis, or `code --command`). Investigation needed.
- **Xcode**: the odd one out — Xcode doesn't have an integrated terminal we can drive AppleScript into. Likely approach: open the project in Xcode AND spawn a separate Terminal/iTerm window with `claude` in the same dir, treating both as part of one logical "session." Needs design before implementation.
- **Android Studio**: IntelliJ-based, similar to other JetBrains products. Has an integrated terminal pane and a plugin system. Claude Code's Studio support, when it exists, will likely look like its JetBrains plugin behavior.

CLI-spawnable terminals (Ghostty, Alacritty, WezTerm, kitty, …) don't need new Swift code — add a host through Settings → Hosts and edit the generated `.applescript` (starts from `_template.applescript`) to `do shell script` the terminal's CLI with `{cwd}` and `{claude}` substituted in.

#### M8 — Sessions dashboard with cost estimates

A separate view showing a table of all sessions: Name / Directory / Status / Elapsed / Cost. Cost requires JSONL parsing + Anthropic pricing tables (hardcoded with a clear "as of YYYY-MM" comment). Independent of M7.

When starting M8, look at `~/ClaudeMultiAgentTemplate` (bgentry's other project) for existing JSONL parsing + cost-estimate logic to adapt rather than rebuild from scratch.

#### M9 — Documentation

This file (CLAUDE.md) and README.md are part of M9. Still open:

- **INTEGRATIONS_GUIDE.md** — how to add a new host: pick an app, edit its `.applescript` from `_template.applescript`, document the placeholder contract and the AX-diff fallback. Cross-reference the lessons in this file.
- **USER_GUIDE.md** — end-user flows: new session, resume, rename, adding a host through Settings or by editing `hosts.json` + a script directly.

### Deferred (no milestone, available anytime)

- **Smart bundled-script updates** — `HostRegistry.copyBundledScriptsIfMissing` only copies a bundled `.applescript` when the user's copy doesn't exist. So when we ship a fix to a default script (e.g. iterm2.applescript), existing installs keep their old copy and the user has to `rm` it manually to pick up the change. Fix: ship a hash sidecar (`.shipped.json` in the scripts dir) recording the SHA of each script as last shipped. On launch, hash the user's file — if it still matches the recorded SHA, they haven't edited it, so safely overwrite with the new bundle and update the sidecar. If it differs, leave alone. Distinguishes "user edited" from "we re-shipped" without timestamps.
- **Undocking** — depends on docking shipping first.
- **External session adoption** — enumerate `~/.claude/sessions/*.json` to find every running claude on the machine, including ones the hub didn't launch. `ClaudeSessionFile` is the foundation. Filter `kind == "interactive" && entrypoint == "cli"` to avoid sub-process / plugin sessions.

---

## Out of scope

Decided no, won't change without strong reason:

- **JSONL conversation viewer**: the docked external app IS the viewer; the hub never re-renders conversations.
- **Claude Desktop (Electron chat app) integration**: different product, different storage, different mental model. Out of scope.
- **Window reparenting / SkyLight private APIs**: macOS doesn't allow it cleanly. When tab-area docking returns, we use AX position/size on visible windows, not reparenting.
- **App Store distribution**: direct download / Homebrew. The non-sandboxed Accessibility + Automation requirements would be friction in a sandboxed App Store build.

---

## Quick orientation for a fresh Claude session

If you're a Claude session opening this repo for the first time:

1. Read this file completely.
2. Run `git log --oneline -20` to see recent work.
3. Run `ls Sources/Services/ Sources/Launchers/ Sources/Models/` to ground yourself in the structure.
4. The most opinionated files (where conventions matter most) are `SessionLauncherService.swift`, `ScriptedHostLauncher.swift`, and the bundled `Resources/Scripts/*.applescript`. Read the launcher end-to-end and pair it with `iterm2.applescript` to understand the lifecycle: `launch → substitute → AppleScript → return CGWindowID or fall back to AX diff → bind → SessionStore`.
5. Before suggesting design changes, search this file for relevant "Lessons learned" entries — most non-obvious choices are documented there.
6. When you ship something, update the "Milestones" section here. Don't let the file go stale.
