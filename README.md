# Claude Project Hub

<p align="center">
  <img src="logos/export/iteration-8-1024x512.png" alt="Claude Project Hub" width="520">
</p>

A native macOS app that gives you one place to manage Claude Code sessions across whichever terminal or IDE launches them. Discover, focus, close, and resume sessions — without reinventing the terminal.

## Why

Claude sessions can be from a variety of hosts.  Tracking these sessions and identifying when the Claude is waiting for the user to provide input, is a growing issue.  The project hub solves this by allowing the user to create new sessions or 'adopt' existing ones into a single place.

## Features

- **Unified session list** across every supported terminal and IDE
- **Launch / Focus / Close / Resume** sessions from one place; status detection (idle / working / closed) reads from `~/.claude/sessions/<pid>.json` directly
- **Tab docking** — pin foreign host windows into the hub's tab area so multiple sessions live in one window with native-feeling tabs
- **Idle session notifications** when a session transitions from working → idle and the hub isn't already focused the user receives a system notification that Claude is waiting
- **Reattach on restart** — sessions whose underlying `claude` PID is still alive are re-bound and re-docked when the hub launches
- **External session adoption** — any `claude` running on the machine, including ones launched outside the hub, appears in the sidebar and can be docked
- **Resume past conversations** — closed conversations the hub never launched are discovered from `~/.claude/projects/` and listed under "Available to Resume"; pick a host and the hub runs `claude --resume` for you. Entries you'll never revisit can be hidden individually or per-project
- **Per-session cost + token breakdown** via right-click → Get Info; pricing comes from a user-editable `models.json`
- **Sessions Dashboard** (⌘⇧D) — one table of every session on the machine, hub-tracked or not, with cost and token totals
- **Survives the messy cases** — sleep/wake, monitor plug/unplug, and closing the lid in clamshell mode all re-pin docked windows instead of losing them. If you resume a conversation yourself in a terminal, the hub notices and adopts it
- **Stays in sync with you** — bring a docked host window to the front yourself (click it, ⌘-tab, Mission Control) and the hub's selection follows, without stealing focus back
- **Keyboard**: ⌘⇧F focuses the selected session's window, ⌘1–9 switch tabs, ⌘⇧D opens the dashboard, ⌘, opens Settings

## Supported hosts

Pre-configured. The New Session picker filters to whichever of these you actually have installed:

