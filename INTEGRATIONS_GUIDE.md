# Integrations Guide

How to add a new host integration to Claude Project Hub. A **host** is whatever app you want the hub to launch `claude` into — Terminal, iTerm2, an IDE, a third-party terminal emulator. The hub already ships integrations for 12 hosts; this guide walks through adding more.

For end-user flows see [USER_GUIDE.md](USER_GUIDE.md). For project-level context and design decisions see [CLAUDE.md](CLAUDE.md).

## The host model in one paragraph

Every host is driven by a single AppleScript file at `~/Library/Application Support/ClaudeProjectHub/scripts/<id>.applescript`, and a corresponding entry in `~/Library/Application Support/ClaudeProjectHub/hosts.json`. The hub reads the script, substitutes a known set of placeholders (the working directory, the `claude` command, etc.), runs the script via NSAppleScript, and binds the resulting host window via Accessibility so it can later focus, close, dock, and re-discover it. There is no per-host Swift code — the script does all the launching.

## Lifecycle of a launch

When the user clicks **Launch** in the New Session dialog, `ScriptedHostLauncher` runs through:

1. **Read the script** from the user's scripts directory. (Bundled scripts get copied there on first launch and never overwritten — see [USER_GUIDE.md](USER_GUIDE.md#files-on-disk).)
2. **Pre-raise the target window** if `mode == .newTab` — Swift activates the host app and AX-raises the user-picked target window before the script runs, so any `tell current window` / System Events keystrokes inside the script land on the right window. Scripts don't have to reinvent this.
3. **Snapshot existing host windows** by `CGWindowID`. This baseline is used for AX-diff window discovery if the script returns 0.
4. **Substitute placeholders** in the template (see contract below) and run via NSAppleScript.
5. **Capture the script's return value**. Positive integer = the new window's `CGWindowID`; the hub binds the AX element directly. Zero = AX-diff fallback (find the new window by comparing against the pre-launch snapshot). Errors propagate to the UI.
6. **Watch `~/.claude/sessions/<pid>.json`** for the `claude` process the script launched, capturing the conversation id once it appears.
7. **Bind the host window** via AX, register it with `DockController` if dockable, and add a tab to the hub.

The script is responsible for steps that need host-specific knowledge (how the app accepts a command). Steps 2–7 are generic and live in Swift.

## The placeholder contract

Before running, the hub substitutes these tokens in the script template. Every value is AppleScript-escaped (backslashes and double quotes), so it's safe to embed inside a quoted string literal — `"{cwd}"` works directly.

| Token | Type | Description |
| --- | --- | --- |
| `{cwd}` | path | Absolute path of the working directory (no trailing slash). |
| `{claude}` | shell command | `claude` for a new session, or `claude --resume <conversation-id>` for a resume. Use as-is in `do shell script` or `write text` contexts. |
| `{marker}` | string | A unique tag (`ClaudeProjectHub-<UUID>`) for AX-based discovery. Set it as a tab title where the host supports it. |
| `{mode}` | `"newWindow"` or `"newTab"` | The window mode the user picked. |
| `{targetWindowID}` | int | `CGWindowID` of the user-picked target window for `newTab` mode (`0` otherwise). The hub has already AX-raised this window in Swift, so you usually don't need to use this — but it's there if the script needs to reference the specific window by id. |
| `{bundleID}` | string | The host's bundle identifier from `hosts.json`. Useful for `open -b "{bundleID}" "{cwd}"` and for `first process whose bundle identifier is "{bundleID}"` lookups. |

## The return value contract

The script's last expression is its return value (AppleScript convention).

- **Positive integer** → treated as the new window's `CGWindowID`. The hub binds the AX element directly via `AXSupport.waitForWindow(matching:)`. Use this when the host's AppleScript dictionary exposes the window id (iTerm2, Terminal).
- **`0`** → AX-diff fallback. The hub compares the host's current windows against the pre-launch snapshot and picks the first one that's new. Use this when the host doesn't expose a window id (CLI-spawnable terminals like Ghostty, IDEs driven by `do shell script`).
- **`error "..."`** → the message surfaces to the user in the launch dialog. Use this for unrecoverable conditions like "no project file found" or "the IDE never reached a keystroke-ready state."

## Step-by-step: adding a host

