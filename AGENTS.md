# Notes for Codex

This file is loaded into every Codex session in this repo. Keep it tight; high-signal notes only.

## What this is

**pebble** — open-source macOS terminal. Slogan: *"a terminal built for the coding experience"*. Core differentiation is vertical tabs + one-click AI agent sessions. macOS-only, MIT licensed.

The user (Corey) makes product decisions; Codex does the implementation. Keep code tight and avoid over-engineering — every milestone earns the next.

## Active stack

- Swift 6.2 / SwiftUI / AppKit / SPM
- Terminal engine: **libghostty** via a prebuilt `Vendor/GhosttyKit.xcframework`. `TerminalEngine` protocol keeps the engine swappable; `TestEngine` validates it in tests.
- Session model: **Workspaces → Pane tree → Tabs** (cmux-style). `Workspace.root: PaneNode` is a recursive `.pane(Pane) | .split(...)` tree; each leaf `Pane` owns its own tab list + active-tab id. `WorkspaceStore` owns the list of workspaces and the active workspace id.

## First-time setup gotcha

`Vendor/` is gitignored. On a fresh checkout you must run `./scripts/setup-libghostty.sh` before `swift build`, otherwise the binaryTarget resolution fails. The script is idempotent.

## Architecture pointers

- Roadmap + design decisions: [ARCHITECTURE.md](ARCHITECTURE.md)
- libghostty wiring + integration gotchas (surface creation timing, action_cb routing, hover tracking, clipboard, scroll accumulator): see "libghostty Integration Notes" in ARCHITECTURE.md
- Engine protocol: `Sources/PebbleKit/Terminal/TerminalEngine.swift`
- Active engine impl: `Sources/PebbleKit/Terminal/LibghosttyEngine.swift`
- Session model: `Sources/PebbleKit/Sessions/{Workspace,WorkspaceStore,Session,Pane,PaneNode}.swift`
- Split tree renderer: `Sources/PebbleKit/Terminal/PaneTreeView.swift`
- Right-click event filter: `Sources/PebbleKit/Sessions/RightClickCatcher.swift`
- Window-drag handle (the only thing that can move the window — `isMovable = false` globally): `Sources/PebbleKit/App/WindowDragHandle.swift`
- App metadata (single-source for About panel + Help menu + window title): `Sources/PebbleKit/App/AppInfo.swift`
- Menu DSL (`MenuRow` / `MenuEntry` / `selfRow` / `responderRow` / `buildMenu`): inside `Sources/PebbleKit/App/AppDelegate.swift`
- Activity color tokens (`Theme.activityRunning/Failure/Attention` — single source for tab + workspace dot palette): `Sources/PebbleKit/App/Theme.swift`
- Custom bundle resolver (replaces SPM's auto-generated `Bundle.module` so resources resolve in both `swift run` and `.app` layouts): `bundleResourceURL` in `Sources/PebbleKit/App/Theme.swift`
- Shell-integration zsh / bash wrappers (OSC 7 cwd, OSC 133 command status, agent auto-launch): `Sources/PebbleKit/Terminal/ShellIntegration.swift`
- Rename popover primitive (`PebbleRenameField`, shared by tab + workspace rename UIs): `Sources/PebbleKit/Sidebar/RowStyle.swift`
- `.app` build pipeline (sips + iconutil for AppIcon.icns, adhoc codesign, Info.plist heredoc with `PebbleApp.displayVersion` injected): `scripts/build-app.sh`
- DMG packaging (drag-to-Applications layout via staging dir + `hdiutil`): `scripts/build-dmg.sh`
- Brand assets (single 1024×1024 source PNG, `build-app.sh` generates the multi-size `.iconset` at build time): `branding/AppIcon.png`

## Module layout

- `Sources/Pebble/main.swift` — thin executable. Just bootstraps `AppDelegate`.
- `Sources/PebbleKit/` — library with everything else (App, Sessions, Sidebar, Terminal). SPM doesn't allow tests to import an executable, so all logic lives here.
- `Sources/PebbleHook/` — tiny CLI invoked from agent hooks (Claude Code's `--settings` hooks, Codex `notify`). Connects to the unix socket at `~/Library/Application Support/pebble/socket` and writes one JSON line per event. Stays off `PebbleKit` so the binary is dependency-free.
- `Tests/PebbleKitTests/` — XCTest suite. Run with `swift test`.

## Testing

Run `swift test` after each non-trivial change. Aim to write a test whenever you touch pure logic (`WorkspaceStore`, `AgentTemplate`, key-translation helpers) — engine/UI/PTY paths stay manual.

- Tests use `@testable import PebbleKit` so internal types are reachable.
- `WorkspaceStore` takes an `engineFactory` closure; tests pass `TestEngine` (in `Tests/PebbleKitTests/TestEngine.swift`) so no libghostty/PTY is started.
- `@MainActor`-isolated tests just annotate the test class with `@MainActor`.

## Roadmap

- M0–M2: ✅ shipped (window, libghostty, scroll, hover, chrome, workspaces+tabs, right-click menu, drag-to-scroll)
- M3: ✅ agent launcher (Claude Code / Codex / Gemini CLI / OpenCode / Amp), per-session executable + env injection, OSC 7 cwd tracking, refined chrome
- M4: ✅ persistence + keyboard shortcuts (⌘T / ⌘N / ⌘W / ⌘⇧W / ⌘1-9) + hidden title bar
- M4.x: ✅ Sidebar agent activity dot — Claude Code hooks + Codex `notify` + IME (NSTextInputClient). Gemini / OpenCode / Amp wrappers TBD.
- M4.y: ✅ cmux-style splits — recursive `PaneNode` tree, per-pane tab bars, ⌘D / ⌘⇧D split, ⌘[ / ⌘] focus cycle, drag-resize divider, click-to-focus via `engine.onFocus`, right-click menus styled with `PebbleMenuRow` (shortcut hints in SF Pro), persistence schema with backward-compat decoder for the legacy flat-tabs layout.
- M4.z: ✅ drag-reorder workspaces + tabs (animated, direction-aware indicators), cross-pane tab move preserves session state, `+` doubles as drop-at-end, double-click tab bar = `performZoom`. `closePane` uses object identity (`===`) not id equality after the post-split id-collision bug bit.
- M5: ✅ three-state sidebar (`full` / `compact 52pt` / `hidden`, ⌘⌃S cycles), top chrome strip with explicit `WindowDragHandle` (`window.isMovable = false` globally so tab DnD wins), View menu becomes navigation hub, Help + Debug menus, custom About panel sourced from `PebbleApp` constants, declarative menu DSL. URL ⌘+click + mouse shape + `⌘=`/`⌘-`/`⌘0` font size + `⌘K` Clear Pane + sidebar mode persistence. Tab + workspace manual rename via right-click. OSC 133 / FinalTerm command-status dot per tab + `⌘↑`/`⌘↓` jump-to-prompt; failure dot also surfaces at the workspace row. `Theme.activityRunning/Failure/Attention` the single source for the palette. `.app` bundle pipeline (`scripts/build-app.sh` + `scripts/build-dmg.sh`) + `Theme.swift` custom bundle resolver replacing SPM's `.module` accessor. AppIcon from `branding/AppIcon.png` → multi-size `.iconset` at build time. macOS 14 (Sonoma) floor. Find in scrollback (`⌘F`) per-tab via libghostty's `search:` action family. Settings UI still pending; Apple Developer ID + notarization deferred.
- M6: notifications (deferred — see ARCHITECTURE.md design)

## Do / don't

**Do**

- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing any architectural assumption.
- Run `./scripts/setup-libghostty.sh` if `Vendor/GhosttyKit.xcframework` is missing.
- Keep both engines working — `TerminalEngine` protocol is the abstraction; UI layer must not import a specific engine module beyond `ContentView`'s constructor line.
- Defer libghostty surface creation to `viewDidMoveToWindow` (the surface needs a real window + bounds before Metal can attach).
- Pair every `ghostty_surface_read_selection` with `ghostty_surface_free_text` — libghostty allocates the buffer for the caller.
- Drive the scroll indicator's position from libghostty's `GHOSTTY_ACTION_SCROLLBAR` action_cb. While the user is dragging the knob, the local position takes precedence so the cursor isn't yanked by the action_cb roundtrip.
- For trackpad scroll, accumulate `event.scrollingDeltaY` in points and only forward to `ghostty_surface_mouse_scroll` once the accumulator crosses a cell-line worth (~20 pt). Raw forwarding scrolls hundreds of lines per swipe.
- For right-click on SwiftUI views that need a custom popover (not NSMenu), use `RightClickCatcher` in `.overlay()` — its `hitTest` returns `self` only when `NSApp.currentEvent.type` is `rightMouseDown/Up/Dragged`, so left clicks and `.onHover` pass through. `.background()` won't see right-clicks behind a libghostty `IOSurfaceLayer`; the layer eats clicks before any sibling/background view can react.
- Window drag from anywhere except the explicit `WindowDragHandle` is **off** (`window.isMovable = false`). Otherwise `fullSizeContentView` makes the top ~22pt of every pane an implicit title-bar drag region, and AppKit's window-drag activation threshold is smaller than SwiftUI's `.onDrag` threshold — tab DnD races and loses. `WindowDragHandle.mouseDown` flips `isMovable = true`, calls `performDrag(with: event)`, and restores via `defer`.
- When opening a context-menu popover and a follow-up rename popover off the same row, defer `isRenameOpen = true` by one `DispatchQueue.main.async` tick so the context popover finishes dismissing first — back-to-back popovers anchored on the same view glitch otherwise.
- Default to writing no comments. Add one only when the **why** is non-obvious — invariants, workarounds, hidden constraints.

**Don't**

- Don't create `~/.hushlogin` to suppress the "Last login" line — it permanently changes the user's global shell behavior. Set `surfaceConfig.command = $SHELL` instead so libghostty execs the shell directly and skips `/usr/bin/login`.
- Don't add a SwiftUI `.background(...)` modifier directly behind a libghostty `IOSurfaceLayer` — when the colors mismatch (or even when they don't, in some compositing edge cases) it produces a visible seam. Set the chrome background once, sourced from `engine.backgroundColor` (or the module-internal `pebbleDefaultTerminalBackground`), on the SwiftUI parent.
- Don't add a polling tick timer on `ghostty_app_tick`. The runtime is event-driven via `wakeup_cb`. Rendering uses a separate per-surface 60 Hz timer for `ghostty_surface_draw` only, gated on `(surface != nil && window != nil)`.
- Don't override `mouseMoved` without also installing an `NSTrackingArea` — without the tracking area the override is dead code and link/hover tracking never works.
- Don't override both `setFrameSize` and `resizeSubviews(withOldSize:)` — they fire on the same change and double-propagate. `setFrameSize` is the canonical hook.
- Don't try to `deinit`-free a libghostty surface: Swift 6's nonisolated `deinit` cannot touch `@MainActor` state. Use explicit `releaseSurface()` from the engine's `terminate()`. Nil the property before calling `ghostty_surface_free` so any guarded read sees the cleared state.
- Don't write to `NSPasteboard` from libghostty's `write_clipboard_cb` directly — the callback is on a worker thread and the change notification doesn't reach clipboard managers. Hop to main first.
- Don't concatenate the multiple MIME variants `write_clipboard_cb` hands you — they're alternative representations of the same selection, not separate lines. Pick `text/plain`, fall back to the first entry.
- Don't lift other terminal apps' source patterns wholesale — read for understanding, write your own implementation, especially when their license isn't compatible with ours.

## Comment & commit style

- Commits use simple version tags (`v0.1`, `v0.2`, …). Detail goes in CHANGELOG.md, not the commit body. Co-authored line is appended automatically.
- Each release bump checklist:
  1. Append a new section to CHANGELOG.md (prose + bullets, why-focused).
  2. Bump `PebbleApp.displayVersion` in `Sources/PebbleKit/App/AppInfo.swift` — single source for the About panel; if you forget, About lies about which version is running.
  3. `git commit -m "vX.Y"`.
- Avoid milestone TODOs in code (`// M5 will...`). Either capture the work in ARCHITECTURE.md's roadmap or omit it.
