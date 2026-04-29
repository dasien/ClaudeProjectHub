# Docking — design and implementation plan

The hub's central value prop. Every other feature (sidebar, session
management, host abstraction) is supporting cast for the experience of
having all your active claude sessions in one place, switchable from a
single window.

This document is the working plan for docking. Update it as the design
evolves; CLAUDE.md links here.

---

## Mechanics: what "docking" means on macOS

We can't reparent foreign windows — that requires SkyLight private APIs
we deliberately avoid. So the foreign window (Terminal, iTerm2, VSCode,
…) stays a top-level OS window owned by its own app. We use AX to pin
its frame to a rectangle the hub designates as the "dock area." When
the hub moves or resizes, we observe `kAXMovedNotification` /
`kAXResizedNotification` on our own window and `setFrame` each docked
foreign window to follow.

The user perceives docking; technically the foreign window is just
glued to the right rectangle. Same model every macOS window manager
uses (Magnet, Rectangle, Yabai, AeroSpace).

What we get for free from this model:
- No reparenting → no risk of windows getting orphaned or rendering
  incorrectly
- AX is public API → stable across macOS versions (relative to private
  APIs)
- Foreign apps keep their own focus, keyboard handling, scroll, etc.
- Undocking is just "stop tracking and let it free-float"

What we don't get:
- Foreign window pixels can't be composited inside our SwiftUI view
  hierarchy. The dock area in the hub is a placeholder; the actual
  pixels overlay it from a different window.
- We can't make foreign windows "scroll with the hub" or otherwise
  treat them like child views.
- Z-order: docked windows sit above the hub at their nailed positions.
  We can't make the hub's UI render above a docked window without
  manipulating window levels (private/messy).

---

## UX scenarios

### What macOS allows (and what it doesn't)

- ✅ **Drag from our UI** — sidebar row, tab, anywhere in the hub.
  SwiftUI's `onDrag` / `onDrop` handle this normally because both
  endpoints are our process.
- ✅ **Click in our UI to dock/undock/switch** — also our process.
- ✅ **Detect when the user drags a docked foreign window's titlebar**
  via AX position-changed events. We can re-snap (sticky) or release
  (Magnet-style) on threshold.
- ❌ **Drag a foreign window onto the hub.** macOS doesn't expose a
  drag source for foreign windows. The closest workaround is polling
  AX position during user drag and snapping on proximity — fragile and
  weird, deferred.

### Scenarios

#### 1. Spawn-into-dock

A new session launched via the hub flow:
1. ScriptedHostLauncher launches the host, AX-binds the new window.
2. Hub immediately positions the bound window into the next available
   tab slot in the dock area.
3. Tab appears in the hub's tab bar; clicking it raises that window.

This is the "always-docked" path for new sessions and the simplest
case. Should work out of the gate.

#### 2. Adopt-from-list (foreign-window discovery)

There's an external claude session running that the hub didn't launch
(e.g., the user started one from a regular Terminal):
1. `ClaudeSessionFile` enumerates `~/.claude/sessions/*.json` to find
   running claudes.
2. Hub shows them in a sidebar section "Available to dock" (separate
   from hub-owned sessions).
3. User clicks "Adopt and dock" → hub uses pid → AX → finds the host
   app's window → binds → docks into next tab slot.

Most reliable adoption path. Doesn't depend on drag-and-drop.

#### 3. Drag-from-sidebar to tab area

For sessions in the sidebar that aren't yet docked:
1. SwiftUI `onDrag` on the session row carries a session id payload.
2. SwiftUI `onDrop` on the dock area accepts that payload.
3. On drop, hub AX-positions the session's bound window into the tab
   slot at drop location.

Optional convenience over click-to-adopt; nice UX touch but not v1
critical.

#### 4. Drag-tab-out to undock

For docked sessions:
1. SwiftUI `onDrag` on the tab carries the session id.
2. Drag-out outside the hub's window → `onDragEnd` (or absence of
   `onDrop`) signals release.
3. Hub stops tracking that window's position. We can either:
   - Set the window to a sensible free-floating position near where
     the user released
   - Leave it at its current docked position and just let it move
     freely