1. **Open Settings → Hosts (⌘,)** in the running hub.
2. Click **+**, pick the app from the chooser, and give it a display name. The hub auto-slugs an id (e.g. "Ghostty" → `ghostty`) and copies `_template.applescript` to `<id>.applescript` in your user scripts dir.
3. **Right-click the new host row → Reveal Script in Finder**. Open the file in your editor of choice.
4. Replace the placeholder error at the bottom with your launch logic. See the patterns below for templates.
5. **Test by launching a session into your host** from the New Session dialog. Iterate on the script until launch, focus, close, and resume all behave correctly. No rebuild required between iterations — the script is read fresh each launch.
6. **Once it's working**, copy the finalized script into `Resources/Scripts/<id>.applescript` in the repo so it ships with the bundle, and add the host to `HostRegistry.builtinDefaults`. Bump `currentDefaultsVersion` so existing users pick it up.

## Common patterns

The bundled scripts cover three host archetypes. Pick the closest match and adapt.

### CLI-spawnable terminal (Ghostty, WezTerm, kitty, Alacritty, …)

The simplest pattern: shell out to the terminal's CLI with `--working-directory` and `-e`, then `return 0` to let the hub discover the new window via AX-diff.

```applescript
set theCwd to "{cwd}"
set theClaude to "{claude}"

do shell script "/Applications/Ghostty.app/Contents/MacOS/ghostty --working-directory=" & quoted form of theCwd & " -e " & quoted form of theClaude & " &"

return 0
```

Notes:
- The trailing `&` detaches the spawned process so `do shell script` returns immediately.
- AX-diff works because the new window is the only one that wasn't in the pre-launch snapshot.
- `newTab` mode for these hosts usually isn't supported — terminals like Ghostty don't have an AppleScript dictionary for tab-into-existing-window. Either error out, fall back to spawning a new window, or use `keystroke "t" using {command down}` after raising the target window (System Events keystrokes will land on it because Swift pre-raised it).

### Host with an AppleScript dictionary that exposes window IDs (iTerm2, Terminal)

For hosts that natively know their window's id, return it directly. The hub binds the AX element via `AXSupport.waitForWindow(matching:)` — no diff needed. From `Resources/Scripts/iterm2.applescript`:

```applescript
set theCwd to "{cwd}"
set theClaude to "{claude}"
set theMarker to "{marker}"
set theMode to "{mode}"

set runCommand to "cd " & quoted form of theCwd & " && " & theClaude

if theMode is "newWindow" then
    tell application "iTerm"
        activate
        create window with default profile
        set winID to id of current window
        tell current session of current window
            write text runCommand
            set name to theMarker
        end tell
        return winID
    end tell
else if theMode is "newTab" then
    -- Target window already AX-raised by Swift; iTerm2's "current
    -- window" is the user's pick.
    tell application "iTerm"
        activate
        tell current window
            create tab with default profile
            tell current session of current tab
                write text runCommand
                set name to theMarker
            end tell
        end tell
        set winID to id of current window
        return winID
    end tell
else
    error "Unknown mode: " & theMode
end if
```

The marker is set as the tab name as a debugging hand-hold; it's not load-bearing for binding because `winID` is the canonical CGWindowID. The shell `cd && claude` keeps the conversation in the right cwd even though `write text` doesn't take a working-directory argument.

### IDE driven by a menu walk (JetBrains)

JetBrains IDEs run on JBR (a custom Java runtime) and don't expose AppleScript dictionaries, so we drive them via System Events. They also have a few specific quirks documented in the bundled scripts and CLAUDE.md's "Lessons learned":

- **Title-based polling** to know when the project window is loaded. The IDE's startup dialogs (Open Project, Trust Project) report as `AXStandardWindow` with no `AXModal` flag, so subrole-based detection doesn't work. Instead, poll `AXFocusedWindow.title` for the cwd's basename — JetBrains puts the project name in the loaded window's title.
- **Welcome window guard**. If the cwd isn't a recognized project, the IDE shows "Welcome to <IDE>" instead of loading. Bail with a clear error rather than waiting out a timeout.
- **Menu walk via `click menu item`**. Despite the name, AppleScript's `click menu item` is an AX press action (no synthetic mouse events). To open `View → Tool Windows → Terminal`, click each level in sequence with small delays between — clicking the deeply-nested leaf alone doesn't reliably open the parent menus.
- **Don't use Option+F12** even though that's the keyboard shortcut. On Macs with default F-keys-as-media-keys mode, Option+F12 requires the user to also hold Fn. AppleScript's synthetic keystrokes don't reliably bypass that mode. Menu walk is keymap-independent.

