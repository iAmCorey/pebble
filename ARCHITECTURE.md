# pebble Architecture

## Vision

**A terminal built for the coding experience.** Native macOS terminal where vertical tabs are the primary interaction and AI agent sessions are first-class. Every product decision is judged by one question: does it make the daily coding loop smoother? Local-only, MIT-licensed, zero cloud dependencies.

## Tech Stack

| Layer | Choice |
|---|---|
| Language | Swift 6.2+ |
| UI (primary) | SwiftUI |
| UI (system integration) | AppKit |
| Terminal engine | **libghostty** via a prebuilt `GhosttyKit.xcframework` (Metal-accelerated, full ANSI/UTF-8/scrollback). The `TerminalEngine` protocol abstracts the engine — `TestEngine` validates the seam in tests; new engines can be added without touching UI code. |
| Build | Swift Package Manager + binaryTarget |
| Deployment target | macOS 14+ (Sonoma — `@Observable` is the floor; lowering further would mean reverting to `ObservableObject` + `@Published` across all session models) |

## Session Hierarchy

Three levels — `Workspace` → `Pane` (tree) → `Session`:

```
WorkspaceStore
└── workspaces: [Workspace]
    ├── root: PaneNode                    (recursive split tree)
    │   ├── .pane(Pane)                   leaf — owns its own tab strip
    │   │   ├── tabs: [Session]           (one libghostty surface per session)
    │   │   └── activeTabId
    │   └── .split(orientation, first, second, fraction)
    │                                     non-leaf — divider + two children
    └── activePaneId                      currently focused leaf
```

The sidebar lists workspaces; each leaf pane in the workspace's tree renders its own tab strip + content (cmux-style — ⌘D slices the whole pane region, not just the content area). Each session owns its own engine and surface, so per-tab shell state survives switching. Closing the last tab in a pane collapses the pane up into its sibling; closing the last pane closes the workspace; closing the last workspace closes the window.

## Module Layout

