# User Guide

Day-to-day flows in Claude Project Hub. For installation see the [README](README.md). For adding a brand new host integration see the [INTEGRATIONS_GUIDE](INTEGRATIONS_GUIDE.md).

## Permissions on first launch

Two macOS permissions are required:

1. **Accessibility** — used to focus, close, and position host windows. The hub prompts on first launch (System Settings → Privacy & Security → Accessibility). Toggle the hub on.
2. **Automation / Apple Events** — used to drive each host via AppleScript. macOS prompts the first time the hub targets a given host (e.g. the first launch into iTerm2 triggers a "Claude Project Hub wants to control iTerm2" prompt). Approve once per host.

If a permission seems stuck after granting, quit and relaunch the hub — TCC sometimes only re-evaluates trust on process start.

## Hub layout

Two-pane window:

- **Left sidebar**: every session the hub is tracking — running or closed — plus an **Available to Dock** section listing any `claude` processes running on your machine that the hub didn't launch.
- **Main area**: a tab per running session. The active session's host window is brought forward and (if dockable) repositioned to overlap the tab area.

Click a sidebar row or a tab to make that session active. ⌘1 through ⌘9 jump to the corresponding tab.

## Sessions

### Create a new session

Click **+** in the toolbar to open the New Session dialog:

| Field | What it does |
| --- | --- |
| Name | Optional label shown in sidebar/tabs. Defaults to the directory's basename. |
| Directory | The cwd `claude` will run in. Use **Browse…** to pick a folder. |
| Host | Terminal/IDE that'll launch the session. Only apps you have installed are listed. |
| Open in | New Window, or New Tab in… (only available when the host is already running and supports tabs). |

**Launch** runs the host's `.applescript` against your inputs, watches `~/.claude/sessions/<pid>.json` to capture the conversation id, and binds the resulting host window via Accessibility so the hub can focus / close / dock it later.

### Adopt an external session

Any `claude` running on your machine — including one started directly from a terminal — appears in the sidebar's **Available to Dock** section. Right-click the row → **Adopt and Dock** to bring it under the hub's management. From that point it behaves like a session you launched yourself.

### Focus a session

Click its sidebar row or its tab. The host window comes forward and, if applicable, snaps into the dock area.

### Close a session

Right-click a running session → **Close**. The hub presses the host window's close button (which usually ends the `claude` process). The session record stays around in a "closed" state so you can resume it later.

### Rename a session

Right-click → **Rename…**. Affects only the displayed label; doesn't touch the underlying conversation.

### Resume a closed session

Right-click → **Resume…**. The dialog asks where to open it (host + window mode). The hub runs `claude --resume <conversation-id>` against the original cwd.

A session that was opened and closed without ever exchanging a message can't be resumed — Claude doesn't write the JSONL transcript until the first turn. The hub surfaces a friendly error when you try; just create a new session instead.

### Remove from the list

Right-click a closed session → **Remove from List**. Stops tracking the session in the hub. Doesn't delete the JSONL transcript on disk.

### Right-click reference

| Session state | Menu items |
| --- | --- |
| Running (idle / working) | Show, Dock (if not already docked), Rename…, Close, Get Info |
| Closed | Resume…, Rename…, Remove from List, Get Info |
| External (Available to Dock) | Adopt and Dock |

## Tabs and docking

When the active session has a dockable host window, the hub repositions that window to overlap the tab area. From the user's perspective the host window appears to live inside the hub.

- ⌘1 — ⌘9 jump to the corresponding tab.
- Drag a docked window's title bar more than ~30px out of the dock area to undock it. The host window becomes free-floating again.
- Right-click a tab → **Undock** does the same thing deliberately.
- A session that started in a tab can be re-docked: right-click it in the sidebar → **Dock**.

Some hosts share one window across multiple sessions (iTerm2 tabs, Terminal tabs). For those, switching sessions in the hub also tells the host to switch its internal tab.

## Get Info — cost & token usage

Right-click any session → **Get Info** opens a popout with:

- Total estimated cost (USD)
- Per-model token breakdown (input, output, cache reads, cache writes)
- The conversation id and project directory, each with a **Show in Finder** button

Pricing comes from `~/Library/Application Support/ClaudeProjectHub/models.json` (copied from the bundle on first launch). Edit the JSON to override any pattern's per-1M-token rates — costs recompute the next time you open Get Info.

If a session was opened but no message was ever exchanged, Get Info shows a "no transcript yet" alert (same as the Resume case).

## Idle notifications