The full pattern from `Resources/Scripts/pycharm.applescript` (paraphrased):

```applescript
set theCwd to "{cwd}"
set theClaude to "{claude}"
set theBundleID to "{bundleID}"

-- Compute cwd basename for title matching
set AppleScript's text item delimiters to "/"
set pathParts to text items of theCwd
set cwdBasename to last item of pathParts
set AppleScript's text item delimiters to ""

do shell script "open -b " & quoted form of theBundleID & " " & quoted form of theCwd

-- Wait for the IDE process to be frontmost
tell application "System Events"
    set tries to 0
    repeat while tries < 200
        try
            set ideProcess to first process whose bundle identifier is theBundleID
            if frontmost of ideProcess is true then exit repeat
        end try
        delay 0.1
        set tries to tries + 1
    end repeat
end tell

-- Wait for project-loaded state: focused window's title contains the
-- cwd basename for 4 consecutive 0.5s checks. Welcome window guard
-- bails out if the directory isn't a project.
tell application "System Events"
    set requiredStable to 4
    set requiredWelcomeStable to 6
    set stableCount to 0
    set welcomeCount to 0
    set ready to false
    set waitTries to 0
    repeat while waitTries < 240 -- 120s outer timeout
        try
            set ideProc to first process whose bundle identifier is theBundleID
            set focusedWin to value of attribute "AXFocusedWindow" of ideProc
            if focusedWin is not missing value then
                set winTitle to title of focusedWin
                if winTitle contains cwdBasename then
                    set stableCount to stableCount + 1
                    set welcomeCount to 0
                    if stableCount ≥ requiredStable then
                        set ready to true
                        exit repeat
                    end if
                else if winTitle starts with "Welcome to" then
                    set welcomeCount to welcomeCount + 1
                    if welcomeCount ≥ requiredWelcomeStable then
                        error "The IDE couldn't open '" & theCwd & "' as a project."
                    end if
                else
                    set stableCount to 0
                    set welcomeCount to 0
                end if
            end if
        end try
        delay 0.5
        set waitTries to waitTries + 1
    end repeat
    if not ready then
        error "Project window didn't load within 120 seconds."
    end if
end tell

delay 0.3 -- brief settle

-- Open Terminal tool window via menu walk
tell application "System Events"
    tell (first process whose bundle identifier is theBundleID)
        click menu bar item "View" of menu bar 1
        delay 0.15
        click menu item "Tool Windows" of menu "View" of menu bar item "View" of menu bar 1
        delay 0.15
        click menu item "Terminal" of menu "Tool Windows" of menu item "Tool Windows" of menu "View" of menu bar item "View" of menu bar 1
    end tell
    delay 4.0 -- terminal pane + shell startup
    keystroke theClaude
    delay 0.3
    key code 36 -- Return
end tell

return 0
```

A few details worth flagging:

