-- Default launch script for Rider (.NET).
--
-- Rider's default macOS keymap is "Visual Studio macOS" (matching
-- .NET tooling), not the IntelliJ-platform keymap the rest of
-- JetBrains' IDEs use. So the integrated terminal binding is
-- Ctrl+` instead of Option+F12.
--
-- Hub-provided substitutions used here:
--   {cwd}       absolute path of the working directory
--   {claude}    `claude` or `claude --resume <id>`
--   {bundleID}  the host's bundle id from hosts.json
--
-- If you've remapped the terminal binding in Preferences → Keymap,
-- change the `key code 50 using {control down}` line below.

set theCwd to "{cwd}"
set theClaude to "{claude}"
set theBundleID to "{bundleID}"

-- Compute the cwd's basename. Rider's loaded project window puts
-- the project name in the title (e.g. "AchievementService – Foo.cs"),
-- which by convention matches the directory basename. The "Select a
-- Solution to Open" dialog and other startup dialogs do not. So
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

-- Open project. This may trigger a confirmation dialog (e.g. "Select
-- a Solution to Open" when Rider already has a project open, or
-- "Trust this project?" on first open of an unfamiliar folder). The
-- polling block below waits for the project window to be focused
-- before we send Ctrl+`.
do shell script "open -b " & quoted form of theBundleID & " " & quoted form of theCwd

-- Wait for Rider's process to be frontmost.
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
-- Welcome window guard: if Rider can't open the directory as a
-- project (e.g. the user picked a folder with no .sln/.csproj/.idea),
-- it shows "Welcome to JetBrains Rider" instead. There's no project
-- window to send Ctrl+` to, so we bail with a clear error rather
-- than waiting out the 120s timeout. Stable for 3s ensures we don't
-- bail during a transient welcome-flash on cold start.
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
                        error "Rider couldn't open '" & theCwd & "' as a project. Pick a directory containing a .sln/.csproj or .idea folder, or use Terminal/iTerm2 as the host."
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
        error "Rider didn't load the project window within 120 seconds. If a confirmation or trust dialog is open, dismiss it and try launching this session again."
    end if
end tell

-- Brief settle once stable, then open terminal and run claude.
delay 0.3

-- Open integrated terminal (Ctrl+`), type claude, hit Return.
-- Long delays between keystrokes guard against the shell not yet
-- being ready inside the freshly-opened terminal.
tell application "System Events"
    key code 50 using {control down}
    delay 1.5
    keystroke theClaude
    delay 0.3
    key code 36 -- Return
end tell

return 0
