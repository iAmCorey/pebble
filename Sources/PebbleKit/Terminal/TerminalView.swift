import AppKit
import SwiftUI

struct TerminalView: NSViewRepresentable {
    let engine: any TerminalEngine

    func makeNSView(context: Context) -> NSView {
        engine.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