- **Terminal.app**
- **iTerm2**
- **JetBrains IDEs**: IntelliJ IDEA, PyCharm, WebStorm, PhpStorm, RubyMine, CLion, GoLand, Rider, Android Studio
- **Visual Studio Code** — one caveat: on the **first** launch into a folder VSCode hasn't seen before, it shows its "Do you trust the authors of the files in this folder?" prompt. That prompt is drawn *inside* the window rather than as a separate one, so the hub can't tell it apart from a loaded workspace and its keystrokes land on the dialog instead of a terminal. If a VSCode session launch appears to do nothing, accept the trust prompt in VSCode and launch the session again. Subsequent launches into that folder work normally. See [Common quirks](USER_GUIDE.md#common-quirks).

Adding a host the hub doesn't ship with (Ghostty, WezTerm, kitty, …) is a no-code change — see [Adding a host](#adding-a-host) below.

## Development Requirements

- macOS 14+ (developed against macOS 26)
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build

```bash
git clone git@github.com:dasien/ClaudeProjectHub.git
cd ClaudeProjectHub
brew install xcodegen                          # one-time
cp signing.xcconfig.example signing.xcconfig   # one-time per checkout
$EDITOR signing.xcconfig                       # fill in your DEVELOPMENT_TEAM
xcodegen                                       # regenerate .xcodeproj from project.yml
open ClaudeProjectHub.xcodeproj
```

`signing.xcconfig` is per-developer and gitignored. Your Team ID is in **Xcode → Settings → Accounts → your Apple ID → the "Team ID" column**, or from the command line as the `OU` field of your certificate:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
# subject=UID=…, CN=Apple Development: you@example.com (AAAAAAAAAA), OU=BBBBBBBBBB, …
#                                                                      ^^^^^^^^^^ Team ID
```

> **Don't use the parenthesised string from `security find-identity`.** On an *Apple Development* certificate that's a certificate identifier, not the Team ID, and building with it fails with `No Account for Team "…"`. It only happens to be the Team ID on a *Developer ID Application* certificate, which is what makes this an easy mistake.

Two things that will bite you if you do these out of order:

- **`xcodegen` fails outright if `signing.xcconfig` doesn't exist** (`invalid config file path`), so copy the example before generating — as in the commands above.
- **Fill in the real team ID *before* running `xcodegen`, or run it again afterwards.** `xcodegen` bakes `DEVELOPMENT_TEAM` into the generated `.xcodeproj`, so if you generate while the file still says `YOUR_TEAM_ID`, Xcode keeps failing with *"No Account for Team"* even after you fix the xcconfig. Re-run `xcodegen`, then close and reopen the project so Xcode rereads it.

Use a real team rather than ad-hoc signing (`-`): TCC ties Accessibility and Automation grants to the code signature, so ad-hoc builds get re-signed each time and lose their permissions on every rebuild.

Run the project from Xcode. The first launch prompts for **Accessibility** access; the first time each host (Terminal, iTerm2, …) is targeted, macOS will also prompt for **Automation/Apple Events** access for that specific app. Both prompts are necessary for the hub to bind, focus, and close host windows.

`.xcodeproj/` is gitignored — it's regenerated from `project.yml`. Re-run `xcodegen` whenever you add or remove files in `Sources/`.

## Project layout

```
Sources/
├── App/                  @main app + scenes + environment objects
├── Models/               Session, HostConfig, SessionStatus, WindowMode,
│                         DockState, HistoricalSession, ModelPricing,
│                         SessionUsage, ...
├── Stores/               SessionStore (persistence), HostRegistry,
│                         DismissedHistoricalStore (hidden resume entries)
├── Services/             AXSupport, AXObserver, AXWriteTracker,
│                         AppleScriptRunner, ClaudeSessionFile,
│                         ClaudeSessionTranscript, ModelPricingRegistry,
│                         SessionLauncherService, SessionLifecycleMonitor,
│                         WindowManager, DockController, HostWindowResolver,
│                         HostTabSelector, ExternalSessionScanner,
│                         HistoricalSessionScanner, AttentionService,
│                         SessionCatalog, HubMouseGate, ProcessTree, ...
├── Launchers/            ScriptedHostLauncher (single launcher; every
│                         host's behavior lives in its .applescript)
└── UI/                   SwiftUI views — sidebar, tabs, dialogs, settings,
                          per-session info, sessions dashboard, host editor
Resources/
├── Info.plist            (generated by xcodegen)
├── ClaudeProjectHub.entitlements
├── models.json           Claude pricing data (per-1M-token rates)
├── Scripts/              Bundled .applescript launch scripts (one per host)
└── Assets.xcassets/      App icon
logos/                    Brand assets — SVG sources, exported PNGs, export script
project.yml               xcodegen config (source of truth for the .xcodeproj)
```

## Adding a host

Each host is driven by an AppleScript file. The hub substitutes a known set of placeholders (`{cwd}`, `{claude}`, `{bundleID}`, `{marker}`, `{mode}`, `{targetWindowID}`) into the script before running it.

The fast path:

1. Open **Settings → Hosts** (⌘,) → **+** to add a host
2. Pick the app, enter a display name. The hub auto-slugs an id and copies `_template.applescript` into `~/Library/Application Support/ClaudeProjectHub/scripts/<your-id>.applescript`
3. Edit the script to fit how your host accepts a command. The bundled scripts in `Resources/Scripts/` cover the common patterns: CLI-spawnable terminals, IDEs driven by a keyboard shortcut, IDEs driven by a menu walk

The full integration walkthrough — placeholder contract, return-value contract, AX-diff fallback for window discovery, and the lessons baked into the existing scripts — is in [`INTEGRATIONS_GUIDE.md`](INTEGRATIONS_GUIDE.md).

## Docs

- [`USER_GUIDE.md`](USER_GUIDE.md) — end-user flows: permissions, session lifecycle, docking, Get Info, notifications, Settings, where files live on disk, known quirks
- [`INTEGRATIONS_GUIDE.md`](INTEGRATIONS_GUIDE.md) — adding a host: the placeholder + return-value contracts, three worked patterns, testing checklist
- [`CLAUDE.md`](CLAUDE.md) — architecture, design decisions, hard-won gotchas, milestone state

## Contributing

Read [`CLAUDE.md`](CLAUDE.md) first — it captures the design decisions, the gotchas we've already hit, and the current milestone state. Claude Code auto-loads that file when you open a session in this repo, so your AI collaborator will have the same context you do.

Its "Lessons learned" section is worth reading before touching the AX layer specifically — several non-obvious behaviours (spurious destroy notifications during sleep/wake, CGWindowIDs changing across wake, the AX server transiently returning an application element where a window is expected) cost real debugging time to pin down and are documented so they don't have to be rediscovered.

## License

To be decided.
