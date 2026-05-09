import SwiftUI

/// Recursive view for a workspace's split tree. Leaves render their own tab
/// strip + active terminal — cmux-style: a split slices the whole tab strip,
/// not just the content area.
struct PaneTreeView: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    var body: some View {
        switch node.content {
        case .pane(let pane):
            PaneView(
                pane: pane,
                workspace: workspace,
                store: store,
                isFocused: workspace.activePaneId == pane.id
            )
        case .split:
            SplitContainer(node: node, workspace: workspace, store: store)
        }
    }
}

private struct PaneView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane, workspace: workspace, store: store)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if let active = pane.activeTab {
                TerminalView(engine: active.engine)
                    .id(active.id)
                    .padding(8)
                    .overlay(alignment: .topTrailing) {
                        // Per-pane: multiple panes can search simultaneously,
                        // each with their own needle and result count.
                        if active.searchActive {
                            PaneSearchBar(
                                session: active,
                                onFocusGained: { store.activateTab(active, in: workspace) }
                            )
                            .padding(.top, Theme.space3)
                            .padding(.trailing, Theme.space3)
                        }
                    }
            } else {
                Color.clear
            }
        }
    }
}

private struct SplitContainer: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var dragStartFraction: Double?

    private static let dividerThickness: CGFloat = 1
    private static let handleHitSize: CGFloat = 6
    private static let minFraction: Double = 0.1
    private static let maxFraction: Double = 0.9

    var body: some View {
        guard case .split(let orientation, let first, let second, let fraction) = node.content else {
            return AnyView(EmptyView())
        }
        return AnyView(
            GeometryReader { geo in
                let total: CGFloat = orientation == .horizontal ? geo.size.width : geo.size.height
                let usable = max(total - Self.dividerThickness, 0)
                let firstSize = max(0, usable * fraction)
                let secondSize = max(0, usable - firstSize)
                let handleOffset = firstSize - Self.handleHitSize / 2 + Self.dividerThickness / 2

                ZStack(alignment: orientation == .horizontal ? .leading : .top) {
                    if orientation == .horizontal {
                        HStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(width: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(width: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(width: secondSize)
                        }
                        DividerHandle(orientation: .horizontal)
                            .frame(width: Self.handleHitSize, height: geo.size.height)
                            .offset(x: handleOffset, y: 0)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(height: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(height: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(height: secondSize)
                        }
                        DividerHandle(orientation: .vertical)
                            .frame(width: geo.size.width, height: Self.handleHitSize)
                            .offset(x: 0, y: handleOffset)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    }
                }
            }
        )
    }

    private func dragGesture(orientation: SplitOrientation, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard case .split(let orient, let f, let s, let current) = node.content else { return }
                if dragStartFraction == nil { dragStartFraction = current }
                let translation = orientation == .horizontal ? value.translation.width : value.translation.height
                let delta = total > 0 ? Double(translation) / Double(total) : 0
                let proposed = (dragStartFraction ?? current) + delta
                let clamped = min(max(proposed, Self.minFraction), Self.maxFraction)
                guard abs(clamped - current) > .ulpOfOne else { return }
                node.content = .split(orientation: orient, first: f, second: s, fraction: clamped)
            }
            .onEnded { _ in
                dragStartFraction = nil
                store.flushPersistence()
            }
    }
}

private struct DividerHandle: View {
    let orientation: SplitOrientation

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    if orientation == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}

/// Editable search field overlaying the active pane's terminal area.
/// Each keystroke pushes `search:<text>` to libghostty (the named action
/// that updates the needle and re-runs the search). Auto-focuses when
/// search activates so Esc / Enter route here instead of to the terminal
/// NSView. Lives in `PaneTreeView` because search state belongs visually
/// next to the content it filters — not in the global window chrome.
private struct PaneSearchBar: View {
    @Bindable var session: Session
    /// Called when the TextField gains focus so the parent can promote this
    /// pane to active. Without this, clicking a non-active pane's search bar
    /// leaves `WorkspaceStore.activePaneId` unchanged, and ⌘G / ⌘⇧G route
    /// `navigate_search` to the wrong session.
    let onFocusGained: () -> Void
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.chromeMuted)
            TextField("Search…", text: $needle)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeForeground)
                .focused($focused)
                .onChange(of: needle) { _, new in
                    // Persist the needle on the session so it survives a tab
                    // switch (which destroys this view; `onAppear` re-seeds
                    // from `session.searchNeedle`). libghostty's `START_SEARCH`
                    // action_cb writes the same field but only fires on initial
                    // start_search, not on per-keystroke updates.
                    session.searchNeedle = new
                    // `search:<text>` is libghostty's "update the search needle"
                    // action. Empty cancels matches but keeps the GUI open per
                    // libghostty's docs — we end_search explicitly on Esc / X.
                    session.engine.performAction("search:\(new)")
                }
                .onSubmit {
                    session.engine.performAction("navigate_search:next")
                }
                .onKeyPress(.escape) {
                    end()
                    return .handled
                }
            if session.searchTotal > 0 {
                Text(counterText)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(minWidth: 50, alignment: .trailing) // fits "999 / 999"
            }
            HoverableIconButton(systemName: "chevron.up", fontSize: 10, size: 20, help: "Previous match (⌘⇧G)") {
                session.engine.performAction("navigate_search:previous")
            }
            HoverableIconButton(systemName: "chevron.down", fontSize: 10, size: 20, help: "Next match (⌘G)") {
                session.engine.performAction("navigate_search:next")
            }
            HoverableIconButton(systemName: "xmark", fontSize: 10, size: 20, help: "End search (Esc)") {
                end()
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 5)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.chromeBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .onAppear {
            // Seed from libghostty's start-search needle so a future
            // `start_search:<text>` keybind (or selected-text seeding) carries
            // through to the visible TextField. Empty in the common case.
            needle = session.searchNeedle
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocusGained() }
        }
    }

    private func end() {
        focused = false
        session.engine.performAction("end_search")
    }

    /// "i / total" once the user has navigated to a specific match;
    /// the bare match count while libghostty's `selected = -1` (no current
    /// match highlighted yet).
    private var counterText: String {
        guard session.searchSelected >= 0 else { return "\(session.searchTotal)" }
        return "\(session.searchSelected + 1) / \(session.searchTotal)"
    }
}