When a session transitions from **working** → **idle** — i.e. Claude is sitting waiting on you — the hub:

- Pulses a red attention badge on the session's sidebar row
- If the hub isn't the frontmost app, posts a macOS notification with the session's name. Clicking the notification focuses that session.

The hub asks for **Notifications** permission the first time a session would notify; grant it once.

Toggle the whole thing in **Settings → General → Notify when a session goes idle**.

## Settings (⌘,)

### General tab

- **Appearance** — Light / Dark / System
- **Notify when a session goes idle** — on/off

### Hosts tab

The list of hosts available in the New Session picker, backed by `~/Library/Application Support/ClaudeProjectHub/hosts.json`.

| Column | What it is |
| --- | --- |
| Display name | Shown in the picker |
| Bundle id | Used for `open -b` and AX lookup |
| Launch script | Filename in `~/Library/Application Support/ClaudeProjectHub/scripts/` |

Toolbar:

- **+** — Add a host. Pick an app via the chooser, give it a display name. The hub auto-slugs an id and copies `_template.applescript` to `<id>.applescript` so you have something to edit.
- **Edit** (or double-click a row) — Modify a host's metadata.
- **−** — Remove a host. The script file is left in place; delete it manually if you want.
- Right-click a row for **Reveal Script in Finder**.

### Adding a CLI-spawnable terminal (Ghostty / WezTerm / kitty / etc.)

These don't need any Swift code — only an AppleScript:

1. **Settings → Hosts → +**, pick the app
2. Open the generated script (right-click the new host row → Reveal Script in Finder)
3. Replace the body with a `do shell script` invocation of the app's CLI, substituting `{cwd}` and `{claude}`. For example, Ghostty:

   ```applescript
   set theCwd to "{cwd}"
   set theClaude to "{claude}"
   do shell script "/Applications/Ghostty.app/Contents/MacOS/ghostty --working-directory=" & quoted form of theCwd & " -e " & quoted form of theClaude & " &"
   return 0
   ```

   The trailing `return 0` lets the hub fall back to AX-window-diff to find the new window. See the [INTEGRATIONS_GUIDE](INTEGRATIONS_GUIDE.md) for the full placeholder contract.

4. Try **+** in the toolbar and pick your new host. If the launch fails, edit the script and try again — no rebuild required.

## Files on disk

The hub stores everything user-facing under `~/Library/Application Support/ClaudeProjectHub/`:

```
~/Library/Application Support/ClaudeProjectHub/
├── sessions.json        Persistent session records
├── hosts.json           Host registry (display name, bundle id, launch script per host)
├── hosts.json.backup    Previous version, written when the hub bumps its built-in defaults
├── scripts/             Per-host .applescript files (user-editable; never overwritten)
└── models.json          Claude model pricing for cost calculation (user-editable)
```

All plain JSON / AppleScript. Edit by hand or let the in-app UI manage them — both paths read/write the same files.

When a hub update bumps its built-in defaults version, your existing `hosts.json` is copied to `hosts.json.backup` and the file regenerated from the new defaults. Custom hosts you'd added survive in the backup; paste them into the new `hosts.json` (or recreate them via Settings) to keep them.

## Common quirks

### "Permission denied" at session launch

System Settings → Privacy & Security → Automation. Find **Claude Project Hub** in the list and make sure the host you're launching is checked. If you don't see the entry yet, the hub hasn't asked for that host yet — try launching once to trigger the prompt.

### Host window doesn't come to the foreground when I click its session

Some apps need a moment to settle after the hub asks them to come forward. Click the row a second time as a quick fix. JetBrains IDEs in particular run on JBR (a custom Java runtime) and need extra AX hints — the hub already does this, but if a window is consistently stuck, file an issue with the host name and version.

### Multiple iTerm2 sessions all show the same window

iTerm2 returns the same `CGWindowID` for every tab in a window. The hub identifies each session by its controlling tty and switches the host's internal tab via AppleScript when you switch sessions in the hub. If the wrong tab activates, file an issue with the tabs' contents and order.

### A bundled launch script update didn't take effect

User scripts in `~/Library/Application Support/ClaudeProjectHub/scripts/` are never automatically overwritten — once a file is in your scripts directory, it stays. To pick up an updated bundled script:

```
rm ~/Library/Application\ Support/ClaudeProjectHub/scripts/<name>.applescript
```

Then relaunch the hub; it'll re-copy from the bundle. (A future version will detect "user hasn't customized this" via SHA hash and update transparently in that case.)
