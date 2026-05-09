import SwiftUI

struct TabBarItem: View {
    @Bindable var tab: Session
    let isActive: Bool
    let canCloseToRight: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onSplit: (SplitOrientation) -> Void

    @State private var isHovered = false
    @State private var isContextMenuOpen = false
    @State private var isRenameOpen = false
    @State private var pendingRename = ""

    var body: some View {
        HStack(spacing: 7) {
            commandStatusDot
            AgentIconView(asset: tab.agent.iconAsset, fallbackSymbol: tab.agent.symbol, size: 15)
            Text(tab.title)
                .font(Theme.display(12, weight: .regular))
                .lineLimit(1)
            HoverableIconButton(
                systemName: "xmark",
                fontSize: 9,
                size: 16,
                help: "Close tab",
                action: onClose
            )
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
        }
        .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.6))
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 7)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                PebbleMenuRow(title: "Close Tab", shortcut: "⌘W") {
                    isContextMenuOpen = false
                    onClose()
                }
                PebbleMenuRow(title: "Close Other Tabs") {
                    isContextMenuOpen = false
                    onCloseOthers()
                }
                PebbleMenuRow(title: "Close Tabs to the Right", isDisabled: !canCloseToRight) {
                    isContextMenuOpen = false
                    onCloseToRight()
                }
                PebbleMenuDivider()
                PebbleMenuRow(title: "Split Right", shortcut: "⌘D") {
                    isContextMenuOpen = false
                    onSplit(.horizontal)
                }
                PebbleMenuRow(title: "Split Down", shortcut: "⌘⇧D") {
                    isContextMenuOpen = false
                    onSplit(.vertical)
                }
                PebbleMenuDivider()
                PebbleMenuRow(title: "Rename Tab…") {
                    isContextMenuOpen = false
                    pendingRename = tab.customTitle ?? tab.title
                    // Defer one runloop tick so the context popover finishes
                    // dismissing before the rename popover anchors — back-to-back
                    // popovers off the same view glitch otherwise.
                    DispatchQueue.main.async { isRenameOpen = true }
                }
                PebbleMenuRow(title: "Duplicate Tab") {
                    isContextMenuOpen = false
                    onDuplicate()
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .popover(isPresented: $isRenameOpen, arrowEdge: .bottom) {
            PebbleRenameField(placeholder: "Tab title", text: $pendingRename) {
                onRename(pendingRename)
                isRenameOpen = false
            }
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.chromeActive }
        if isHovered { return Theme.chromeHover }
        return .clear
    }

    /// Shows only on non-zero exit. Successful runs intentionally leave the
    /// row clean — a green dot on every command would dominate the chrome.
    @ViewBuilder
    private var commandStatusDot: some View {
        if let exit = tab.lastCommandExit, exit != 0 {
            Circle()
                .fill(Theme.activityFailure)
                .frame(width: 5, height: 5)
                .help(Self.statusTooltip(exit: exit, duration: tab.lastCommandDuration))
        }
    }

    private static func statusTooltip(exit: Int, duration: TimeInterval?) -> String {
        guard let duration else { return "exit \(exit)" }
        return "exit \(exit) · \(formatDuration(duration))"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let rem = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
        return "\(minutes)m \(rem)s"
    }
}
