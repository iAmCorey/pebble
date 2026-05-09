import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            HStack(spacing: 0) {
                if store.sidebarMode != .hidden {
                    SidebarView(store: store)
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                }
                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(chromeBackground)
        .ignoresSafeArea(.all)
        .onChange(of: store.workspaces.isEmpty) { _, isEmpty in
            if isEmpty { NSApplication.shared.keyWindow?.close() }
        }
    }

    /// Top 32pt strip. `window.isMovable = false` is set globally, so this
    /// `WindowDragHandle` is the only place AppKit allows window dragging.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 82).allowsHitTesting(false)
            HoverableIconButton(
                systemName: "sidebar.left",
                fontSize: 12,
                size: 28,
                help: sidebarTooltip
            ) {
                withAnimation(Theme.chromeTransition) {
                    store.setSidebarMode(store.sidebarMode.next)
                }
            }
            WindowDragHandle()
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private var mainPane: some View {
        if let workspace = store.active {
            PaneTreeView(node: workspace.root, workspace: workspace, store: store)
                .id(workspace.id)
        } else {
            Color.clear
        }
    }

    private var chromeBackground: Color {
        let color = store.active?.activeSession?.engine.backgroundColor ?? Theme.terminalSurface
        return Color(nsColor: color)
    }

    private var sidebarTooltip: String {
        switch store.sidebarMode {
        case .full: return "Compact sidebar"
        case .compact: return "Hide sidebar"
        case .hidden: return "Show sidebar"
        }
    }
}
