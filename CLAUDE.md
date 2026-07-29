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

## Docking architecture

The hub doesn't reparent foreign windows — that requires SkyLight private APIs we deliberately avoid. Each docked host window stays a top-level OS window owned by its own app; the hub uses AX to pin its frame to a "dock area" rectangle inside the hub. When the hub moves or resizes, AX `kAXMovedNotification` / `kAXResizedNotification` on our own NSWindow triggers a `setFrame` for each docked foreign window. Same model every macOS window manager uses (Magnet, Rectangle, Yabai, AeroSpace).

What this gets us:
- Public AX API; stable across macOS versions
- Foreign apps keep their own focus, keyboard handling, scroll, etc.
- Undocking is just "stop tracking and let it free-float"
- No risk of orphaned/mis-rendered windows from reparenting

What it doesn't get us:
- Foreign window pixels can't be composited inside our SwiftUI view hierarchy. The dock area is a placeholder; the actual pixels overlay it from a different window.
- The hub's UI can't render above a docked window without window-level tricks (private/messy).

Key files:
- `Services/DockController.swift` — owns the set of docked session ids; reacts to hub move/resize and writes new frames to all docked windows
- `Services/AXObserver.swift` — wraps the C-level AXObserver API; subscribes to `kAXMoved`, `kAXResized`, `kAXUIElementDestroyed`, `kAXTitleChanged`, `kAXWindowMiniaturized`, `kAXWindowDeminiaturized`
- `Services/AXWriteTracker.swift` — when we `setFrame` or `raise`, we record the (window, attribute, timestamp) tuple. AX events that match a recent write are flagged as not user-initiated, preventing cascade loops between our own writes and the resulting notifications
- `Services/HubMouseGate.swift` — toggles `NSWindow.ignoresMouseEvents` based on cursor position vs the dock rect, so clicks over the dock area pass through to the foreign window underneath. Uses 30Hz polling rather than NSEvent monitors (see Lessons learned re: cmd-tab teleport leaving the gate stale)

Undock-on-titlebar-drag threshold is 30px from the dock rect (Magnet-style). When the user drags a foreign window's title bar more than that distance, the AX position-changed event arrives with our `AXWriteTracker` flag absent (i.e. user-initiated) and `DockController` releases tracking.

Tab switching for hosts that share one window across sessions (iTerm2 tabs, Terminal tabs) uses `Services/HostTabSelector.swift` to issue a host-specific AppleScript switch-to-tab call when the active session changes. iTerm2 returns the same `CGWindowID` for every tab in a window; the controlling tty distinguishes which session "is" which tab.

Minimized/hidden state lives in two sets on `DockController`:
- `minimizedSessionIDs` — docked sessions whose foreign window is currently minimized (Cmd-M, fed by AX `kAXWindowMiniaturized/Deminiaturized`) or whose foreign app is hidden (Cmd-H, fed by `NSWorkspace.didHide/UnhideApplication`). The raise + snap-back paths guard on this set so the hub doesn't fight the user's hide gesture. Active sessions in this set get auto-promoted to a sibling so the dock area shows a real window instead of an empty hole; if no sibling is available, `TabbedHostArea` renders an `eye.slash` placeholder.
- `hubMinimizedSessionIDs` — sessions the hub itself minimized as part of a hub-window minimize. The matching restore un-minimizes only this set, so sessions the user had individually minimized stay minimized through a hub round-trip.

Each docked session's row in the sidebar and its tab chip render italic + 0.7 opacity while in `minimizedSessionIDs`, so the UI vocabulary for "this session is alive but currently hidden" matches across both surfaces.

---

## Lessons learned (the hard ones)

These took real debugging to find. Trust them.

### `claude --resume <id>` does NOT reuse the conversation's sessionId

The resumed `claude` process gets a **new** sessionId in `~/.claude/sessions/<pid>.json`, but the conversation continues to be appended to the **original** session's JSONL. So there are two distinct identifiers in play after a resume: the *process* sessionId (in the per-pid sessions file — useless for resume) and the *conversation* sessionId (the JSONL filename, what `--resume` expects).

**Version qualifier (verified twice, 2026-07-29, claude 2.1.197):** on current versions the per-pid file's `sessionId` *is* the conversation id after a `--resume` — the two ids coincide. `SessionLauncherService.reconcileStaleClosedSessions()` depends on that (it matches live per-pid `sessionId` against the stored `claudeSessionId` to detect an externally-resumed session). The set-once semantics below are still correct and still load-bearing — don't remove them — but don't assume the per-pid id is useless either. If reconcile ever stops finding externally-resumed sessions, suspect this behavior changed and compare `~/.claude/sessions/<pid>.json` against the JSONL filename before touching anything else.

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