The package splits into a thin executable + a library so XCTest can `@testable import` the implementation (SPM doesn't allow tests to import an executable target).

```
Sources/
├── Pebble/main.swift         Bootstraps NSApplication + AppDelegate. 5 lines.
└── PebbleKit/                Library — everything else lives here
    ├── App/                 AppDelegate (window setup + declarative menu DSL:
    │                        MenuRow / MenuEntry / selfRow / responderRow /
    │                        buildMenu), ContentView (top chrome strip with
    │                        traffic-light clearance + sidebar toggle + drag
    │                        handle), Theme (colors / fonts / spacing /
    │                        chromeTransition + activityRunning/Failure/Attention
    │                        dot palette), AppInfo (PebbleApp metadata — single
    │                        source for About panel + Help menu + window title),
    │                        WindowDragHandle (NSView with
    │                        mouseDownCanMoveWindow=false + performDrag bounce)
    ├── Terminal/            TerminalEngine protocol, LibghosttyEngine,
    │                        PaneTreeView (recursive split renderer with drag-
    │                        resize divider), ScrollIndicator, ShellIntegration
    │                        (zsh / bash wrapper rc files for OSC 7 cwd, OSC 133
    │                        command-status hooks, and agent auto-launch)
    ├── Sidebar/             Workspace list (SidebarView, SidebarWorkspaceRow,
    │                        HoverableIconButton, RowStyle — PebbleMenuRow +
    │                        PebbleMenuDivider + PebbleRenameField primitives
    │                        shared by every popover menu / rename popover)
    ├── Sessions/            Workspace + WorkspaceStore + Session models (Session
    │                        carries customTitle + lastCommandExit/Duration),
    │                        Pane + PaneNode (recursive split tree), per-pane
    │                        tab bar (TabBarView, TabBarItem with command-status
    │                        dot), RightClickCatcher (NSEvent-filtered overlay
    │                        catching only secondary clicks), AgentTemplate +
    │                        AgentIconView
    ├── Sessions/            (continued) — Persistence (Codable schema with
    │                        backward-compat decoder for the legacy flat-tabs
    │                        layout + FilePersistence writing to Application
    │                        Support)
    └── Resources/
        ├── Fonts/           Onest variable + JetBrains Mono — registered at
        │                    launch via CTFontManagerRegisterFontsForURL
        └── Icons/           Brand PNGs from lobe-icons (Claude Code, Codex,
                             Gemini, OpenCode, Amp)

Tests/PebbleKitTests/         XCTest suite — TestEngine + AgentTemplate +
                             WorkspaceStore. `swift test` runs in <30ms.

scripts/                     setup-libghostty.sh (xcframework fetch),
                             build-app.sh (release build + AppIcon.icns
                             from branding/AppIcon.png + adhoc codesign,
                             writes dist/Pebble.app), build-dmg.sh
                             (drag-to-Applications layout for distribution)

branding/                    AppIcon.png (1024×1024 source for the
                             multi-size .iconset, tracked in git so any
                             clone can produce the icon-equipped .app;
                             build-app.sh falls back to the system
                             blank-document icon when this file is
                             missing)
```

Cross-module wiring lives in `App/ContentView.swift`. Engine creation is injected through `WorkspaceStore.engineFactory` so tests can swap in `TestEngine` without standing up libghostty.

## Core Data Flow (M2)

```
User clicks "+" in tab bar → WorkspaceStore.addTab(in: workspace)
        ↓
new Session created with a fresh LibghosttyEngine (not yet rendered)
        ↓
SwiftUI re-renders; .id(active.id) forces TerminalView to rebuild
        ↓
GhosttySurfaceView attaches to the window → viewDidMoveToWindow
        ↓
createSurfaceIfReady → ghostty_surface_new spawns the user's $SHELL
        ↓
libghostty renders into the IOSurfaceLayer; SCROLLBAR action_cb drives
the overlay indicator
```

When the active session changes (tab switch or workspace switch), SwiftUI tears down the previous `TerminalView` representable and the inactive engine.view leaves the window — `updateDrawTimer()` stops the 60 Hz draw timer so background sessions don't burn frames.

## Shell Integration

Two pieces live behind libghostty: per-tab cwd tracking and one-click agent launch. Both rely on running each session under a wrapper rc file we generate per-process.

- **zsh** — we set `ZDOTDIR` to a temp directory containing our wrapper `.zshrc`. Zsh sources that file instead of `~/.zshrc`; the wrapper sources the user's real `~/.zshrc` first, then installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`). Libghostty reports OSC 7 via `GHOSTTY_ACTION_PWD`, which we route into `WorkspaceStore.addTab`'s `engine.onPwdChange` callback.
- **bash** — bash has no `ZDOTDIR` equivalent, and login bash ignores `--rcfile` (libghostty starts every command as a login shell, `argv[0]` prefixed with `-`). We work around it with a tiny launcher script: `surfaceConfig.command` points at `/tmp/pebble-bash-launch-<pid>.sh`, whose body is `exec /bin/bash --rcfile <wrapper> -i`. The launcher inherits the login `-` prefix; the re-exec'd bash doesn't, so it reads our `--rcfile` like any non-login interactive shell.
- **OSC 133 command status (zsh-only for now)** — the same ZDOTDIR wrapper appends a `precmd` hook that emits `OSC 133;D;<exit>` for the just-finished command then `OSC 133;A` for the new prompt, a `preexec` hook that emits `OSC 133;C` when the user submits a command, and re-injects the `B` marker into `PROMPT` on every redraw (Starship / p10k themes rebuild PROMPT each precmd, so we have to reapply each iteration; idempotent substring-guarded). A `__pebble_133_first` flag suppresses the spurious `D` on the very first prompt before any command has run. Libghostty parses these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` with `(exit_code, duration_ns)` on `D` — pebble surfaces that as a per-tab status dot (`Session.lastCommandExit/Duration`) and aggregates non-zero exits up to the workspace row via `Workspace.sidebarReadout.hasCommandFailure`. Bash OSC 133 hooks are TBD.
- **Agent launch** — `AgentTemplate` puts `PEBBLE_AGENT=<binary>` into `surfaceConfig.env_vars`. Both wrappers check for it at the bottom and `"$PEBBLE_AGENT"` inline before the prompt is ever printed — the user goes straight into the agent UI, no `claude` echo. `PEBBLE_AGENT_LAUNCHED` guards subshell re-entry.
- **Other shells** (fish, nu, …) — agent sessions force `/bin/zsh` so the wrapper still runs; plain terminal sessions respect `$SHELL` and just don't get cwd tracking. A precmd-over-IPC scheme would cover every shell, but it costs three wrappers plus a socket; OSC 7 buys most of the value with one wrapper per shell.

The wrapper files live in `NSTemporaryDirectory()` keyed by PID; `applicationWillTerminate` cleans them up so they don't accumulate.

## Agent Activity State (Hooks)

Each `Session` carries an `activityState ∈ { .idle, .running, .attention }`; the sidebar row aggregates across tabs (`attention` > `running` > `idle`) and surfaces a colored dot in the trailing slot. State is **driven by the agent itself**, not inferred from PTY output:

```
[ Claude Code ] ── --settings hooks.json ──> [ PebbleHook CLI ]
                                                   │
                                                   │ unix socket
                                                   ▼
                                  [ HookServer (Sources/PebbleKit/Sessions/) ]
                                                   │
                                                   ▼
                                 [ WorkspaceStore.applyHookEvent ]
```

Wiring per session:

- `WorkspaceStore.startSession` calls `PebbleShellIntegration.pebbleEnvironment(for:)` to merge `PEBBLE_SURFACE_ID` (the session UUID), `PEBBLE_HOOKS_PATH`, `PEBBLE_BIN_DIR`, `PEBBLE_HOOK_BIN`, plus `PATH` (pebble-bin prepended) and `TERM=xterm-256color` into the spawned shell's environment.
- The bundled `~/Library/Application Support/pebble/bin/{claude,codex}` wrappers (generated at app launch by `installAgentHooks`) see `$PEBBLE_SURFACE_ID` and inject the agent-specific config.
- **Claude path:** wrapper invokes the real `claude --settings $PEBBLE_HOOKS_PATH`. The hooks JSON registers `PebbleHook claude <event>` for `UserPromptSubmit` (`running`), `Stop` / `Notification` (`attention`), `SessionEnd` (`ended`).
- **Codex path:** Codex doesn't expose Claude-style lifecycle hooks per-invocation, only a `notify` config that fires on `AgentTurnComplete`. Wrapper inlines `-c notify=[<PebbleHook>,"codex","attention"]`. To cover SessionStart / SessionEnd we bracket the run from the wrapper itself: `PebbleHook codex running` before `exec`, `PebbleHook codex ended` after exit.
- `PebbleHook` reads `$PEBBLE_SURFACE_ID` from its env (inherited via the agent → hook subprocess), opens `~/Library/Application Support/pebble/socket`, writes `{"agent":"…","event":"…","surface":"<UUID>"}\n`, exits.
- `HookServer` accepts each connection on the main runloop and parses raw JSON into typed values via `AgentTemplate.from(hookSlug:)` + `HookEvent` (`running` / `attention` / `idle` / `ended`). Unknown agents/events drop at the boundary; `WorkspaceStore.applyHookEvent(agent:event:sessionId:)` switches exhaustively.
- **Auto-promote:** when a `.terminal` session reports a `claude` / `codex` hook (user typed the command in the shell), the session's template is upgraded so the sidebar / tab icon catches up. `.ended` reverts to `.terminal` only when the reporting agent matches the current session agent (so running Codex inside a Claude tab doesn't wipe Claude's icon).

`PebbleHook` is a separate SPM executable target intentionally — staying off `PebbleKit` keeps the binary tiny and dependency-free, and the launch path is just `socket` + `connect` + `write` + `close`.

`PATH` injection: each spawned shell gets `PEBBLE_BIN_DIR:$PATH` prepended at spawn, **and** the wrapper rc files (`zshrc` / `bashrc`) re-prepend after sourcing the user's rc — guards against user `.zshrc` doing its own `PATH` rewrites that would push our wrapper to the back.

Gemini / OpenCode / Amp don't drive `activityState` yet — they still use the basic inline-launch path. Per-agent wrappers + hook protocols are the next slice.

## libghostty Integration Notes

The active engine lives in `Sources/Pebble/Terminal/LibghosttyEngine.swift` and follows libghostty's "host owns the chrome" contract.

- **xcframework**: We don't build libghostty from source. `scripts/setup-libghostty.sh` fetches a prebuilt `GhosttyKit.xcframework.tar.gz` keyed by ghostty submodule SHA, verifies SHA256, and renames the macOS slice's `ghostty-internal.a` to `libghostty-internal.a` so SPM accepts it. The xcframework lives in `Vendor/` (gitignored).
- **Singleton runtime**: `LibghosttyApp.shared` calls `ghostty_init` and `ghostty_app_new` once. All Surfaces share that handle.
- **Event loop**: `ghostty_app_tick` is event-driven via `wakeup_cb` only; no polling timer. Rendering is per-surface — a 60 Hz `Timer` calls `ghostty_surface_draw` while the surface exists AND the view is in a window. Inactive sessions stop their timer.
- **Surface creation timing**: SwiftUI's `onAppear` fires before the NSView has a window. `LibghosttyEngine.start(...)` stashes the config; `GhosttySurfaceView.viewDidMoveToWindow` drains it. Without this deferral the Metal sublayer never attaches.
- **Login bypass**: `surfaceConfig.command = $SHELL` makes libghostty exec the shell directly, skipping `/usr/bin/login` and the "Last login: …" line that would otherwise prefix every session. We deliberately do **not** create `~/.hushlogin` — silently mutating the user's global shell behavior is too invasive.
- **Action routing**: Each surface stores `Unmanaged.passUnretained(self).toOpaque()` in `surfaceConfig.userdata`. The `@convention(c)` `action_cb` recovers the originating Swift view via `ghostty_surface_userdata` and dispatches to main through the `dispatchToView(_:work:)` helper (transits the userdata as `Int(bitPattern:)` so Swift 6 concurrency doesn't flag the `UnsafeMutableRawPointer` capture). Currently handles `GHOSTTY_ACTION_SCROLLBAR` (drives the overlay indicator), `GHOSTTY_ACTION_PWD` (drives workspace cwd sync via the shell-integration wrappers), `GHOSTTY_ACTION_OPEN_URL` (⌘+click — routes to `NSWorkspace.shared.open`, returns `false` to libghostty if `URL(string:)` rejects so libghostty's built-in opener gets a fallback shot), `GHOSTTY_ACTION_MOUSE_SHAPE` (maps libghostty's shape enum to `NSCursor` and applies via `currentCursor.set()` — the tracking area's `.cursorUpdate` reapplies on re-entry since libghostty only fires on shape *change*), and `GHOSTTY_ACTION_COMMAND_FINISHED` (`(exit_code, duration_ns)` from OSC 133;D — pebble maps `exit_code == -1` to `nil` so the UI uses neutral treatment instead of pretending it knows the result).
- **Named actions** (push to libghostty): `LibghosttyEngine.performAction("name:arg")` wraps `ghostty_surface_binding_action`. Used for font size (`increase_font_size:1` / `decrease_font_size:1` / `reset_font_size`), Clear Pane (`clear_screen`), and prompt jumps (`jump_to_prompt:-1` / `jump_to_prompt:1`). Adding a new keyboard-driven libghostty action is a one-line menu addition + handler routing through `performAction(_:)`, no new protocol surface.
- **Hover tracking**: `updateTrackingAreas()` installs an `NSTrackingArea` with `.activeWhenFirstResponder` so mouse-tracking apps (vim, less) and link/cursor hover feedback get pointer updates. Only the focused surface receives mouseMoved.
- **Clipboard**: copy is direct — `ghostty_surface_read_selection` (paired with `ghostty_surface_free_text` to avoid leaks) writes to `NSPasteboard`. Paste is intercepted at keyDown for Cmd+V; libghostty's own `write_clipboard_cb` covers in-terminal copy bindings, dispatching to main so clipboard-manager change notifications fire.
- **Trackpad scroll**: precise-delta wheel events (trackpad) accumulate in points; we forward to libghostty only when one cell-line's worth has crossed. Non-precise wheel ticks (legacy mice) pass through unchanged.
- **IME**: `GhosttySurfaceView` conforms to `NSTextInputClient` so non-Latin input methods (拼音 / かな / 한글 / Vietnamese / Thai / etc.) compose properly. `keyDown` short-circuits special keys + `Cmd+`/`Ctrl+letter` itself; everything else goes through `inputContext.handleEvent`, which routes through `insertText` (commit) and `setMarkedText` (in-flight composition). `firstRect(forCharacterRange:)` returns a sentinel rect anchored just below the window — libghostty doesn't expose cursor cell coords, so we can't anchor inline marked text precisely; pushing the rect off-surface keeps the system's marked-text overlay from ghosting on top of TUIs that don't redraw aggressively (Codex, vs. Claude Code which redraws each keystroke).
- **Kitty keyboard release events**: `keyUp` does NOT forward to libghostty. Codex (ratatui/crossterm) pushes kitty keyboard protocol with `report-event-types`, then mishandles the release CSI as a second press — every keystroke doubles. See [codex#18564](https://github.com/openai/codex/issues/18564). Skipping release forwarding loses nothing for vim / tmux / zsh / claude code (none of them depend on key-release semantics) and dodges the Codex bug.

## MVP Roadmap

| Milestone | Deliverable |
|---|---|
| **M0** | SPM package + empty SwiftUI window runs via `swift run` ✅ |
| **M1** | Live `zsh` session with input/output, scroll indicator, hover, and chrome ✅ |
| **M2** | Workspaces → tabs hierarchy; multi-session with switch / new / close; right-click context menu; drag-to-scroll indicator ✅ |
| **M3** | Agent launcher (Claude Code, Codex, Gemini CLI, OpenCode, Amp) + per-tab cwd tracking + refined chrome (custom fonts, brand icons) + XCTest suite ✅ |
| **M4** | Persistence (workspaces + tabs survive relaunch) + keyboard shortcuts (⌘T / ⌘N / ⌘W / ⌘⇧W / ⌘1-9) + hidden title bar ✅ |
| **M4.x** | Sidebar agent-activity dot via `PebbleHook` CLI + unix socket. Claude Code hooks ✅, Codex `notify` + bracketing ✅, IME via `NSTextInputClient` ✅, kitty-keyboard release-event workaround for Codex ✅. Gemini / OpenCode / Amp wrappers TBD. |
| **M4.y** | cmux-style splits: `Workspace.root: PaneNode` recursive tree, per-pane tab bars, ⌘D / ⌘⇧D split, ⌘[ / ⌘] focus cycle, drag-resize divider, persistence schema upgrade with backward compat. Right-click context menus (tab + sidebar workspace) styled with `PebbleMenuRow` instead of system NSMenu, shortcut hints in SF Pro. ✅ |
| **M4.z** | Drag-reorder for sidebar workspaces and per-pane tabs (animated drop-snap with direction-aware indicators). Cross-pane tab move preserves session state — sessions keep engine/scrollback/agent on move; source pane collapses if it runs out of tabs. `+` doubles as drop-at-end target. Double-click tab bar = `performZoom`. ✅ |
| **M5** | Three-state sidebar (`full` / `compact` 52pt icon-only / `hidden`, ⌘⌃S cycles). Top chrome strip with traffic-light clearance + sidebar toggle + explicit `WindowDragHandle` (`window.isMovable = false` globally so tab DnD wins). View menu becomes the navigation hub. Help + DEBUG-only Debug menus. Custom About panel sourced from `PebbleApp` constants. Declarative menu DSL. URL ⌘+click + mouse shape + font-size shortcuts (`⌘=`/`⌘-`/`⌘0`) + Clear Pane (`⌘K`) + sidebar mode persistence. Tab + workspace manual rename. OSC 133 / FinalTerm command-status dot per tab + `⌘↑`/`⌘↓` jump-to-prompt. Workspace-row failure aggregation + `Theme.activityRunning/Failure/Attention` palette. `.app` bundle pipeline (`scripts/build-app.sh` + `scripts/build-dmg.sh`) + custom bundle resolver replacing SPM's `.module` accessor. AppIcon. Find in scrollback (`⌘F`) per-tab via libghostty's `search:` action family. ✅ Settings UI still pending; Apple Developer ID + notarization deferred. |
| **M6** | Notifications & activity awareness (lower priority — see design below) |

### M5 sub-milestones (shipped)

- **OSC 133 / FinalTerm command status.** Per-tab pill renders a small red dot (`Theme.activityFailure`, 5pt) to the *left* of the agent icon when the most recent command exited non-zero; hover reveals a native tooltip with `exit N · 12.4s`. Per-workspace sidebar row aggregates non-zero exits across every pane via `Workspace.sidebarReadout.hasCommandFailure`, with precedence attention > failure > running > idle so a still-thinking agent never gets shouted over by a stale shell failure. Status resets on the next zero-exit so the indicator always reflects the *latest* command, not a sticky failure history. The walk runs to completion (no short-circuit) so each readout field is independent — earlier short-circuit-on-attention silently zeroed `hasCommandFailure` whenever attention fired in DFS-earlier panes than the failing tab. New `TerminalEngine.onCommandFinished: ((Int?, TimeInterval) -> Void)?` protocol member; `LibghosttyEngine` forwards from the new `GHOSTTY_ACTION_COMMAND_FINISHED` action_cb case. ZDOTDIR wrapper grew an OSC 133 hook block (precmd D+A, preexec C, PROMPT-suffix B re-injected each redraw). DEBUG `Cycle Activity` (⌘⇧A) now previews all four states in precedence order. 5 new XCTest cases (engine→session propagation, zero-exit clear, cross-pane aggregation, recovery, attention+failure independence). Suite up to 31.
- **Jump to previous / next prompt.** `⌘↑` / `⌘↓` route through `LibghosttyEngine.performAction("jump_to_prompt:-1" / ":1")` — libghostty owns "what's a prompt boundary" via the OSC 133 marks. Lives in the View menu beneath Clear Pane.
- **Manual rename — tabs and workspaces.** Right-click any tab pill → *Rename Tab…*; same on any sidebar workspace row → *Rename Workspace…*. Empty / whitespace input clears the override so the title resumes tracking the cwd. `Session.customTitle` and `Workspace.customTitle` are Codable optionals on `PersistedTab` / `PersistedWorkspace` (decoded with `decodeIfPresent`, so old `state.json` files keep loading clean). The rename `TextField` lives in `PebbleRenameField` (`Sidebar/RowStyle.swift`); both call sites pick a placeholder + a popover `arrowEdge`. The right-click menu defers `isRenameOpen = true` by one `DispatchQueue.main.async` tick so the context popover finishes dismissing before the rename popover anchors — back-to-back popovers off the same view glitch otherwise.
- **URL ⌘+click + mouse shape.** ⌘+click on any URL in any terminal opens it in the default browser via `GHOSTTY_ACTION_OPEN_URL`; falls back to libghostty's built-in opener when `URL(string:)` rejects an OSC 8 / unescaped `file://` shape. `GHOSTTY_ACTION_MOUSE_SHAPE` maps libghostty's shape enum to `NSCursor` (URL → `pointingHand`, vim split → `resizeLeftRight`, etc.). Tracking area `.cursorUpdate` reapplies the current cursor on re-entry since libghostty only fires shape changes; without this the cursor would flip back to default whenever the mouse briefly left the surface.
- **Font size + Clear Pane shortcuts.** `⌘=` / `⌘-` / `⌘0` Increase / Decrease / Default Font Size, `⌘K` Clear Pane. All routed through libghostty's named-action API (`increase_font_size:1` / `decrease_font_size:1` / `reset_font_size` / `clear_screen`). New `TerminalEngine.performAction(_:)` protocol method wraps `ghostty_surface_binding_action` so any libghostty binding can be invoked from the menu without growing the protocol surface for every new shortcut.
- **Sidebar mode persists.** `SidebarMode` becomes `String, Codable`; `PersistedState` carries the last layout so `compact` / `hidden` choices survive quit + relaunch. `WorkspaceStore.setSidebarMode(_:)` wraps the state change + `scheduleSave` in one call so the keyboard and toggle-button paths can't drift.
- **Window drag, finally honest.** `window.isMovable = false` globally, single explicit `WindowDragHandle` (`Sources/PebbleKit/App/WindowDragHandle.swift`) overrides `mouseDownCanMoveWindow = false`, hit-tests only left-mouse events (`leftMouseDown/Dragged/Up`), and on `mouseDown` flips `isMovable` true → calls `window.performDrag(with: event)` → restores via `defer`. Double-click on the handle calls `performZoom(nil)`. Replaces three failed attempts (`.background` blocker, `.overlay` blocker, `WindowDragShield` NSHostingView wrapper) that all leaked into other gestures. Codex landed the final shape.
- **Three-state sidebar.** `WorkspaceStore.sidebarMode: SidebarMode { .full, .compact, .hidden }` cycles via `.next`. `SidebarWorkspaceRow` branches on `isCompact` between `fullBody` (icon + title + path + activity dot + close) and `compactBody` (icon + activity badge floating top-trailing, hover for path). Sidebar width 220pt / 52pt / 0pt. `Theme.chromeTransition: Animation = .easeInOut(duration: 0.2)` is the shared timing token (used by both `⌘⌃S` and the toggle button so they can't drift apart).
- **Top chrome strip (32pt).** New always-on strip in `ContentView`: 82pt clearance for traffic lights (system-drawn, hit-test-disabled), sidebar toggle (sidebar.left SF symbol), then `WindowDragHandle`. Hairline below. Tab bars start at `y=32` so they don't sit under the drag handle.
- **Menu reorg.** **View** menu becomes navigation hub (Tab/Workspace switching, Split, Focus Pane, Toggle Sidebar, Enter Full Screen). **Window** drops back to macOS standard (Minimize / Zoom / Center). New **Help** (Report Issue → `iAmCorey/pebble/issues`, View on GitHub) registered as `NSApp.helpMenu` so AppKit adds the standard help search field. New `#if DEBUG` **Debug** menu (Cycle Activity).
- **Declarative menu DSL.** `MenuRow` struct + `MenuEntry` enum + `selfRow` / `responderRow` / `buildMenu(title:entries:)` replace ~70 lines of imperative `addItem` calls. `MenuTag` enum keeps the tab/workspace tag partition (`tabRange = 1...9`, `workspaceRange = 101...109`) named.
- **Custom About panel.** `NSApp.orderFrontStandardAboutPanel(options:)` populated from `PebbleApp` metadata (`name`, `displayVersion`, `tagline`, repo URL, copyright line). Without this we'd show an empty panel since pebble has no Info.plist (running directly from SPM, not bundled).
- **`PebbleApp` metadata.** New `Sources/PebbleKit/App/AppInfo.swift` consolidates app identity. `repositoryDisplay` is derived from `repositoryURL` so user-visible string can't desync from the URL. `displayVersion` is the only thing that needs bumping per release for About to update.
- **Pane padding.** `TerminalView` inside `PaneView` gets `.padding(8)` so terminal text doesn't touch chrome edges; splits get 17pt visual gap between adjacent panes.

### M4.z sub-milestones (shipped)

- **Drag-reorder.** SwiftUI `.onDrag` / `.dropDestination` on each workspace row and tab pill; `.dropIndicator(active:on:offset:length:)` modifier in `RowStyle.swift` is the single source for the 2pt edge line used by all three reorder gestures (workspace rows, tab pills, `+` button as drop-at-end). Direction-aware edge: drag down/right → drop indicator on bottom/trailing of target; drag up/left → top/leading. Animated drop-snap via `withAnimation(.easeInOut(duration: 0.18))`.
- **Cross-pane tab move.** `WorkspaceStore.handleTabDrop(droppedId:to:at:in:)` is the single entry point; same-pane drops dispatch to `moveTab(from:to:in:)`, cross-pane drops to `moveTab(_:to:at:in:)`. Sessions keep their engine/scrollback/agent across moves. Source pane collapses (sibling pops up via `parent.content = sibling.content`) when it runs out of tabs.
- **Bug fixes.** `closePane` switched from id-equality to object identity (`leafNode === workspace.root`) — after `splitPane`, root and a child wrapper can share `pane.id`, and the old check would false-match a child collapse to "close whole workspace". Cross-pane move now syncs `workspace.workingDirectory` so sidebar title + next-spawned tab cwd track the moved session.
- **Right-click menu shortcut hints.** Bound shortcuts render right-aligned in SF Pro 11.5pt next to their menu item — JetBrains Mono had wrong glyph shapes for ⌘⇧⌥⌃, system font matches AppKit's native key-equivalent rendering.
- **Double-click tab bar = Zoom.** Empty area of any pane's tab strip acts as window's title-bar substitute — `performZoom` (filled screen, dock + menu kept), distinct from `toggleFullScreen` which animates into its own Space.
- 2 new XCTest cases (cross-pane move from root pane keeps workspace alive — regression for the id-collision bug; cross-pane move syncs `workspace.workingDirectory`). Suite at 31 cases.

### M4.y sub-milestones (shipped)

- `PaneNode` recursive class (`@Observable`) holds either `.pane(Pane)` or `.split(orientation, first, second, fraction)`; `Pane` owns `tabs: [Session]` + `activeTabId`. `Workspace.tabs: [Session]` retired in favor of `Workspace.root: PaneNode` + `activePaneId`.
- `splitPane(_ pane:orientation:in:)` rewrites the leaf node's content to `.split` with the existing pane as `first` and a new `Pane` (single fresh `Session` inheriting active-tab agent + cwd) as `second`. `closePane` collapses the parent split: `parent.content = sibling.content`, so the sibling effectively pops up one level.
- `PaneTreeView` is the recursive renderer. `.pane` leaves render `VStack { TabBarView, hairline, TerminalView(activeTab) }`; `.split` nodes use a `GeometryReader` + `HStack`/`VStack` keyed off `fraction`, with a 1pt hairline divider plus a 6pt transparent grab strip that flips the cursor to `resizeLeftRight` / `resizeUpDown` and writes the new fraction back via direct `node.content` mutation. `flushPersistence()` fires on drag end so resize survives relaunch.
- Click-to-focus: `TerminalEngine.onFocus` is a new callback fired from `GhosttySurfaceView.becomeFirstResponder`. `WorkspaceStore.wirePwdSync` binds it to `activateTab(session, in: workspace)` so clicking any pane updates `Workspace.activePaneId` + the matching `Pane.activeTabId` + `workingDirectory` together — split-aware operations (⌘D, cwd inheritance, sidebar dot) follow the visually-active pane.
- Right-click stack: `RightClickCatcher` (NSViewRepresentable) installs a `hitTest` override that returns `self` only when `NSApp.currentEvent.type` is `rightMouseDown/Up/Dragged`; left clicks and `.onHover` pass through to SwiftUI gestures behind it. Sits in `.overlay()`. Tab and sidebar-row right-click menus render as SwiftUI `.popover`s built from `PebbleMenuRow` (shared with the `+` agent picker) — `Theme.chromeBackground`, Onest titles, optional `shortcut` slot in SF Pro 11.5pt for ⌘W / ⌘D / ⌘⇧D / ⌘⇧W.
- Persistence schema: `PersistedWorkspace.tabs: [PersistedTab]` → `PersistedWorkspace.root: PersistedPaneNode` (`.pane(PersistedPane{tabs, activeTabId}) | .split(orientation, first, second, fraction)`). Custom `init(from:)` falls back to the legacy `tabs` key, wrapping each old session into a single `.pane` with the original tab list — legacy `state.json` files migrate transparently on first read.
- Hot-path perf: `PaneNode.allPanes` switched from `a.allPanes + b.allPanes` (allocates per split) to an in-place accumulator. New short-circuit lookups: `PaneNode.pane(id:)`, `pane(containingSessionId:)`. `Workspace.activePane` now O(depth). `Workspace.distinctAgents` + `Workspace.activityState` folded into a single early-exit DFS that fills both in one walk (sidebar reads both per render). `activateTab` / `focusPane` / `setSplitFraction` guard every assignment so repeat focus events don't trigger phantom @Observable invalidations + persistence writes.
- 6 new XCTest cases (split creates sibling + focuses it, split inherits agent + cwd, close pane collapses sibling up, closing only tab in second pane collapses the split, focus pane switches active pane, restore split tree reconstructs both panes + fraction). Suite up to 26.

### M4 sub-milestones (shipped)

- `Persistence` protocol + `FilePersistence` (JSON in `~/Library/Application Support/pebble/state.json`); `InMemoryPersistence` for tests
- `WorkspaceStore` debounced `scheduleSave()` (1 s) plus `flushPersistence()` called from `applicationWillTerminate`
- Restore path validates each saved cwd via `FileManager.fileExists`, falls back to `$HOME` if missing; verifies `activeWorkspaceId` / `activeTabId` resolve before assigning so a corrupted file can't pin a non-existent active reference
- `Workspace.id` / `Session.id` accept an init parameter so restore preserves identity (active references stay valid across relaunch)
- Three persistence tests added (round-trip, cwd-from-state, flush snapshot)
- `AppDelegate` builds a runtime `NSMenu` (App / File / Edit / Window) — `⌘T`, `⌘N`, `⌘W`, `⌘⇧W`, `⌘1-9`; first-responder selectors for `⌘C` / `⌘V` / `⌘X` / `⌘A` so libghostty handles them inside the surface
- Window uses full-content layout with `titleVisibility = .hidden` and `titlebarAppearsTransparent` — traffic lights overlay the sidebar header (32 pt clear-space), tab bar sits at the window top edge
- SwiftTerm fallback dropped; `TerminalEngine` protocol kept for `TestEngine` + future engine swaps; Carbon framework now linked directly (was a transitive of SwiftTerm)

### M3 sub-milestones (shipped)

- PebbleKit library + thin Pebble executable so XCTest can `@testable import` the app code
- `WorkspaceStore.engineFactory` injection — tests use `TestEngine`, prod uses `LibghosttyEngine`
- `AgentTemplate` (Terminal / Claude Code / Codex / Gemini / OpenCode / Amp) with brand icons (lobe-icons PNG, MIT) and inline launch via `PEBBLE_AGENT` env + wrapper `.zshrc` / `.bashrc`
- OSC 7 cwd tracking — `Workspace.workingDirectory` follows the active tab's `cd`; new tabs inherit; sidebar path label + tab title both derive from cwd
- `Session.currentDirectory` per-tab; `WorkspaceStore.activateTab` syncs workspace cwd on switch
- `+` menu rebuilt as a SwiftUI popover (NSMenu drops custom `Image(nsImage:)` icons)
- Theme system — Onest (display) + JetBrains Mono (mono) registered at launch via `CTFontManagerRegisterFontsForURL`; chrome palette / spacing tokens centralized in `Theme.swift`
- `hoverableRowBackground` view modifier — three row patterns (sidebar, tab, menu) share one source of truth for hover/active alpha
- 17-test XCTest suite — `AgentTemplateTests` + `WorkspaceStoreTests`

### M2 sub-milestones (shipped)

- Workspace + WorkspaceStore models — workspace owns tabs, sidebar lists workspaces, top tab bar lists tabs
- Sidebar (`SidebarView` + `SidebarWorkspaceRow`) and top tab bar (`TabBarView` + `TabBarItem`)
- `HoverableIconButton` shared helper for every +/× control
- `.id(active.id)` on `TerminalView` so the NSViewRepresentable rebuilds cleanly per session
- `updateDrawTimer()` gates ghostty_surface_draw on `(surface != nil && window != nil)`
- Right-click context menu — Copy / Paste / Select All / Clear
- `surfaceConfig.command = $SHELL` to skip /usr/bin/login (no .hushlogin write)
- Trackpad scroll accumulator (point → cell-line conversion)
- Drag-to-scroll on the overlay indicator with knob hover/drag visual states
- `ghostty_surface_read_selection` + `ghostty_surface_free_text` for menu Copy
- Window forced to `.darkAqua` so SwiftUI `.primary` / `.secondary` resolve to readable colors

## M6 Notifications Design (deferred)

Detection signals (in priority order):
1. **Bell character** (`\a` / Ctrl-G) — agents and scripts can emit this as an explicit "done" signal; most reliable
2. **PTY process exit** — strong signal that a foreground command finished
3. **Output idle for N seconds after sustained activity** — fallback heuristic

Delivery layers:
- `UNUserNotificationCenter` system notification (request permission on first run)
- Sidebar tab badge (red dot) when window not focused or tab not active
- Optional sound + Dock bounce

Suppression rule: if the originating tab is the active tab and the window is in the foreground, skip — the user is already looking at it.

Per-session toggle exposed via tab right-click menu; global default in Settings.

## Out of Scope (explicitly not in MVP)

- In-app browser
- Cloud sync, remote VMs, team collaboration
- Built-in LLM calls (we launch other agents' CLIs; we don't talk to OpenAI/Anthropic ourselves)
- Linux/Windows ports
- Paid features

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Terminal engine | libghostty, behind `TerminalEngine` protocol | libghostty gives Metal-rendered terminal correctness for free. The protocol stays so a future engine (self-built libghostty, alternate renderer) can drop in without touching the UI layer; `TestEngine` already exercises the seam. |
| Session hierarchy | Workspaces → Tabs | Closing the last tab closes the workspace; closing the last workspace closes the window. Matches familiar terminal-app muscle memory and gives the agent launcher a natural "project + sessions" home. |
| libghostty distribution | Download a prebuilt `GhosttyKit.xcframework` rather than building from source | Avoids a Zig toolchain dependency, ~1-day setup, and our own CI infrastructure. Pin to a specific ghostty submodule SHA for reproducibility. |
| Window/menu layer | AppKit `NSWindow` + `NSHostingView(SwiftUI)` | macOS-idiomatic; SwiftUI alone is too restrictive for menubar/global shortcuts. Forced `.darkAqua` because the chrome is always dark. |
| Chrome bg color | Module-internal `pebbleDefaultTerminalBackground`; ContentView reads `engine.backgroundColor` when available | Mismatch between terminal background and surrounding chrome is the most visually jarring possible bug; centralize. |
| "Last login" suppression | `surfaceConfig.command = $SHELL` (skip login wrapper) | Earlier path created `~/.hushlogin` programmatically; Codex review correctly flagged this as a global side-effect that survives uninstall. The shell-direct exec achieves the same UX without touching user dotfiles. |
| Agent list | Hard-coded for MVP, user-configurable in M5 | Ship faster; agents change rarely |
| Persistence | JSON in `~/Library/Application Support/pebble/state.json`, debounced 1 s + flush on terminate | Simple, atomic write, no DB. PTY state intentionally NOT persisted — restored tabs spawn fresh sessions in the saved cwd. |
| Keyboard shortcuts | `NSMenu` with keyEquivalents owned by `AppDelegate` | NSMenu's keyEquivalent dispatch fires ahead of `GhosttySurfaceView.keyDown`, so menu shortcuts work even with libghostty's full-keyboard intercept. SwiftUI `Commands` API would have meant adopting `@main App`, which we don't use (custom NSWindow setup). |

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Prebuilt xcframework supply | Pin to a specific ghostty SHA. If supply breaks, set up our own libghostty build CI; the `TerminalEngine` protocol means the UI layer stays untouched during that swap. |
| libghostty C ABI evolution | Each ghostty SHA bump is gated by setup script's checksum; bumps land as deliberate PRs. |
| `Unmanaged.passUnretained(self)` view pointers handed to libghostty | Theoretical action_cb-after-free race during workspace teardown. `releaseSurface()` nils the property before `ghostty_surface_free` so any guarded read sees the cleared state; `passRetained` migration deferred until we hit a real crash. |
| SwiftUI sidebar perf at >50 workspaces / tabs | Sidebar uses `LazyVStack`; tab bar uses horizontal `ScrollView`. Switch to `NSOutlineView` if needed. |
| Clipboard managers (Paste, Maccy) don't see our writes | Resolved by the `.app` pipeline — was indeed the unbundled-process filter. The `scripts/build-app.sh` `.app` (Bundle ID `com.iamcorey.pebble`) is what users install; clipboard managers see writes from a real bundle. `swift run` still produces a bare executable; clipboard manager visibility there is a non-goal. |