Equivalent to Chrome's "tear off a tab into a window."

#### 5. Drag the foreign window's titlebar to undock

For docked sessions, when the user drags the actual foreign window:
1. AXObserver on the docked window fires `kAXMovedNotification`.
2. We check `userInitiated` flag — was this our `setFrame` or a real
   user drag?
3. If user drag and the new position is sufficiently far from the
   docked rect, undock (release tracking).
4. If close, snap back into place.

Magnet/Rectangle pattern. Threshold is probably 10–20 px from the
docked rect.

#### 6. Tab switching

For docked sessions, only the active tab's window should be visible:
1. Click a tab → raise that AX window via `kAXRaiseAction`.
2. The other docked windows are positioned in the same dock rect
   (overlapping). Raising one brings it on top.
3. Tab indicators in the hub UI show which is active.

We don't actually hide/show windows — they all sit in the same rect
and macOS Z-order handles which one is visible.

Open question: what if the user has Mission Control / All Windows
spread? They'll see all docked windows stacked. Acceptable.

#### 7. Hub move/resize → docked windows follow

When the user drags or resizes the hub:
1. AXObserver on hub's NSWindow fires `kAXMovedNotification` /
   `kAXResizedNotification`.
2. Recompute dock rect from hub's new frame.
3. `setFrame` each docked window to match.

The `userInitiated` flag matters here. When we `setFrame` a docked
window, AX fires its own moved/resized notification. Without the
flag, we'd cascade. We track our own writes within a short window
(~200ms) and ignore matching events.

#### 8. Foreign window dies mid-dock

The foreign app crashes or the user closes the window:
1. AXObserver fires `kAXUIElementDestroyedNotification`.
2. Hub unbinds the session, removes the tab.
3. Session moves to "closed" state in the sidebar (existing behavior).

Already handled by the lifecycle monitor for PID exit; AX destruction
is the more direct signal.

---

## Implementation plan

Phased so we can ship value incrementally and validate each layer
before adding the next.

### Phase 0 — Pre-work review

- Re-read git history around the original `WindowManager.updateTabFrame`
  and `TabFrameReader` (deferred 2026-04-26). What worked, what didn't,
  what we learned.
- Audit current `AXSupport.swift` for what's already present and what's
  missing.
- Validate AX permissions still working post-refactor.

### Phase 1 — AX foundation

Lift the patterns from Swindler's API.swift without taking the
dependency. Build a thin layer in `Sources/Services/`:

- `AXObserver` wrapper — subscribe to `kAXMovedNotification`,
  `kAXResizedNotification`, `kAXUIElementDestroyedNotification`,
  `kAXTitleChangedNotification` on a target AXUIElement. Coalesce
  events on MainActor.
- `AXWriteTracker` — when we call `setFrame` or `raise`, record the
  (element, attribute, timestamp) tuple. AXObserver events that match
  a recent write are flagged `userInitiated == false` (it was us).
  Window: ~250ms.
- `WindowRef` value type wrapping `AXUIElement` + `pid` + cached
  `bundleIdentifier` + `isValid` check. Replaces raw `AXUIElement`
  passing in higher layers.

~250–400 LOC. Pure foundation, no UI.

### Phase 2 — Layout engine

Computing where each docked window goes, given the hub's frame and the
current set of docked sessions:

- `DockLayout` struct — input: hub frame, active tab index, total tabs,
  desired tab-bar height. Output: dock rect (where tab content goes).
- `DockController` — owns the set of docked session ids in order.
  Reacts to hub move/resize and writes new frames to all docked
  windows. Filters its own write feedback via `AXWriteTracker`.

Pure computation + AX writes. No UI surface yet — the hub's existing
TabbedHostArea provides the visual rectangle; we just position foreign
windows over it.

### Phase 3 — Spawn-into-dock (scenario 1)

Wire the launch flow to dock automatically:

- After `SessionLauncherService` AX-binds the new window, register it
  with `DockController`.
- Position into the next tab slot.
- Tab UI in hub updates to show new tab.

This is the smallest end-to-end test: launch a session, see it dock,
switch with another session, both follow when the hub moves.

