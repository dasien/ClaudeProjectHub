-- Default launch script for Terminal.app (com.apple.Terminal).
--
-- Hub provides these substitutions before running:
--   {cwd}            absolute path of the working directory
--   {claude}         shell command: `claude` or `claude --resume <id>`
--   {marker}         unique tag used as the tab's custom title
--   {mode}           "newWindow" or "newTab"
--   {targetWindowID} CGWindowID of the user-picked target window for newTab
--                    mode (0 otherwise). Hub has already AX-raised this
--                    window in Swift before this script runs, so System
--                    Events keystrokes below land on it.
--
-- Returns: integer CGWindowID of the new tab's window for AX binding,
-- or 0 to let the hub fall back to AX diff.

set theCwd to "{cwd}"
set theClaude to "{claude}"
set theMarker to "{marker}"
set theMode to "{mode}"

-- `&& exit` closes the tab with claude: the hub drops a session the
-- moment claude ends, so a leftover shell tab just drifts out of step
-- with it. Only a clean exit closes it — if claude crashes or the cd
-- fails, the shell stays open with the error visible.
set runCommand to "cd " & quoted form of theCwd & " && " & theClaude & " && exit"

if theMode is "newWindow" then
    if application "Terminal" is running then
        -- warm start: Terminal's `make new window` is non-functional, so
        -- send Cmd-N via System Events. Snapshot existing windows first so
        -- we can identify the new one by diff.
        tell application "Terminal" to activate
        tell application "System Events"
            set frontTries to 0
            repeat while (frontmost of process "Terminal") is false and frontTries < 40
                delay 0.05
                set frontTries to frontTries + 1
            end repeat
        end tell
        set initialIDs to {}
        tell application "Terminal"
            repeat with w in windows
                copy id of w to end of initialIDs
            end repeat
        end tell
        tell application "System Events"
            keystroke "n" using {command down}
        end tell
        set foundWindowID to 0
        set tries to 0
        repeat while foundWindowID is 0 and tries < 40
            delay 0.05
            set tries to tries + 1
            tell application "Terminal"
                repeat with w in windows
                    set wID to id of w
                    set wasKnown to false
                    repeat with kID in initialIDs
                        if (contents of kID) is wID then
                            set wasKnown to true
                            exit repeat
                        end if
                    end repeat
                    if wasKnown is false then
                        set foundWindowID to wID
                        exit repeat
                    end if
                end repeat
            end tell
        end repeat
        if foundWindowID is 0 then
            error "Could not detect a new Terminal window after Cmd-N. Check Terminal's keyboard shortcuts."
        end if
        tell application "Terminal"
            set foundWindow to (first window whose id is foundWindowID)
            set newTab to do script runCommand in (selected tab of foundWindow)
            set custom title of newTab to theMarker
        end tell
        return foundWindowID
    else
        -- cold start: `do script` will launch Terminal and create one
        -- window for our command. Run inside the startup window's existing
        -- tab so we don't end up with two windows.
        tell application "Terminal"
            activate
            set tries to 0
            repeat while (count of windows) = 0 and tries < 40
                delay 0.05
                set tries to tries + 1
            end repeat
            if (count of windows) > 0 then
                set newTab to do script runCommand in (selected tab of window 1)
            else
                set newTab to do script runCommand
            end if
            set custom title of newTab to theMarker
            return id of (first window whose tabs contains newTab)
        end tell
    end if

else if theMode is "newTab" then
    -- Target window already raised by Swift via AX. Send Cmd-T to add a
    -- new tab to the (now front) target window. We diff windows by tab
    -- count to find which window grew.
    tell application "Terminal" to activate
    tell application "System Events"
        set frontTries to 0
        repeat while (frontmost of process "Terminal") is false and frontTries < 40
            delay 0.05
            set frontTries to frontTries + 1
        end repeat
    end tell
    set initialMap to {}
    tell application "Terminal"
        repeat with w in windows
            copy {id of w, count of tabs of w} to end of initialMap
        end repeat
    end tell
    tell application "System Events"
        keystroke "t" using {command down}
    end tell
    set foundWindowID to 0
    set tries to 0
    repeat while foundWindowID is 0 and tries < 40
        delay 0.05
        set tries to tries + 1
        tell application "Terminal"
            repeat with w in windows
                set wID to id of w
                set currentTabs to count of tabs of w
                set wasKnown to false
                set initialTabs to 0
                repeat with j from 1 to count of initialMap
                    set entry to item j of initialMap
                    if (item 1 of entry) is wID then
                        set wasKnown to true
                        set initialTabs to (item 2 of entry)
                        exit repeat
                    end if
                end repeat
                if wasKnown is false and currentTabs > 0 then
                    set foundWindowID to wID
                    exit repeat
                else if wasKnown and currentTabs > initialTabs then
                    set foundWindowID to wID
                    exit repeat
                end if
            end repeat
        end tell
    end repeat
    if foundWindowID is 0 then
        error "Could not detect a new tab after Cmd-T. Check Terminal's keyboard shortcuts."
    end if
    tell application "Terminal"
        set foundWindow to (first window whose id is foundWindowID)
        set newTab to do script runCommand in (selected tab of foundWindow)
        set custom title of newTab to theMarker
    end tell
    return foundWindowID

else
    error "Unknown mode: " & theMode
end if
