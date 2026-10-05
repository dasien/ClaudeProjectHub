-- Default launch script for PyCharm (Professional or Community).
--
-- All JetBrains IDEs share the same automation pattern on macOS:
-- no AppleScript dictionary, so we use `open -b` to launch the IDE
-- with a project, then send Option+F12 (the default macOS terminal
-- binding across the IntelliJ Platform) to open the integrated
-- terminal, then type the claude command.
--
-- Hub-provided substitutions used here:
--   {cwd}       absolute path of the working directory
--   {claude}    `claude` or `claude --resume <id>`
--   {bundleID}  the host's bundle id from hosts.json — same script
--               body works across IDE editions (Pro vs Community
--               etc.) since the bundle id comes from your host
--               config.
--
-- If you've remapped the terminal binding away from Option+F12,
-- change `key code 111 using {option down}` below.
set theCwd to "{cwd}"
set theClaude to "{claude}"
set theBundleID to "{bundleID}"

-- Compute the cwd's basename. The loaded JetBrains project window
-- puts the project name in the title (e.g. "MyProject – Foo.kt"),
-- which by convention matches the directory basename. The startup
-- "Open Project" / "Trust Project" dialogs don't contain it. So
-- "title contains basename" is our signal that the project window
-- (not a dialog) is in front. JetBrains' Swing dialogs report as
-- AXStandardWindow with no AXModal flag, so subrole-based detection
-- doesn't work — title matching is what we have.
set AppleScript's text item delimiters to "/"
set pathParts to text items of theCwd
set cwdBasename to last item of pathParts
if cwdBasename is "" and (count of pathParts) > 1 then
    set cwdBasename to item ((count of pathParts) - 1) of pathParts
end if
set AppleScript's text item delimiters to ""

-- Open project. `open -b` works whether the IDE is running cold
-- or warm; the IDE handles "open this folder as a project."
do shell script "open -b " & quoted form of theBundleID & " " & quoted form of theCwd

-- Wait for the IDE process to be frontmost.
tell application "System Events"
    set tries to 0
    repeat while tries < 200 -- 20s timeout
        try
            set ideProcess to first process whose bundle identifier is theBundleID
            if frontmost of ideProcess is true then exit repeat
        end try
        delay 0.1
        set tries to tries + 1
    end repeat
end tell

-- Wait for project-loaded state: focused window's title contains
-- the cwd basename for `requiredStable` consecutive checks (each
-- 0.5s apart). If a dialog is up, its title doesn't contain the
-- basename, so the counter stays at 0 and we keep waiting.
--
-- Welcome window guard: if the IDE can't open the directory as a
-- project (e.g. the folder has no recognized project file or .idea
-- subdir), it shows "Welcome to <IDE>" instead. There's no project
-- window to send Option+F12 to, so we bail with a clear error
-- rather than waiting out the 120s timeout. Stable for 3s ensures
-- we don't bail during a transient welcome-flash on cold start.
tell application "System Events"
    set requiredStable to 4 -- 2s of consecutive stability
    set requiredWelcomeStable to 6 -- 3s confirms welcome is final
    set stableCount to 0
    set welcomeCount to 0
    set waitTries to 0
    set ready to false
    repeat while waitTries < 240 -- 120s outer timeout (cold-start indexing)
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
                    set stableCount to 0
                    if welcomeCount ≥ requiredWelcomeStable then
                        error "The IDE couldn't open '" & theCwd & "' as a project. Pick a directory containing a recognized project file or .idea folder, or use Terminal/iTerm2 as the host."
                    end if
                else
                    set stableCount to 0
                    set welcomeCount to 0
                end if
            else
                set stableCount to 0
                set welcomeCount to 0
            end if
        end try
        delay 0.5
        set waitTries to waitTries + 1
    end repeat
    if not ready then
        error "The IDE didn't load the project window within 120 seconds. If a confirmation or trust dialog is open, dismiss it and try launching this session again."
    end if
end tell

-- Brief settle once stable, then open terminal and run claude.
delay 0.3

-- Open the integrated terminal via View → Tool Windows → Terminal,
-- then type claude and hit Return.
--
-- Using the menu rather than the Option+F12 keyboard shortcut: that
-- shortcut requires the user to also hold Fn on Macs where F-keys
-- are configured as media keys (the default), and AppleScript's
-- synthetic keypresses don't reliably bypass that mode. The menu
-- path is identical across all IntelliJ Platform IDEs and doesn't
-- depend on keyboard remapping. If you use a non-English IDE
-- language pack, update the menu names below.
tell application "System Events"
    tell (first process whose bundle identifier is theBundleID)
        -- Despite the name, `click menu item` invokes the AX press
        -- action — not a synthetic mouse event. We walk the menu
        -- hierarchy explicitly (View → Tool Windows → Terminal)
        -- because a single `click` on the deeply-nested leaf
        -- doesn't reliably open the parent menus first; small
        -- delays between clicks let each submenu render.
        click menu bar item "View" of menu bar 1
        delay 0.15
        click menu item "Tool Windows" of menu "View" of menu bar item "View" of menu bar 1
        delay 0.15
        click menu item "Terminal" of menu "Tool Windows" of menu item "Tool Windows" of menu "View" of menu bar item "View" of menu bar 1
    end tell
    -- Generous delay to let the terminal pane open AND its shell
    -- spawn — JetBrains starts the shell async after the pane
    -- appears, so a too-short wait sends keystrokes into a pane
    -- that has focus but no live shell yet.
    delay 4.0
    -- Keystrokes go to whatever app is frontmost. A long cold start
    -- gives the user time to switch away, so check right before
    -- typing rather than trusting the earlier wait.
    if frontmost of (first process whose bundle identifier is theBundleID) is false then
        error "The IDE lost focus before the claude command could be typed, so nothing was sent. Bring it to the front and launch the session again."
    end if
    keystroke theClaude
    delay 0.3
    key code 36 -- Return
end tell

return 0
