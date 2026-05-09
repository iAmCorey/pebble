import AppKit

struct TerminalSessionConfig {
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]

    static func defaultShell() -> TerminalSessionConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? PebbleShellIntegration.zshPath
        return TerminalSessionConfig(command: shell, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Pinned zsh — pairs with the ZDOTDIR wrapper for PEBBLE_AGENT + OSC 7.
    static func zshShell() -> TerminalSessionConfig {
        TerminalSessionConfig(command: PebbleShellIntegration.zshPath, arguments: ["--login"], workingDirectory: nil, environment: [:])
    }

    /// Bash via launcher script — direct `--rcfile` flags don't work because
    /// libghostty makes every `command` a login shell, which strips
    /// `--rcfile` semantics. Launcher re-execs as interactive non-login.
    static func bashShell(launcher: String) -> TerminalSessionConfig {
        TerminalSessionConfig(command: launcher, arguments: [], workingDirectory: nil, environment: [:])
    }
}

@MainActor
protocol TerminalEngine: AnyObject {
    var view: NSView { get }
    var backgroundColor: NSColor { get }
    /// Called when the engine observes a working-directory change (libghostty's
    /// `GHOSTTY_ACTION_PWD`, fired when the shell emits OSC 7). Lets the
    /// workspace track the active tab's cwd so new tabs inherit the latest path.
    var onPwdChange: ((String) -> Void)? { get set }
    /// Called when this engine's surface becomes the window's first responder
    /// (i.e. the user clicked into it). Lets the workspace mark the matching
    /// leaf as focused so split-aware operations (cwd tracking, ⌘D inheritance)
    /// follow the visually-active pane.
    var onFocus: (() -> Void)? { get set }
    /// Called when libghostty sees `OSC 133;D` from the shell — the
    /// most-recent command's exit code and run duration. `exitCode` is `nil`
    /// when the shell omitted it from the OSC sequence.
    var onCommandFinished: ((Int?, TimeInterval) -> Void)? { get set }
    /// Search lifecycle from libghostty's `start_search` / `end_search` /
    /// `navigate_search` keybinds. While `onSearchStart` is the most recent
    /// signal, libghostty owns the input loop and reports the current needle
    /// + total / selected match index back through these callbacks. The UI
    /// is a passive mirror — pebble doesn't push the needle string itself.
    var onSearchStart: ((String) -> Void)? { get set }
    var onSearchEnd: (() -> Void)? { get set }
    var onSearchTotal: ((Int) -> Void)? { get set }
    var onSearchSelected: ((Int) -> Void)? { get set }
    func start(config: TerminalSessionConfig)
    func terminate()
    /// Trigger a libghostty named action (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`, `clear_screen`). Returns
    /// `true` when the engine recognised and dispatched the action.
    @discardableResult
    func performAction(_ name: String) -> Bool
}
