import AppKit
import SwiftUI

/// Design tokens for pebble's chrome — refined minimal, low-contrast palette,
/// generous rhythm. Terminal content (libghostty) renders independently.
enum Theme {
    // MARK: Colors
    // Slightly cooler than One Dark; sits ~1 step deeper than terminal #282C34
    // so the chrome reads as background and the surface stays the focal plane.
    static let chromeBackground = Color(nsColor: NSColor(srgbRed: 0x1B / 255, green: 0x1D / 255, blue: 0x22 / 255, alpha: 1))
    static let chromeForeground = Color(nsColor: NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xF1 / 255, alpha: 1))
    static let chromeMuted = Color(nsColor: NSColor(srgbRed: 0x93 / 255, green: 0x95 / 255, blue: 0x9C / 255, alpha: 1))
    static let chromeFaint = Color(nsColor: NSColor(srgbRed: 0x5C / 255, green: 0x5E / 255, blue: 0x66 / 255, alpha: 1))
    static let chromeHairline = Color.white.opacity(0.05)
    static let chromeHover = Color.white.opacity(0.04)
    static let chromeActive = Color.white.opacity(0.08)

    /// Color libghostty draws inside the terminal surface (One Dark #282C34).
    /// Distinct from `chromeBackground` — the terminal owns its own canvas;
    /// chrome wraps it. Exposed as NSColor so AppKit code (engines, etc.)
    /// can reach it without bridging.
    static let terminalSurface = NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1)

    /// Activity-dot palette — one design token per signal so sidebar workspace
    /// rows and tab pills read identically. Hue picked for at-a-glance read:
    /// cool blue == "thinking", warm amber == "needs you", warm red == "look
    /// when free". Precedence (where multiple apply) is encoded by callers.
    static let activityRunning = Color(.sRGB, red: 0.41, green: 0.69, blue: 0.86, opacity: 1)
    static let activityAttention = Color(.sRGB, red: 0.91, green: 0.69, blue: 0.40, opacity: 1)
    static let activityFailure = Color(.sRGB, red: 0.91, green: 0.40, blue: 0.40, opacity: 1)

    // MARK: Fonts
    private static let displayName = "Onest"
    private static let monoName = "JetBrainsMono-Regular"

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(displayName, size: size).weight(weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        Font.custom(monoName, size: size)
    }

    // MARK: Spacing rhythm — multiples of 4. Use space3+ for chrome breathing.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24

    // MARK: Motion
    /// Standard transition for chrome state changes (sidebar collapse,
    /// drag-reorder commit). One source so timings can't drift across sites.
    static let chromeTransition: Animation = .easeInOut(duration: 0.2)
}

/// Registers bundled fonts at app launch via Core Text. SPM resources show up
/// in `Bundle.module`; CTFontManagerRegisterFontsForURL exposes them by family
/// name so SwiftUI's Font.custom("...") finds them.
@MainActor
enum PebbleFonts {
    static func registerOnce() {
        guard !registered else { return }
        registered = true
        for name in ["Onest", "JetBrainsMono-Regular"] {
            guard let url = bundleResourceURL(name: name, ext: "ttf", subdirectory: "Fonts") else {
                NSLog("pebble: missing font \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("pebble: font register failed for \(name): \(String(describing: error?.takeRetainedValue()))")
            }
        }
    }

    private static var registered = false
}

/// Replaces SPM's auto-generated `Bundle.module`, which `fatalError`s on
/// first access inside a `.app` (it only checks `Bundle.main.bundleURL` —
/// the .app root — but resources canonically ship in `Contents/Resources/`).
@MainActor
func bundleResourceURL(name: String, ext: String, subdirectory: String) -> URL? {
    let bundleName = "Pebble_PebbleKit"
    let candidates: [URL] = [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
    ].compactMap { $0?.appendingPathComponent("\(bundleName).bundle") }
    for candidate in candidates {
        guard let bundle = Bundle(url: candidate) else { continue }
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
    }
    return nil
}

extension Color {
    /// `Color(hex: "D97757")` or `Color(hex: "#D97757")`. Returns nil for
    /// malformed input so callers can fall back deterministically.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
