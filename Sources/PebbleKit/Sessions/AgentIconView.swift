import AppKit
import SwiftUI

/// Loader for the bundled lobe-icons PNGs. Chosen over SVG because Apple's
/// CoreSVG renderer mis-parses lobe's compact arc-flag form (gemini-color is
/// the canonical victim) and the 640×640 PNGs are plenty for tab/menu usage.
///
/// Cached because `AgentIconView.body` calls this on every SwiftUI re-render
/// (hover, scroll, OSC 7 push) — without the cache each call paid a stat +
/// PNG decode.
@MainActor
enum AgentIcon {
    private static var cache: [String: NSImage] = [:]

    /// NSImage with a 16×16 logical size suitable for SwiftUI menu items
    /// (`Image(nsImage:)` in a `Label` bridges to `NSMenuItem.image`, which
    /// uses `image.size` to lay out the menu row). Pixel data stays at 640×640
    /// so SwiftUI `.resizable()` callers still render sharp at any frame size.
    static func nsImage(asset: String) -> NSImage? {
        if let hit = cache[asset] { return hit }
        guard let url = bundleResourceURL(name: asset, ext: "png", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        cache[asset] = image
        return image
    }
}

struct AgentIconView: View {
    let asset: String?
    let fallbackSymbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let asset, let image = AgentIcon.nsImage(asset: asset) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}
