import AppKit
import SwiftUI

/// Namespace for the View menu's Tab/Workspace switch items. Tags share a
/// single integer field on `NSMenuItem`, so we partition them: 1...9 for tabs
/// (matching ⌘N), 101...109 for workspaces (⌥⌘N). The 100 offset keeps both
/// sets identifiable from `menuNeedsUpdate`.
private enum MenuTag {
    static let tabRange = 1...9
    static let workspaceRange = 101...109
    static func tab(_ n: Int) -> Int { n }
    static func workspace(_ n: Int) -> Int { 100 + n }
    static func tabIndex(from tag: Int) -> Int { tag - 1 }
    static func workspaceIndex(from tag: Int) -> Int { tag - 101 }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    let store = WorkspaceStore()
    private lazy var hookServer = HookServer { [weak store] agent, event, sessionId in
        store?.applyHookEvent(agent: agent, event: event, sessionId: sessionId)
    }


    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        PebbleFonts.registerOnce()
        PebbleShellIntegration.installAgentHooks()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = PebbleApp.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Tab strips sit under the transparent titlebar; let only our explicit
        // sidebar handle move the window so tab DnD never races AppKit.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        // Force dark chrome regardless of system appearance — the terminal
        // surface and our sidebar are always dark, and SwiftUI's .primary /
        // .secondary need a dark context to resolve to readable colors.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMainMenu()
        hookServer.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        store.flushPersistence()
        hookServer.stop()
        PebbleShellIntegration.cleanup()
    }

    // MARK: - Menu

    /// Builds the menu bar at app launch. Keyboard shortcuts route through
    /// NSMenu first, so they fire even though `GhosttySurfaceView.keyDown`
    /// captures every other key — the menu system gets first dibs on `⌘x`
    /// before keyDown sees the event.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu — system-routed selectors via the responder chain. About
        // routes to our own handler so we can populate the panel without a
        // bundled Info.plist (the responder-chain default reads from there).
        mainMenu.addItem(submenu(buildMenu(title: PebbleApp.name, entries: [
            selfRow("About \(PebbleApp.name)", #selector(handleAbout)),
            .separator,
            responderRow("Hide \(PebbleApp.name)", #selector(NSApplication.hide(_:)), "h"),
            responderRow("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            responderRow("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            responderRow("Quit \(PebbleApp.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])))

        mainMenu.addItem(submenu(buildMenu(title: "File", entries: [
            selfRow("New Tab", #selector(handleNewTab), "t"),
            selfRow("New Workspace", #selector(handleNewWorkspace), "n"),
            .separator,
            selfRow("Close Tab", #selector(handleCloseTab), "w"),
            selfRow("Close Workspace", #selector(handleCloseWorkspace), "w", modifiers: [.command, .shift]),
        ])))

        // Edit menu — first-responder selectors so libghostty's NSResponder
        // implementation handles copy/paste inside the surface.
        mainMenu.addItem(submenu(buildMenu(title: "Edit", entries: [
            responderRow("Cut", #selector(NSText.cut(_:)), "x"),
            responderRow("Copy", #selector(NSText.copy(_:)), "c"),
            responderRow("Paste", #selector(NSText.paste(_:)), "v"),
            responderRow("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            selfRow("Find…", #selector(handleFind), "f"),
            selfRow("Find Next", #selector(handleFindNext), "g"),
            selfRow("Find Previous", #selector(handleFindPrevious), "g", modifiers: [.command, .shift]),
        ])))

        let tabSwitchRows: [MenuEntry] = MenuTag.tabRange.map { n in
            selfRow("Tab \(n)", #selector(handleSwitchTab(_:)), "\(n)", tag: MenuTag.tab(n))
        }
        let workspaceSwitchRows: [MenuEntry] = (1...9).map { n in
            selfRow("Workspace \(n)", #selector(handleSwitchWorkspace(_:)), "\(n)",
                    modifiers: [.command, .option], tag: MenuTag.workspace(n))
        }
        let viewEntries: [MenuEntry] = [
            selfRow("Toggle Sidebar", #selector(handleToggleSidebar), "s", modifiers: [.command, .control]),
            .separator,
            selfRow("Increase Font Size", #selector(handleIncreaseFontSize), "="),
            selfRow("Decrease Font Size", #selector(handleDecreaseFontSize), "-"),
            selfRow("Default Font Size", #selector(handleResetFontSize), "0"),
            .separator,
            selfRow("Clear Pane", #selector(handleClearScrollback), "k"),
            .separator,
            // Arrow function-keys via NSEvent's specialKey codepoints — AppKit
            // renders them as ↑/↓ glyphs in the menu. Routed through libghostty
            // bindings so the engine is the single source of truth on what
            // counts as a prompt boundary.
            selfRow("Jump to Previous Prompt", #selector(handleJumpToPreviousPrompt), "\u{F700}"),
            selfRow("Jump to Next Prompt", #selector(handleJumpToNextPrompt), "\u{F701}"),
            .separator,
            selfRow("Split Right", #selector(handleSplitRight), "d"),
            selfRow("Split Down", #selector(handleSplitDown), "d", modifiers: [.command, .shift]),
            selfRow("Focus Previous Pane", #selector(handleFocusPreviousPane), "["),
            selfRow("Focus Next Pane", #selector(handleFocusNextPane), "]"),
            .separator,
        ]
        + tabSwitchRows
        + [.separator]
        + workspaceSwitchRows
        + [
            .separator,
            responderRow("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]),
        ]
        let viewMenu = buildMenu(title: "View", entries: viewEntries)
        viewMenu.delegate = self
        mainMenu.addItem(submenu(viewMenu))

        let windowMenu = buildMenu(title: "Window", entries: [
            responderRow("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            responderRow("Zoom", #selector(NSWindow.performZoom(_:))),
            selfRow("Center", #selector(handleCenterWindow)),
        ])
        mainMenu.addItem(submenu(windowMenu))

        #if DEBUG
        mainMenu.addItem(submenu(buildMenu(title: "Debug", entries: [
            selfRow("Cycle Activity", #selector(handleCycleActivity), "a", modifiers: [.command, .shift]),
        ])))
        #endif

        let helpMenu = buildMenu(title: "Help", entries: [
            selfRow("Report an Issue", #selector(handleOpenIssues)),
            selfRow("View on GitHub", #selector(handleOpenRepo)),
        ])
        mainMenu.addItem(submenu(helpMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Menu DSL

    private struct MenuRow {
        let title: String
        let selector: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let target: AnyObject?
        let tag: Int
    }

    private enum MenuEntry {
        case row(MenuRow)
        case separator
    }

    /// Item routed to `self` — used for the AppDelegate's own `handle*`
    /// methods that need a concrete target.
    private func selfRow(_ title: String, _ selector: Selector, _ key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> MenuEntry {
        .row(MenuRow(title: title, selector: selector, key: key,
                     modifiers: modifiers, target: self, tag: tag))
    }

    /// Item with `target: nil` — AppKit dispatches via the responder chain.
    /// Used for system selectors like `NSWindow.performZoom(_:)` and
    /// `NSText.cut(_:)`, which let libghostty / the active window handle them.
    private func responderRow(_ title: String, _ selector: Selector, _ key: String = "",
                              modifiers: NSEvent.ModifierFlags = .command) -> MenuEntry {
        .row(MenuRow(title: title, selector: selector, key: key,
                     modifiers: modifiers, target: nil, tag: 0))
    }

    private func buildMenu(title: String, entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case .row(let row):
                let item = NSMenuItem(title: row.title, action: row.selector, keyEquivalent: row.key)
                item.keyEquivalentModifierMask = row.modifiers
                item.target = row.target
                item.tag = row.tag
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        // AppKit's menu bar renders the menu item's own title — submenu.title
        // isn't used as a fallback. An empty title degrades to "NSMenuItem"
        // in the bar, so copy the submenu's title across.
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    // MARK: - Menu actions

    @objc private func handleNewTab() {
        guard let workspace = store.active else { return }
        store.addTab(in: workspace)
    }

    @objc private func handleNewWorkspace() {
        store.addWorkspace()
    }

    @objc private func handleCloseTab() {
        guard let workspace = store.active, let session = workspace.activeSession else { return }
        store.closeTab(session, in: workspace)
    }

    @objc private func handleSplitRight() {
        guard let workspace = store.active, let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .horizontal, in: workspace)
    }

    @objc private func handleSplitDown() {
        guard let workspace = store.active, let pane = workspace.activePane else { return }
        store.splitPane(pane, orientation: .vertical, in: workspace)
    }

    @objc private func handleFocusNextPane() {
        cyclePaneFocus(forward: true)
    }

    @objc private func handleFocusPreviousPane() {
        cyclePaneFocus(forward: false)
    }

    private func cyclePaneFocus(forward: Bool) {
        guard let workspace = store.active else { return }
        let panes = workspace.root.allPanes
        guard panes.count > 1 else { return }
        let currentId = workspace.activePaneId ?? panes.first?.id
        let idx = panes.firstIndex(where: { $0.id == currentId }) ?? 0
        let nextIdx = forward ? (idx + 1) % panes.count : (idx - 1 + panes.count) % panes.count
        store.focusPane(panes[nextIdx], in: workspace)
    }

    @objc private func handleCloseWorkspace() {
        guard let workspace = store.active else { return }
        store.closeWorkspace(workspace)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Hidden NSMenuItems don't fire their keyEquivalents — pressing ⌘5
        // with 3 tabs is a no-op, matching what the menu shows.
        let tabCount = store.active?.activePane?.tabs.count ?? 0
        let workspaceCount = store.workspaces.count
        for item in menu.items {
            if MenuTag.tabRange.contains(item.tag) {
                item.isHidden = item.tag > tabCount
            } else if MenuTag.workspaceRange.contains(item.tag) {
                item.isHidden = MenuTag.workspaceIndex(from: item.tag) >= workspaceCount
            }
        }
    }

    @objc private func handleIncreaseFontSize() {
        store.active?.activeSession?.engine.performAction("increase_font_size:1")
    }

    @objc private func handleDecreaseFontSize() {
        store.active?.activeSession?.engine.performAction("decrease_font_size:1")
    }

    @objc private func handleResetFontSize() {
        store.active?.activeSession?.engine.performAction("reset_font_size")
    }

    @objc private func handleClearScrollback() {
        store.active?.activeSession?.engine.performAction("clear_screen")
    }

    @objc private func handleJumpToPreviousPrompt() {
        store.active?.activeSession?.engine.performAction("jump_to_prompt:-1")
    }

    @objc private func handleJumpToNextPrompt() {
        store.active?.activeSession?.engine.performAction("jump_to_prompt:1")
    }

    @objc private func handleFind() {
        guard let session = store.active?.activeSession else { return }
        // ⌘F is a toggle on the active tab. Search state is per-session, so
        // ⌘F in pane A doesn't affect pane B's open search bar — both can
        // be active simultaneously, each with their own needle / count.
        if session.searchActive {
            session.engine.performAction("end_search")
        } else {
            session.engine.performAction("start_search")
        }
    }

    @objc private func handleFindNext() {
        store.active?.activeSession?.engine.performAction("navigate_search:next")
    }

    @objc private func handleFindPrevious() {
        store.active?.activeSession?.engine.performAction("navigate_search:previous")
    }

    @objc private func handleToggleSidebar() {
        withAnimation(Theme.chromeTransition) {
            store.setSidebarMode(store.sidebarMode.next)
        }
    }

    @objc private func handleAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: PebbleApp.name,
            .applicationVersion: PebbleApp.displayVersion,
            .credits: aboutCredits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private var aboutCredits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "\(PebbleApp.tagline)\n\n", attributes: body)
        credits.append(NSAttributedString(
            string: PebbleApp.repositoryDisplay,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .link: PebbleApp.repositoryURL,
                .paragraphStyle: centered,
            ]
        ))
        credits.append(NSAttributedString(
            string: "\n\n\(PebbleApp.copyrightLine)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centered,
            ]
        ))
        return credits
    }

    @objc private func handleOpenIssues() {
        NSWorkspace.shared.open(PebbleApp.issuesURL)
    }

    @objc private func handleOpenRepo() {
        NSWorkspace.shared.open(PebbleApp.repositoryURL)
    }

    @objc private func handleCenterWindow() {
        // NSWindow.center() takes no sender arg, so it can't be a direct
        // first-responder selector — wrap it.
        NSApp.keyWindow?.center()
    }

    @objc private func handleSwitchTab(_ sender: NSMenuItem) {
        let index = MenuTag.tabIndex(from: sender.tag)
        guard let workspace = store.active,
              let pane = workspace.activePane,
              index >= 0, index < pane.tabs.count else { return }
        store.activateTab(pane.tabs[index], in: workspace)
    }

    @objc private func handleSwitchWorkspace(_ sender: NSMenuItem) {
        let index = MenuTag.workspaceIndex(from: sender.tag)
        guard index >= 0, index < store.workspaces.count else { return }
        store.activateWorkspace(store.workspaces[index])
    }

    #if DEBUG
    /// Cycles through every dot state in precedence order: idle → running
    /// → failure → attention → idle. Used to preview the dot palette without
    /// running real agents / commands.
    @objc private func handleCycleActivity() {
        guard let session = store.active?.activeSession else { return }
        let isFailure = session.lastCommandExit.map { $0 != 0 } ?? false
        switch (session.activityState, isFailure) {
        case (.idle, false):
            session.activityState = .running
        case (.running, _):
            session.activityState = .idle
            session.lastCommandExit = 1
            session.lastCommandDuration = 0.42
        case (.idle, true):
            session.activityState = .attention
        case (.attention, _):
            session.activityState = .idle
            session.lastCommandExit = nil
            session.lastCommandDuration = nil
        }
    }
    #endif
}
