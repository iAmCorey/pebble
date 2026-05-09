import Foundation

/// Single source of truth for product metadata — surfaced by the About panel,
/// Help menu, and window title. Bump `displayVersion` on every release so the
/// About panel matches the latest CHANGELOG `vX.Y` tag.
enum PebbleApp {
    static let name = "pebble"
    static let displayVersion = "0.1.0"
    static let tagline = "A terminal built for the coding experience."
    static let author = "Corey Chiu"
    static let copyrightYear = "2026"
    static let license = "MIT"

    static let repositoryURL = URL(string: "https://github.com/iAmCorey/pebble")!
    static let issuesURL = URL(string: "https://github.com/iAmCorey/pebble/issues")!

    /// Schemeless form for display — derived from `repositoryURL` so a future
    /// URL change can't desync the user-visible string.
    static var repositoryDisplay: String {
        (repositoryURL.host ?? "") + repositoryURL.path
    }

    static var copyrightLine: String {
        "© \(copyrightYear) \(author) — \(license) licensed"
    }
}