### Phase 4 — Adopt-from-list (scenario 2)

External session adoption:

- Sidebar section: "Available to dock" — running claudes that the hub
  didn't launch (filter the existing `ClaudeSessionFile` enumeration
  for sessions whose pid we don't already track).
- "Adopt and dock" action → AX-binds the host's window for that pid →
  registers with `DockController`.

Unblocks the daily-driver case where a user has been running claude
in plain Terminal and wants to bring it into the hub mid-stream.

### Phase 5 — Tab switching (scenario 6)

The tab bar:

- Click a tab → `AXSupport.raise(window)` for that session.
- Visual active-tab indicator.
- Keyboard shortcut: Cmd-1 / Cmd-2 / etc. for tab N.

### Phase 6 — Undocking (scenarios 4 + 5)

Letting docked windows out:

- Drag-tab-out: SwiftUI `onDrag` on tab. On drop outside the hub's
  bounds, unregister from `DockController`. Window stays where it is
  (stops following the hub).
- Drag-titlebar-out: AXObserver on docked window → `kAXMoved` +
  `userInitiated == true` → if new origin is > N pixels from the
  docked rect, unregister.

### Phase 7 — Drag-from-sidebar (scenario 3)

Optional: SwiftUI drag from sidebar row to tab area. Nice-to-have if
adoption-via-click feels insufficient, otherwise defer.

### Phase 8 — Edge cases

- Multi-monitor — pick which screen the hub is on, bound docked
  windows to that screen.
- AX trust loss mid-session — if user revokes permissions, gracefully
  release all docked windows and surface an error.
- Hub minimized — pause docked-window tracking; on restore, re-snap
  positions.
- Foreign app quit — unbind, move session to closed.
- Foreign window minimized by user — release tracking? Hide tab?
  TBD, design call.

### Phase 9 — Polish

- Animation on dock/undock (set frame in steps over ~150ms instead of
  instantly for visual coherence).
- Tab thumbnails (or icons + truncated titles).
- Drag-to-reorder tabs.

---

## Open questions before coding

1. **Undock trigger threshold.** How many pixels off the docked rect
   before we release? 20? 50? Magnet uses ~25–30 by feel.
2. **Multi-monitor default behavior.** Pin docked windows to the same
   screen as the hub, or allow them to follow the hub if the user
   drags it to a different screen?
3. **Tab bar positioning.** Top of the docked area (Chrome-like) or
   left side (vertical)? Affects DockLayout.
4. **What happens when the hub is the only thing on screen and the
   user clicks somewhere outside it?** Docked windows lose focus, hub
   loses focus, tab bar should still show active tab. AX should
   handle this naturally — verify.
5. **Should we expose a "docked / undocked" toggle per session?** Or
   is "in tab area" implicitly docked, "outside tab area" implicitly
   undocked?

---

## References (for learning, not dependencies)

- **[yabai](https://github.com/asmvik/yabai)** — full-screen tiling
  window manager for macOS. C/Obj-C daemon, 28k stars, MIT licensed.
  Not usable as a library (it's a separate process you talk to via
  CLI/socket), and its global-tiling model doesn't match our
  "rectangle inside our hub" model. But the source is excellent
  reference material for: AX observer patterns, working around
  individual host apps' weird behaviors, multi-screen handling, and
  what NOT to do without disabling SIP. Read; don't depend.
- **[Swindler](https://github.com/tmandry/Swindler)** — Swift AX
  wrapper, MIT licensed. Embodies the patterns we need (cached state,
  async writes, `userInitiated` event flag) but is dormant alpha
  (last code commit 2022-09) and predates Swift Concurrency.
  See its `API.swift` for a clean roadmap of the wrapper's domain
  model. Reference, not dependency — we're rolling our own.

---

## Non-goals

- Docking arbitrary apps (web browsers, etc.). Only host windows for
  active claude sessions. Out of scope unless a real use case emerges.
- Window reparenting / SkyLight. Stay AX-only.
- Replicating Yabai's tile management. We have one dock area, N
  sessions, simple stacking. Anything more elaborate is feature creep.
- App Store distribution. Already off the table.
