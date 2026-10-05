-- Default launch script for iTerm2 (com.googlecode.iterm2).
--
-- See terminal-app.applescript for the placeholder contract.
--
-- iTerm2's `id of current window` IS the CGWindowID, so we return it
-- directly and the hub binds the AX window via `AXSupport.waitForWindow`.

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
    -- iTerm2's AppleScript dictionary properly supports `create window`,
    -- so cold and warm start share the same flow.
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
    -- Target window already raised by Swift via AX, so iTerm2's
    -- "current window" is the user's pick. We grab winID outside the
    -- `tell current window` block — inside it, `current window` would
    -- resolve against the window object instead of the app, which iTerm
    -- rejects with "Can't get current window of current window".
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