With `CODE_SIGN_IDENTITY: "-"` (ad-hoc), every build re-signs with a new signature, breaking Accessibility / Automation grants on each rebuild — TCC ties grants to signatures. Switching to a stable Personal Team makes grants persist across rebuilds.

The team ID is per-developer and lives in `signing.xcconfig` (gitignored), not `project.yml`. Each contributor copies `signing.xcconfig.example` → `signing.xcconfig` and fills in their own `DEVELOPMENT_TEAM` value. Find your team ID via `security find-identity -v -p codesigning` (paid teams) or Xcode → Settings → Accounts → your Apple ID → Manage Certificates (Personal Teams from a free Apple ID).

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

### Cmd-H is app-level, Cmd-M is window-level — two different observers

`kAXWindowMiniaturizedNotification` fires only for Cmd-M / yellow button (per-window minimize). Cmd-H is at the application level — it hides every window the app owns at once — and AX has no per-window event for it. To respect Cmd-H of a docked foreign app the hub also subscribes to `NSWorkspace.didHide` / `didUnhideApplication` and sweeps every docked session whose host pid matches.

Also: `AXSupport.raise` sets `kAXMain` + `kAXFocused` before `AXRaise` (originally added for JBR), and on a hidden window those writes can un-hide the foreign app. So the hub's "re-raise the active docked window on becoming frontmost" path *must* guard on `minimizedSessionIDs` — without that guard, cmd-tabbing back to the hub would defeat the user's Cmd-H every time.

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
│   ├── DockState.swift                     docked(tabIndex) / undocked (future)
│   ├── ModelPricing.swift                  Codable shape for models.json (per-1M-token rates)
│   └── SessionUsage.swift                  per-model token totals + cost calc
├── Stores/
│   ├── SessionStore.swift                  JSON persistence + selection state
│   └── HostRegistry.swift                  hosts.json + bundled-script copy on first run
├── Services/
│   ├── AccessibilityService.swift          AX trust check + prompt
│   ├── AXSupport.swift                     AX helpers (windows, title, raise, close, CGWindowID)
│   ├── AppleScriptRunner.swift             NSAppleScript wrapper
│   ├── ClaudeSessionFile.swift             reader for ~/.claude/sessions/<pid>.json
│   ├── ClaudeSessionTranscript.swift       JSONL parser for per-message usage → SessionUsage
│   ├── ModelPricingRegistry.swift          loads models.json, lookup by model id
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
    ├── SessionInfoView.swift               Get Info popout: cost + tokens per session
    ├── HubWindowConfigurator.swift         transparent NSWindow + frame autosave to UserDefaults
    ├── SettingsView.swift                  General + Hosts tabs (Cmd+,)
    ├── GeneralSettingsView.swift           appearance preferences
    ├── HostsSettingsView.swift             host list with native selection + double-click edit
    ├── HostEditorView.swift                add/edit a host (Display Name → Choose App → auto slug)
    ├── HostIconView.swift                  bundle-id-keyed icon resolution
    └── HelpPopover.swift                   (i) info-circle popover next to confusing labels