- The 4-second delay after opening the terminal pane gives JetBrains' async shell-spawn time to be ready before keystrokes. Shorter delays send the command into a pane that has focus but no live shell yet — keystrokes get eaten.
- `click menu bar item "View"` opens the menu so the descent is visible to AX. Clicking the leaf alone fails silently on most macOS versions.
- Rider is the exception in the JetBrains lineup: its default macOS keymap is "Visual Studio macOS" (Ctrl+`) rather than the IntelliJ default (Option+F12). The Rider bundled script uses Ctrl+\` directly; the menu walk would also work and would be more keymap-independent.

## Lessons baked into the existing scripts

When writing a new integration, scan these so you don't relearn them the hard way. Most have longer entries in [CLAUDE.md](CLAUDE.md#lessons-learned-the-hard-ones).

- **Terminal.app's `make new tab/window` is non-functional.** Listed in the dictionary, throws `error -10000` at runtime. Use System Events Cmd-T / Cmd-N instead, after AX-raising the target window.
- **Window titles don't survive the shell.** Setting a tab/window title via AppleScript works briefly, but the shell's first prompt and `claude`'s startup print escape sequences that overwrite it within ~1s. Don't rely on titles for AX binding — use the host's window id when available, or AX-diff against the pre-launch snapshot.
- **JBR (JetBrains) windows need `AXMain` and `AXFocused` set before `AXRaise`.** Bare AXRaise flashes the window forward for a frame and then JBR's window manager re-asserts its own idea of which window is main. The hub already handles this in `AXSupport.raise`; you don't need to do anything in the script, but knowing this helps when debugging "why does my IDE window not come forward."
- **`AXRaise` of the user-picked window happens in Swift, not the script.** For `newTab` mode, by the time your script runs, the target window is already front. Don't reinvent it.
- **System Events synthetic keystrokes for F-keys don't bypass F-key/media-key mode.** If a host's default shortcut uses an F-key, prefer the menu-walk path; it's keymap- and mode-independent.
- **Hardened runtime requires the apple-events entitlement.** Already set in `Resources/ClaudeProjectHub.entitlements`. Without it, macOS silently denies all Apple Events from the hub and refuses to even prompt.

## Testing your integration

A new host script should pass this checklist before you ship it as a bundled default:

1. **Cold launch**: with the host app not running, launch a session via the hub. The host should open, the project should load (if applicable), `claude` should start, and the session should appear in the sidebar with status "idle" or "working."
2. **Warm launch (newWindow)**: with the host already running with another project/session, launch a fresh session. A new window should appear; the existing one should be left alone.
3. **Warm launch (newTab)**, if your host supports tabs: pick an existing session as the target. The new session should land in a tab inside that target's window.
4. **Focus**: switch away to another session in the hub, then back. The host window should come to the foreground.
5. **Close**: right-click → Close. The host window/tab should close cleanly. The session record should move to "closed" state.
6. **Resume**: right-click the closed session → Resume… The hub should re-launch with `claude --resume <conversation-id>` against the original cwd.
7. **External adoption**: with the hub closed, launch a session directly from the host (or a parent terminal). Open the hub. The session should appear in the sidebar's **Available to Dock** section. Right-click → **Adopt and Dock**.
8. **Get Info**: right-click → Get Info. The cost and token breakdown should appear. (Requires at least one message exchanged.)
9. **Idle notification**: send a message in `claude` and let it complete. The session row should pulse and a system notification should fire (if not focused).

If any of these fail, the script needs more work. Common culprits:
- Step 1 fails: usually a script syntax error or missing entitlement. Check `Console.app` for AppleScript errors.
- Step 4 fails (host stays in background): JBR raise issue, or the host's window doesn't respond to `AXRaise`. File an issue.
- Step 5 fails (window doesn't close): the hub presses the AX close button; if that's missing or non-functional on your host, you'll need a different close strategy.
- Step 7 fails (session doesn't appear in Available to Dock): the hub finds external sessions by enumerating `~/.claude/sessions/*.json`. If your host doesn't spawn a `claude` process in the standard way, this won't trigger.

## Known limitations

These are deliberate non-goals or pending work — don't try to fix them in your integration script.

- **No window reparenting.** Foreign windows stay top-level OS windows owned by their own app; the hub uses AX to position them inside the dock area. See [CLAUDE.md → Docking architecture](CLAUDE.md#docking-architecture).
- **No SkyLight private APIs.** Stay AX-only.
- **Multi-monitor edge cases** are partially supported but not rigorously tested. If your host behaves oddly across multiple displays, file an issue rather than working around it in the script.
- **Xcode is a deliberate non-goal**, not pending work. It has no integrated terminal to drive AppleScript into, so an Xcode host could only ever be a terminal host plus the side effect of opening the project — and the hub's bind path resolves windows through the host's bundle id, so such a host mis-binds Xcode's own project window instead of the terminal running `claude`. Use Terminal or iTerm2 as the host and open the project in Xcode yourself. Full reasoning in [CLAUDE.md → Out of scope](CLAUDE.md#out-of-scope).

## Contributing your integration upstream

If you've added a host that others might use, a PR is welcome. Steps:

1. Move your `<id>.applescript` from `~/Library/Application Support/ClaudeProjectHub/scripts/` into `Resources/Scripts/<id>.applescript` in the repo.
2. Add the host's `HostConfig` to `HostRegistry.builtinDefaults` in `Sources/Stores/HostRegistry.swift`. Use the bundle id you confirmed against an actual install (cheaper than guessing — `mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app` works).
3. Bump `HostRegistry.currentDefaultsVersion` so existing users pick up the new host on their next launch (their `hosts.json` is backed up to `hosts.json.backup` when this happens).
4. Run `xcodegen` so the new script gets bundled.
5. Test the full flow on a clean checkout — the bundle copy + hosts.json regeneration should give the new host appearing automatically.
6. Open a PR with a screenshot or terminal log showing the integration working.
