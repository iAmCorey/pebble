import AppKit
import SwiftUI

/// Right-click detector designed to sit in `.overlay()` above SwiftUI content.
/// Its `hitTest` returns `self` only for secondary-mouse events, so left
/// clicks/hovers pass through to the SwiftUI gestures behind it.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: SecondaryClickView, context: Context) {
        nsView.action = action
    }

    final class SecondaryClickView: NSView {
        var action: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type else { return nil }
            switch type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return bounds.contains(point) ? self : nil
            default:
                return nil
            }
        }
    }
}