Resources/
├── Info.plist                              generated by xcodegen
├── ClaudeProjectHub.entitlements           apple-events entitlement
├── models.json                             Claude model pricing (per-1M-token rates, "as of" 2026-05)
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
- **M7 — script-driven hosts** (2026-04-28): collapsed `TerminalAppLauncher` / `ITerm2Launcher` / `ProcessLauncher` into a single `ScriptedHostLauncher`. Every host is now one `.applescript` file in `~/Library/Application Support/ClaudeProjectHub/scripts/`; defaults ship in the bundle. New hosts are added through Settings → Hosts (Display Name + Choose Application + auto-slug), and the user can drop in any host with a script — no Swift code change needed. Dropped `HostStrategy` / `BuiltinKind` from the model.
- **M7 hosts shipped**: Terminal, iTerm2 (direct CGWindowID lookup, with iTermServer/tmux fallback via controlling-tty matching), VSCode (integrated-terminal launch via System Events keystroke).
- **Docking phases 1-6** (2026-04-30): foreign windows pinned to the hub's dock rect via AX. Hub window is transparent at the dock area with `HubMouseGate` toggling `ignoresMouseEvents` so clicks pass through to the foreign window. Spawn-into-dock, drag-titlebar-out + 30px-threshold-snap-back undocking, right-click "Undock", external session adoption via `ExternalSessionScanner` + sidebar "Available to Dock" section, Cmd-1..9 tab keyboard shortcuts, per-tab AppleScript switching for hosts that share a window across multiple sessions (iTerm2 tabs, Terminal tabs). See the "Docking architecture" section above for the design.
- **Docking Phase 8 — minimize/hide handling** (2026-05-17): docked foreign windows now respect Cmd-M (window minimize) and Cmd-H (app hide) without the hub fighting the gesture. `DockController.minimizedSessionIDs` is populated by AX `kAXWindowMiniaturized` and by NSWorkspace `didHide/UnhideApplication` notifications; the raise + snap-back paths guard on it. When the active session is hidden, the next-most-recently-docked sibling auto-promotes so the dock area shows a real window instead of an empty hole; the muted session's sidebar row and tab go italic + 0.7 opacity. When *all* docked sessions are hidden, the dock area shows an `eye.slash` placeholder ("All docked sessions are hidden. Click a tab to bring one back."). Hub minimize/restore propagates to all currently-visible docked windows via `kAXMinimizedAttribute` writes; sessions the user had individually minimized stay minimized through a hub round-trip. Step 6 of the sketch (undock-on-hub-close) was attempted then reverted — both red-button close (DockController state survives) and Cmd-Q (relaunch hits `reattachAll`) already do the right thing.
- **Reattach on hub restart**: sessions whose underlying claude pid is still alive are re-bound and re-docked at startup via `SessionLauncherService.reattachAll()`. Dead pids are marked closed.
- **`selectedSessionID` persisted across restarts**: `SessionStore` mirrors `selectedSessionID` to UserDefaults (`ClaudeProjectHubSelectedSessionID`) and restores it after `load()`. `SessionLauncherService.reattachAll` honors the restored value — if it matches a docked session, that session is made active via `setActiveSessionID` after the reattach loop. Without this, the default-active after relaunch was always the *most recently created* session (last in the iteration order), not the one the user had selected.
- **Attention badge dismisses on docked-window click**: `AttentionService` observes `NSWorkspace.didActivateApplication`. When the host app of the currently-selected session becomes frontmost (the user clicked into the docked foreign window via the click-through dock area), the badge clears. Previously only an explicit hub-side selection change cleared it, so clicking into the docked window when the badged session was already selected left the badge stuck.
- **App icon and combination mark** (2026-05-04): 7-spoke hub-and-satellite glyph on a Claude-warm squircle. Icon set wired through `Resources/Assets.xcassets/AppIcon.appiconset` + `ASSETCATALOG_COMPILER_APPICON_NAME` + `CFBundleIconName`. Combination mark (icon + "Claude Project Hub" wordmark) at `logos/iterations/iteration-8.svg`. Reusable Swift export script at `logos/export.swift` uses NSImage's native SVG support.
- **Per-developer signing setup**: `DEVELOPMENT_TEAM` lives in `signing.xcconfig` (gitignored). Each contributor copies `signing.xcconfig.example` → `signing.xcconfig` and fills in their team id. `project.yml` references the xcconfig via `configFiles` so collaborators no longer have to edit `project.yml` to build. Second scheme `ClaudeProjectHub (Release)` so ⌘B targets Release without flipping the default scheme.
- **Dock-area resize inset**: 8px on the right and bottom of the dock area so the hub's NSWindow resize edges remain exposed when foreign windows are docked. Visually matches the sidebar's natural margin.
- **M9 — Documentation** (2026-05-03): README refreshed (12 hosts, accurate project layout, signing setup, combination mark at top, dropped stale references). `USER_GUIDE.md` for end-user flows (permissions, session lifecycle, docking, Get Info, notifications, Settings, files on disk, quirks). `INTEGRATIONS_GUIDE.md` for contributors adding hosts (placeholder + return-value contracts, three patterns with examples, lessons baked into bundled scripts, testing checklist). `DOCKING.md` distilled into the "Docking architecture" subsection of this file and deleted. All docs grouped under "Docs" in the Xcode project tree.
- **M10 — Idle session notifications** (2026-05-02): when a session transitions `.working` → `.idle` with a 2.5s debounce, the sidebar row shows a pulsing red `systemRed` attention badge. If the hub isn't frontmost, a `UserNotifications` banner fires with the session's display title; clicking it focuses the hub and selects the session. Settings → General → "Notify when a session goes idle" toggles the banner (the in-app badge always shows). Authorization requested via `UNUserNotificationCenter.requestAuthorization` on first idle.
- **M8 — Per-session Get Info window** (2026-05-01, scoped down from a global dashboard): right-click any session → "Get Info" opens a popout showing cost + per-model token usage parsed from the JSONL transcript. Pricing data lives in `Resources/models.json` (Claude 4.x family with 5m + 1h cache write rates and cache-read rates per 1M tokens, as of 2026-05); copies to `~/Library/Application Support/ClaudeProjectHub/models.json` on first run for user editability. JSONL parser is `ClaudeSessionTranscript`. Window also has "Show in Finder" buttons next to the project directory and the Claude session id; transcript-not-yet-recorded sessions get an alert matching the Resume "no conversation found" pattern.
- **Hub window state persistence**: hub window frame saved/restored via `UserDefaults` in `HubWindowConfigurator`. SwiftUI's stock state restoration didn't apply consistently with our manual NSWindow configuration; direct save-on-resize/move + restore-on-appear is unambiguous and screen-aware (won't restore an off-screen frame from a previous monitor layout).
- Resume from closed sessions (with stale-`claudeSessionId` recovery + empty-conversation guard)
- Idle/working status detection from `~/.claude/sessions/<pid>.json`
- Auto-select new session on launch
- Rename action (right-click → Rename…)
- Lifecycle monitor pauses when no sessions are running
- Settings UI (Cmd+, or gear icon in toolbar): General tab (appearance) + Hosts tab (CRUD editor for the registry)
- **M11 — Historical session discovery** (2026-05-26): closed claude conversations the hub didn't launch are now surfaced in the sidebar's "Available to Resume" section. `HistoricalSessionScanner` walks `~/.claude/projects/<encoded-cwd>/` every 10s, preferring each dir's `sessions-index.json` (claude-written manifest with `sessionId`, `projectPath` — the real undecoded cwd — `fileMtime`, `messageCount`, `summary`/`firstPrompt`, `gitBranch`); falls back to globbing `*.jsonl` + a >1 KB size heuristic when no index is present. Excludes anything already in `sessions.json` and anything whose pid is alive in `~/.claude/sessions/` (deferring to `ExternalSessionScanner`). Filter `messageCount >= 1` honors the "Empty conversations can't be resumed" lesson. Right-click → Resume… opens `HistoricalResumeDialog`, a host picker + window-mode chooser (no host affinity is recorded in the JSONL, so the user must pick); confirming calls `SessionLauncherService.adoptHistorical(_:hostID:windowMode:targetSessionID:)` which creates a `Session(status: .closed)` and runs the standard resume path against it. The CLAUDE.md proposal floated adopt-as-closed vs. adopt-and-immediately-resume; ship chose the latter because the user's intent is "resume this," not "import this." `sessions-index.json` schema verified empirically 2026-05-26; may evolve with claude versions — defensive optional decoding.
- **Session-tracking robustness audit** (2026-06-14 → 2026-06-15): 3-agent audit of "why does the hub sometimes fail to switch to a session it's hosting" surfaced five gaps. Shipped fixes:
  - **Persist `hostWindowID` as a reattach breadcrumb** (commit `14e9025`): `Session.hostWindowID` was previously dead code — nil'd on load, never populated at runtime. Now mirrored via `bindAndPersist()` whenever `WindowManager.bind` is called; preserved for running sessions across hub restart. `reattach()` probes it first via new `AXSupport.findWindow(matching:in:)` (non-polling, so a stale id doesn't burn the 3s `waitForWindow` timeout) before falling through to `match.cgWindowID` then to focused/first window. Prevents cross-wiring to a sibling's window when a host has multiple windows open.
  - **Validate AX elements before raise; log AX failures** (commit `1a66725`): `AXSupport.raise()` now probes `elementIsLive(_:)` via a `kAXRoleAttribute` read before writing; returns `false` on dangling. `WindowManager.focus`, `DockController.raiseActive`, and `raiseActiveWithoutFocus` drop stale bindings (via `undock(restoreFrame: false)` for the DockController paths). Non-success individual writes are logged at `.notice` but not treated as failure — JBR-backed apps routinely report errors while working. All AX-layer status routes through `os.Logger` subsystem `com.bgentry.ClaudeProjectHub`, category `AX`.
  - **Survive sleep/wake and tty races** (commit `28f90f9`): three complementary fixes. (D) `SessionLifecycleMonitor.poll` re-derives a missing `tabID` for any docked session with a live pid — catches launch-time `ProcessTree.controllingTTY(of:)` returning nil (kernel hadn't yet assigned a tty), which previously broke per-tab AppleScript routing forever. Category `Lifecycle`. (G) `DockController.handleDestroyEvent` defers 500ms and rechecks the cached CGWindowID against `CGWindowListCopyWindowInfo` — spurious destroys during sleep/wake / display reconfig no longer undock. Category `Dock`. (H) `SessionLauncherService` subscribes to `NSWorkspace.didWakeNotification` and, after a 1s settle, runs `reattachAll()`. Belt-and-suspenders with G.
  - **Re-pin on display change; undock all tab-siblings on destroy** (commit `593bb46`): (1) `DockController` observes `NSApplication.didChangeScreenParametersNotification`, debounces 400ms (monitor connect / lid close fires 3-5 events), then re-pins every docked session to the current dock rect — macOS migrates foreign windows between screens on monitor (un)plug and lid-close-with-external, and without this they drift off. (2) `handleDestroyEvent` undocks *every* session bound to the destroyed element via new `sessionIDs(for:)` plural helper; the old singular `sessionID(for:)` left tab-siblings (which share one AXUIElement) behind as zombies when the shared window died. Verified 2026-07-29 against monitor plug/unplug + clamshell.
  - **Never bind non-window AX elements; reconcile stale-closed** (commit `c41ee33`): fixes docked sessions going permanently unresponsive after sleep/wake or display change. Root cause: CGWindowIDs change across wake, so reattach's cgID lookups miss and drop to a fallback that — during the post-wake AX-confused window — returned iTerm2's *application element* instead of a window. `elementIsLive` accepted it (answers `kAXRole`) but every window op returned `-25205`/`-25206` (Unsupported), so clicks silently no-op'd. Fixes: `AXSupport.windows(of:)` filters to `kAXWindowRole`; `focusedWindow(of:)` validates role; `raise()` returns false for a live-non-window element that rejects all of main/focus/raise (JBR windows that flakily error still return true); `reattach` won't close a session whose claude pid is still alive on a transient wake miss (`closeSessionIfProcessDead`). Also lands `reconcileStaleClosedSessions`: at reattach, promote a `.closed` record back to `.idle` if a live claude process shares its `claudeSessionId` (hub gave up but process survived, or user externally re-ran `claude --resume`). Key diagnostic lesson: in the AX logs, **`element is dangling` = healthy recovery** (stale binding across a display/wake transition, re-bound correctly after); **`role=AXApplication` / `not a raisable window` = the bug** (now absent).
  - **New Session dialog UX** (commit `ccfd59b`): tab-target picker groups by `hostWindowID` (N tabs in one window → one row, comma-joined labels) instead of listing raw sessions that all resolved to the same window; "New tab in an existing window…" stays always-visible-but-disabled (custom radio rows — `Picker(.radioGroup)` can't disable individual options) with a help tooltip; `WindowMode.newWindow` label changed "New Terminal window" → "New window" (host-agnostic — the host is already shown in the dropdown; flows through Resume + Historical Resume dialogs too).
  - **Tab drops with the window, not the process** (commit `651cc67`, 2026-07-29): fixes the 3-5s lag before a closed host window cleared from the hub. Two parts. (1) **Event-driven process exit** — each running session gets a `DispatchSourceProcess` watching `.exit` (kqueue `NOTE_EXIT`) in `SessionLifecycleMonitor`, so `status` flips the instant the pid dies instead of up to a 2s poll later. Watchers are keyed by session id *and* tagged with the watched pid, so a session returning on a different pid (reconcile promoting a stale-closed record) gets its watcher rebuilt. The 2s poll remains for what needs sampling — busy/idle refinement, the tabID self-heal, a liveness backstop — and both paths funnel through one idempotent `markClosed`. (2) **Tab decoupled from process liveness** — a tab's contract is "click me to see that window," so a tab whose window is destroyed is a broken affordance regardless of process state. `TabbedHostArea` now filters on running *and* still window-backed; `WindowManager` publishes `boundSessionIDs` (synced by `didSet` on `bindings` so no mutation site can forget); `DockController` takes a `WindowManager` reference and releases the binding on a confirmed destroy. Net: tab disappears with the window (~500ms, matching the undocked indicator) while the sidebar row honestly shows the session running until its pid exits. Undocking a live session still keeps its tab. **Key measurement:** a claude process outlives its host window by ~5s (iTerm2 teardown + claude's SIGHUP cleanup) — so detection speed alone could never have fixed this; see the corrected entry in Deferred for the misdiagnosis worth learning from.
  - **Reconcile externally-resumed sessions on hub activation** (commit `edd3276`, 2026-07-29): `reconcileStaleClosedSessions()` previously ran only from `reattachAll()` — hub startup and system wake. So the most common way to strand a record went unnoticed: the user runs `claude --resume <id>` in a terminal themselves while the hub is already running and awake. The record stayed `.closed` while `ExternalSessionScanner` skipped the live process (its sessionId *is* tracked), leaving the session in a gap — seen by one component, disowned by the other; recoverable only by restarting the hub. Now also reconciles on `NSApplication.didBecomeActiveNotification`, catching it in the natural flow (resume in terminal → switch to hub → correct). `reconcileStaleClosedSessions()` returns the promoted ids so only those reattach; `isReconciling` guards overlapping activations. **Deliberately no polling timer** — every stale-closed path is already an observed event (external resume → activation, spurious close → `didWake`, hub restart → startup); the sole gap is a session going stale while the hub sits visible-but-never-activated on another display, which self-heals on click. Rationale is in the code so it doesn't get "fixed" with a timer later. Also fixes a stale `hostID`: a session can return in a different host than the record remembers (record says iTerm2, user resumed in Terminal) — the dock already used the resolved host, but the persisted record kept the old id, so the sidebar showed the wrong host name and icon.
  - **Follow hub selection on external focus — roadmap step 3** (commit `33593ad`, 2026-07-29): when the user brings a docked host window to the front *outside* the hub (click it, or cmd-tab / Dock / Mission Control to the host app), the hub's sidebar + tab selection follows to that session. **Selection-only — no window moves, focus stays where the user put it** (this was a deliberate design choice over "raise the hub," to avoid stealing focus from the terminal the user just clicked). Two trigger paths into `DockController.syncSelection`: `kAXFocusedWindowChangedNotification` subscribed once per host pid on the *application* element (`appFocusSubscribedPIDs`), and `NSWorkspace.didActivateApplicationNotification` for the cmd-tab-to-host case. `syncSelection` sets `activeSessionID` *before* `store.selectedSessionID` — ordering is load-bearing: `MainView.onChange` → `setActiveSessionID` early-returns when the id is already active, so nothing raises; the `activeSessionID != sessionID` guard is also the loop-breaker against our own raises re-firing `focusedWindowChanged`. `AXSupport.focusedWindow(ofApplication:)` is role-validated. Scope: **docked sessions only** (mapped via DockController bindings) — undocked/free-floating sessions aren't synced yet (see follow-up below). The ⌘⇧F "Focus Active Session" shortcut stays one-way (push focus to the session; no toggle back — confirmed intentional 2026-07-29).

### Session-tracking audit — full findings, in case some become useful later

Prompted a survey of window-manager patterns (AeroSpace, Amethyst, Rectangle, Hammerspoon, AltTab). Key non-adopted findings we may return to:

1. **Daemon + UI split**: investigated, deliberately rejected. Every single-purpose WM-adjacent Mac app in the survey (Hammerspoon, AltTab, Rectangle, Amethyst, AeroSpace) is single-binary. Splitting doubles TCC grants, loses `NSWorkspace` (not daemon-safe), and doesn't unlock capabilities we can't reach from the existing process. If revisited: `XPCSession` (macOS 14+) is the right IPC.
2. **AeroSpace's `NSWorkspace.didLaunchApplicationNotification` reattach pattern**: canonical impl at [AeroSpace `GlobalObserver.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/GlobalObserver.swift) — a fleet of NSWorkspace observers debounced into one `refresh()` that re-walks `NSWorkspace.shared.runningApplications`. Amethyst uses Carbon `kEventAppLaunched` for earlier delivery. Estimated ~35-50 LOC to add to the hub. Handles the "host app crashes and user relaunches" case we currently can't recover from without a hub restart.
3. **`AccessibilityElement` wrapper (Rectangle)**: `~500 LOC` class wrapping `AXUIElement` with typed optional-return accessors + the `enhancedUserInterface` Electron workaround for Slack/VSCode/Chrome. Consider lifting the `enhancedUserInterface` pattern separately if VSCode frame writes ever misbehave.
4. **`NSApplication.didChangeScreenParametersNotification` handling** — Amethyst's `Screens.updateScreens()` re-fetches `NSScreen` on cached `ScreenManager` objects rather than replacing them. Neither AeroSpace nor Rectangle nor Amethyst handles the "monitor plug + lid close" case cleanly per open issues (Amethyst #1436/#1667, AeroSpace #333). We'd be shipping better than the state of the art.

### Open

### Open

#### M7 remainder

The "big 3 IDEs" — VSCode is shipped, two left:

- **Xcode**: the odd one out — Xcode doesn't have an integrated terminal we can drive AppleScript into. Likely approach: open the project in Xcode AND spawn a separate Terminal/iTerm window with `claude` in the same dir, treating both as part of one logical "session." Needs design before implementation.
- **Android Studio**: IntelliJ-based, similar to other JetBrains products. Has an integrated terminal pane and a plugin system. Claude Code's Studio support, when it exists, will likely look like its JetBrains plugin behavior.

CLI-spawnable terminals (Ghostty, Alacritty, WezTerm, kitty, …) don't need new Swift code — add a host through Settings → Hosts and edit the generated `.applescript` (starts from `_template.applescript`) to `do shell script` the terminal's CLI with `{cwd}` and `{claude}` substituted in.

#### M8 — Global sessions dashboard

The per-session Get Info popout shipped (see Done above). A *cross-session* dashboard — a table of all hub-tracked + external claude sessions on the machine with sortable columns, total cost, time-range filters — was intentionally deferred to keep scope tight. Most of the foundation is already in place: `ClaudeSessionTranscript` parses JSONLs, `ModelPricingRegistry` does cost lookup, `ClaudeSessionFile.enumerateAll` walks `~/.claude/sessions/`. When this is picked back up, it's mostly a SwiftUI `Table` over those existing primitives.

#### Docking Phase 9 polish

Tab icons + larger chips shipped. Remaining: animation on dock/undock, tab thumbnails (would use ScreenCaptureKit), drag-to-reorder tabs.

#### Session-tracking audit follow-ups — remaining roadmap

The five in-progress items from the audit all shipped 2026-07-28/29 (commits `593bb46`, `c41ee33`, `ccfd59b`), and step 3 shipped 2026-07-29 (commit `33593ad`) — all in Done above. Remaining:

- **Step 4: `NSWorkspace.didLaunchApplicationNotification` reattach** (~35-50 LOC). **Next up** (still unbuilt — a first attempt at testing it on 2026-07-29 was inconclusive because ⌘Q of iTerm2 without session-restoration kills the claude processes outright, so there was nothing to reattach; the shipped `edd3276` reconcile covered the case that actually surfaced instead). Note when testing: step 4 only has something to do when the host dies but claude *survives* — a real host crash, or ⌘Q with iTerm2 session restoration enabled so `iTermServer` outlives the GUI app. For Terminal/VSCode, quitting kills the shells and the sessions correctly go `.closed`. Also note `DockController.dock()` early-returns for a session already in `dockedSessionIDs`, so a relaunch sweep must release the dead dock binding first or the replacement window never gets pinned. Handles the case where a host app crashes/quits and the user relaunches it — new pid, existing AX bindings all dead. Model on AeroSpace's `GlobalObserver.swift`; extract `SessionLauncherService.reattachAll()`'s body into a `reattach(forBundleID:)` variant, dispatch on host bundle-id matching. Note: `DockController` now already observes `didActivateApplication` (added in step 3) — step 4 adds the *launch* counterpart. The `reconcileStaleClosedSessions` + role-validated binding fixes from `c41ee33` should make the relaunch rebind land on the right window without the app-element mis-binding that plagued the wake path.
- **Follow-up (from step 3): sync selection for undocked sessions too.** Step 3's external-focus sync only covers docked sessions (`DockController` bindings). Undocked/free-floating running sessions live in `WindowManager.bindings`, not DockController — so focusing one outside the hub doesn't move the hub selection. Extend by mapping the focused window against WindowManager's bindings as well. Low priority; surfaced only if the docked-only scope feels incomplete in use.
- **Follow-up (from the tab-decoupling work): recover a running session that has no window.** A claude process can outlive its host window (iTerm2 session restoration), which now correctly shows as a sidebar row with no tab. Recovery currently only happens via the wake handler or a hub restart — deliberately *not* wired into hub activation, because `HostWindowResolver.resolve` runs a synchronous AppleScript on the main actor and firing it on every activation during the windowless gap risks a UI hitch. If this state proves common, the fix is an async/off-main resolve path first, then hook it up.

### Deferred (no milestone, available anytime)

- **Smart bundled-script updates** — `HostRegistry.copyBundledScriptsIfMissing` only copies a bundled `.applescript` when the user's copy doesn't exist. So when we ship a fix to a default script (e.g. iterm2.applescript), existing installs keep their old copy and the user has to `rm` it manually to pick up the change. Fix: ship a hash sidecar (`.shipped.json` in the scripts dir) recording the SHA of each script as last shipped. On launch, hash the user's file — if it still matches the recorded SHA, they haven't edited it, so safely overwrite with the new bundle and update the sidecar. If it differs, leave alone. Distinguishes "user edited" from "we re-shipped" without timestamps.
- **Drag-foreign-window-into-hub** — proximity-based dock: AX move observers on candidate foreign windows (the apps hosting active claude sessions per `ClaudeSessionFile` enumeration) + a SwiftUI drop-zone overlay in the hub's dock area. macOS doesn't expose drag start/end events for foreign windows, so drag-end has to be inferred from a short AX-move-quiet timeout (~200ms) — needs empirical tuning to avoid false drops when the user pauses mid-drag. Complementary to "adopt and dock"; the latter is the deterministic fallback when the gesture isn't discoverable.
- **Multi-monitor edge cases** — pin docked windows to the hub's screen, follow the hub if the user drags it to a different display, behave correctly across mixed-DPI setups. Today's code mostly works (NSWindow.convertToScreen handles screen coords), but hasn't been tested rigorously across configurations.
- **AX-trust-loss handling** — if the user revokes Accessibility permission mid-session, gracefully release docked windows and surface an error rather than silently malfunctioning.
- **Eliminate the two "Publishing changes from within view updates" warnings** — currently fire on every successful sidebar/tab click. Don't appear to cause observable bugs (the noisy bug was the simultaneousGesture cascade we already removed), but ideally fix by routing the active-tab sync through a Combine subscription on `store.$selectedSessionID` in `DockController.init` instead of `.onChange` in MainView.
- **Restore minimized session on re-click of already-selected row** — when the user Cmd-H's or Cmd-M's a docked session that's also the hub's selected row, the sidebar click path can't restore it because SwiftUI's `List` selection binding only fires `onChange` on a *different* selection. The user's current workaround is select another session then back. We tried `.onTapGesture(count: 2)` on the sidebar row + a `DockController.bringActive` force-forward method (see git history around 2026-05-16), but the gesture made single-click selection behavior inconsistent on macOS Lists and was reverted. Alternatives to explore: (a) update the existing right-click → "Show" action to call a force-forward path for docked-minimized sessions, (b) a keyboard shortcut (e.g. ⌘R) to refocus the selected session, (c) a toolbar button "Show selected." The `restore()` logic in `DockController` is already in place and idempotent — only the entry point needs to be wired.
- **Docked-window z-order on hub quit** — when the hub Cmd-Q's, the foreign apps regain focus and surface *their* current main window, which may be a non-docked window that was behind the hub. The docked windows are still alive and visible but end up behind whatever the foreign app brought forward. Recoverable via Cmd-Tab + cycling within the foreign app. Partial fix would be AX-raising each docked window during hub-quit so it becomes the foreign app's "main" — but each app can only have one main window, so a multi-docked-windows-per-app scenario only surfaces one. Not critical (red-button close doesn't have this issue; the foreign windows stay exactly where they were).
- **~~2-3s lag before a closed host window clears from the hub~~ — FIXED 2026-07-29 (commit `651cc67`), and the original diagnosis here was wrong.** Kept as a worked example of misdiagnosing a latency. This entry originally blamed the dangling-raise cascade (`didBecomeActive` → `raiseActiveWithoutFocus` → `raise` fails → `undock`). What actually disproved that: the user observed the sidebar's undocked indicator appearing *instantly* while the tab lingered — and those two surfaces read different state. The indicator is driven by `DockController.dockedSessionIDs` (already prompt), the tab and the row's inactive state by `status.isRunning`, and only `SessionLifecycleMonitor`'s 2s `kill(pid,0)` poll flipped status. Then measurement moved the target again: with event-driven exit detection installed, the log showed the destroy at `17:05:14` and the process exit at `17:05:19` — **a claude process outlives its host window by ~5s** (iTerm2 tears the session down, then claude does its own SIGHUP cleanup). So the poll was never the main cost and no amount of faster detection would have fixed the perceived lag. Resolution took both halves: (1) `DispatchSourceProcess` / kqueue `NOTE_EXIT` per running session so status flips the instant the pid dies, and (2) decoupling the tab from process liveness — the tab list now filters on running *and* still window-backed, since a tab whose window is gone is a broken affordance either way. Lesson: when a lag has two surfaces updating at different times, the surfaces are reading different state — find out which, before theorizing about the mechanism.

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
