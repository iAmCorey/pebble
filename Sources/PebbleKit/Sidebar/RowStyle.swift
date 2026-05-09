import SwiftUI

/// Shared row background palette for sidebar / tab / popover-menu rows.
/// Centralizes the hover/active alpha values so a future theme toggle has one
/// place to change.
extension View {
    func hoverableRowBackground(isActive: Bool = false, isHovered: Bool) -> some View {
        let color: Color
        if isActive {
            color = Color.white.opacity(0.10)
        } else if isHovered {
            color = Color.white.opacity(0.05)
        } else {
            color = .clear
        }
        return background(color)
    }

    /// Menu rows are single-state: hover === selected, so they use the active
    /// alpha (0.10) instead of the lighter hover (0.05).
    func menuRowHover(_ isHovered: Bool) -> some View {
        background(isHovered ? Color.white.opacity(0.10) : Color.clear)
    }
}

/// One row in a pebble popover menu — tab right-click, "+" agent menu, etc.
/// Shares hover treatment + typography with the rest of the chrome.
/// Optional `shortcut` renders right-aligned in the same monospace style
/// AppKit uses for native NSMenuItem key equivalents (e.g. "⌘W", "⌘⇧D").
struct PebbleMenuRow<Leading: View>: View {
    let title: String
    let shortcut: String?
    let isDisabled: Bool
    let leading: Leading
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        @ViewBuilder leading: () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.isDisabled = isDisabled
        self.leading = leading()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.space2) {
                leading
                Text(title)
                    .font(Theme.display(12.5, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.chromeMuted : Theme.chromeForeground)
                Spacer(minLength: 0)
                if let shortcut {
                    // System font (SF Pro) — the ⌘⇧⌥⌃ glyphs are designed for
                    // it; in JetBrains Mono they render heavier and off-baseline,
                    // which looks alien next to the row title.
                    Text(shortcut)
                        .font(.system(size: 11.5, weight: .regular))
                        .tracking(0.5)
                        .foregroundStyle(isDisabled ? Theme.chromeMuted.opacity(0.6) : Theme.chromeMuted)
                        .padding(.leading, Theme.space2)
                }
            }
            .padding(.horizontal, Theme.space2 + 2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuRowHover(isHovered && !isDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 && !isDisabled }
    }
}

extension PebbleMenuRow where Leading == EmptyView {
    init(
        title: String,
        shortcut: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            shortcut: shortcut,
            isDisabled: isDisabled,
            leading: { EmptyView() },
            action: action
        )
    }
}

extension View {
    /// 2pt drop-target indicator anchored to one edge of the view, animated on
    /// the `active` toggle. Used by reorder gestures (sidebar workspaces, tab
    /// pills, the trailing `+` button) to show "drop will land here".
    /// `offset` nudges the line into a visual gap between sibling views.
    /// `length` only applies to horizontal-axis (leading/trailing) edges.
    func dropIndicator(active: Bool, on edge: Alignment, offset: CGFloat = 0, length: CGFloat = 22) -> some View {
        let isVertical = edge == .top || edge == .bottom
        return overlay(alignment: edge) {
            let color = Theme.chromeForeground.opacity(active ? 0.55 : 0)
            if isVertical {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 2, height: length)
                    .offset(x: offset)
                    .animation(.easeOut(duration: 0.12), value: active)
            }
        }
    }
}

struct PebbleMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.chromeHairline)
            .frame(height: 1)
            .padding(.vertical, 3)
            .padding(.horizontal, Theme.space2)
    }
}

/// Shared rename-popover body used by tab + workspace rename. Both render
/// inside `.popover` modifiers anchored to their own row; the caller picks
/// the arrowEdge so the popover points the right way.
struct PebbleRenameField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.display(13))
            .foregroundStyle(Theme.chromeForeground)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2 + 2)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
            .onSubmit(onSubmit)
    }
}
