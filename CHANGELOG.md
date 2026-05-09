# Changelog

Notable changes per release. Tagged commits use `vX.Y` shortform.

## v0.1.0 — 2026-05-10

Initial public release of **pebble** — an open-source macOS terminal built for the coding experience. Forked from [iAmCorey/kooky](https://github.com/iAmCorey/kooky) at v0.7.7 and rebranded.

What you get out of the box:

- **AI agent launcher** — Claude Code · Codex · Gemini CLI · OpenCode · Amp via the `+` menu. Wrapper scripts auto-launch the agent before the first prompt; sidebar dot tracks per-agent activity (running / attention / idle).
- **cmux-style splits** — `⌘D` / `⌘⇧D` slice the whole pane region (tab strip + content) so each half gets its own tab bar. `⌘[` / `⌘]` cycle focus. Drag the divider to resize.
- **Drag-reorder + cross-pane tab move** — pull tabs between panes; the source pane collapses if it runs out.
- **Three-state sidebar** — full / 52pt icon-only / hidden, `⌘⌃S` cycles. Top chrome strip with traffic-light clearance and explicit `WindowDragHandle`.
- **OSC 133 command status** — small red dot on tab + workspace row when the last command exited non-zero. Hover for `exit N · 12.4s`. `⌘↑` / `⌘↓` jump to the previous / next prompt.
- **Find in scrollback (`⌘F`)** — per-tab search bar pinned to the active pane's top-right. Each pane carries independent search state. `⌘G` / `⌘⇧G` for next / previous match.
- **Manual rename** — right-click any tab or workspace → *Rename…*. Empty input clears back to cwd.
- **URL ⌘+click** opens in your default browser. Mouse cursor follows libghostty (URL → pointing-hand, vim split → resize, etc.).
- **Font size / Clear Pane** — `⌘=` / `⌘-` / `⌘0` font size, `⌘K` clear.
- **State persists** across launches — workspaces, panes, tabs, sidebar mode.
- **AppIcon** — cyber-minimalist `[ - · ]` mark on a charcoal squircle.
- **`.app` build pipeline** — `scripts/build-app.sh` + `scripts/build-dmg.sh` produce `dist/Pebble.app` and a drag-to-Applications DMG, adhoc-signed for local distribution. Apple Developer ID + notarization deferred until the project has real users.

Bundle ID `com.iamcorey.pebble`, min macOS 14 (Sonoma — `@Observable` is the floor). 31-test XCTest suite.
