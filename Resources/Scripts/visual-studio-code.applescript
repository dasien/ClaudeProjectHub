-- Default launch script for Visual Studio Code.
--
-- VSCode is Electron and exposes **no AppleScript dictionary at all**
-- (`sdef` returns error -192), so unlike iTerm2/Terminal there's no
-- `windows` collection to query and no window `id` to return. This
-- script therefore returns 0 and lets the hub identify the new window by
-- diffing VSCode's AX window list before/after the launch.
--
-- That has a consequence worth understanding: the diff only finds a
-- window that *wasn't there before*, so we must force a new one.
-- `open -b <bundleID> <dir>` would reuse an existing window when the
-- same folder is already open, leaving the diff nothing to find and the
-- launch failing with "timed out finding host window". Hence the
-- bundled `code` CLI with `--new-window`.
--
-- Hub-provided substitutions used here:
--   {cwd}       absolute path of the working directory
--   {claude}    `claude` or `claude --resume <id>`
--   {bundleID}  the host's bundle id from hosts.json
--
-- {marker} is unused — VSCode gives us no way to set a window title, so
-- marker-in-title discovery isn't available for this host. {mode} and
-- {targetWindowID} are unused too: `HostConfig.supportsNewTab` is false
-- for this script, so the hub only ever asks for a new window.
--
-- Known limitation — workspace trust. On the first open of an unfamiliar
-- folder VSCode shows "Do you trust the authors of the files in this
-- folder?" as a modal *inside* the window rather than a separate window,
-- so the window title already contains the folder name and the readiness
-- check below can't distinguish it from a loaded workspace. The
-- keystrokes would then land on the dialog instead of a terminal. If a
-- session launch does nothing, accept the trust prompt in VSCode and
-- launch the session again.
--
-- If you've remapped "Terminal: Create New Terminal" from its default
-- Ctrl+Shift+` , change the `key code 50 using {control down, shift down}`
-- line near the bottom.

set theCwd to "{cwd}"
set theClaude to "{claude}"
set theBundleID to "{bundleID}"

-- Compute the cwd's basename. VSCode's default window title is
-- "<activeEditor> — <rootName> — Visual Studio Code", and with no file
-- open it's just "<rootName> — Visual Studio Code", where rootName is
-- the folder basename. So "title contains basename" is our signal that
-- the workspace has actually loaded, rather than an empty startup window.
set AppleScript's text item delimiters to "/"
set pathParts to text items of theCwd
set cwdBasename to last item of pathParts
if cwdBasename is "" and (count of pathParts) > 1 then
    set cwdBasename to item ((count of pathParts) - 1) of pathParts
end if
set AppleScript's text item delimiters to ""

-- Locate the CLI inside the app bundle rather than assuming `code` is on
-- PATH — `do shell script` runs with a minimal PATH, and the "Install
-- 'code' command in PATH" step is optional and often skipped.
-- Resolved from the bundle id so it works wherever the app is installed.
try
    set appPath to POSIX path of (path to application id theBundleID)
on error
    error "Couldn't locate the application for bundle id " & theBundleID & ". Is Visual Studio Code installed?"
end try
set codeCLI to appPath & "Contents/Resources/app/bin/code"

do shell script quoted form of codeCLI & " --new-window " & quoted form of theCwd

-- Wait for VSCode's process to come frontmost.
tell application "System Events"
    set tries to 0
    repeat while tries < 200 -- 20s timeout
        try
            set codeProcess to first process whose bundle identifier is theBundleID
            if frontmost of codeProcess is true then exit repeat
        end try
        delay 0.1
        set tries to tries + 1
    end repeat
end tell

-- Wait for the workspace to load: focused window's title contains the
-- cwd basename for `requiredStable` consecutive checks. A cold start
-- shows an untitled or "Visual Studio Code"-only window first, which
-- keeps the counter at 0 until the folder is actually open.
tell application "System Events"
    set requiredStable to 3 -- 1.5s of consecutive stability
    set stableCount to 0
    set waitTries to 0
    set ready to false
    repeat while waitTries < 120 -- 60s outer timeout (cold start)
        try
            set codeProc to first process whose bundle identifier is theBundleID
            set focusedWin to value of attribute "AXFocusedWindow" of codeProc
            if focusedWin is not missing value then
                set winTitle to title of focusedWin
                if winTitle contains cwdBasename then
                    set stableCount to stableCount + 1
                    if stableCount ≥ requiredStable then
                        set ready to true
                        exit repeat
                    end if
                else
                    set stableCount to 0
                end if
            else
                set stableCount to 0
            end if
        end try
        delay 0.5
        set waitTries to waitTries + 1
    end repeat
    if not ready then
        error "VSCode didn't open '" & theCwd & "' within 60 seconds. If a dialog is open (workspace trust, folder picker), dismiss it and launch this session again."
    end if
end tell

-- Brief settle once the title is stable, then open a terminal and run
-- claude.
delay 0.3

-- Ctrl+Shift+` is "Terminal: Create New Terminal". Deliberately *not*
-- Ctrl+` ("Toggle Terminal"), which would surface whichever terminal
-- already exists in this window — possibly one with a shell already
-- busy, and typing into it would inject the claude command into
-- someone else's session. Creating a new terminal is always safe.
tell application "System Events"
    key code 50 using {control down, shift down}
    delay 1.5
    keystroke theClaude
    delay 0.3
    key code 36 -- Return
end tell

-- 0 = let the hub identify the window via AX diff. VSCode exposes no
-- window id to return.
return 0
