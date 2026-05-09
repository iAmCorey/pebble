import AppKit
import Foundation
import SwiftUI

/// A named profile that turns into a `TerminalSessionConfig` when the user
/// picks it from the "+" menu. The shell starts under our wrapper `.zshrc`
/// (PebbleShellIntegration), which sources the user's config, then — if
/// `PEBBLE_AGENT` is set — invokes the agent inline. The user never sees the
/// shell prompt or the command echo, and on agent exit they land in a clean
/// shell prompt with their full PATH/aliases intact.
struct AgentTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    /// SF Symbol used when `iconAsset` is nil or fails to load.
    let symbol: String
    /// Filename (without extension) of a bundled PNG in `Resources/Icons/`.
    /// Sourced from github.com/lobehub/lobe-icons (MIT).
    let iconAsset: String?
    /// Brand-derived hue used for compact indicators (sidebar status pips).
    /// Picked from each lobe-icon's dominant fill so a row's pip group reads as
    /// the same family of marks shown elsewhere. sRGB hex.
    let tintHex: String?
    let initialCommand: String?

    var tint: Color? {
        tintHex.flatMap(Color.init(hex:))
    }

    func makeSessionConfig() -> TerminalSessionConfig {
        // Pick a shell that has a pebble integration wrapper. Plain terminal
        // sessions respect $SHELL where we have a wrapper (zsh/bash); other
        // shells (fish/nu/...) get $SHELL too, just without cwd tracking.
        // Agent sessions force a wrapped shell so PEBBLE_AGENT auto-launch
        // works — `.other` users get zsh as a working fallback.
        var config: TerminalSessionConfig
        switch (PebbleShellIntegration.detectedUserShell, initialCommand) {
        case (.bash, _):
            config = .bashShell(launcher: PebbleShellIntegration.bashLauncherPath)
        case (.zsh, _):
            config = .zshShell()
        case (.other, .none):
            config = .defaultShell()
        case (.other, .some):
            config = .zshShell()
        }
        if let initialCommand { config.environment["PEBBLE_AGENT"] = initialCommand }
        return config
    }
}

extension AgentTemplate {
    static let terminal = AgentTemplate(
        id: "terminal",
        title: "Terminal",
        symbol: "terminal",
        iconAsset: nil,
        tintHex: nil,
        initialCommand: nil
    )

    static let claudeCode = AgentTemplate(
        id: "claude-code",
        title: "Claude Code",
        symbol: "sparkle",
        iconAsset: "claudecode",
        tintHex: "D97757",
        initialCommand: "claude"
    )

    static let codex = AgentTemplate(
        id: "codex",
        title: "Codex",
        symbol: "chevron.left.forwardslash.chevron.right",
        iconAsset: "codex",
        tintHex: "7A9DFF",
        initialCommand: "codex"
    )

    static let gemini = AgentTemplate(
        id: "gemini",
        title: "Gemini CLI",
        symbol: "diamond",
        iconAsset: "gemini",
        tintHex: "3186FF",
        initialCommand: "gemini"
    )

    static let opencode = AgentTemplate(
        id: "opencode",
        title: "OpenCode",
        symbol: "curlybraces",
        iconAsset: "opencode",
        tintHex: "B0B0B0",
        initialCommand: "opencode"
    )

    static let amp = AgentTemplate(
        id: "amp",
        title: "Amp",
        symbol: "bolt.fill",
        iconAsset: "amp",
        tintHex: "E8B168",
        initialCommand: "amp"
    )

    static let all: [AgentTemplate] = [.terminal, .claudeCode, .codex, .gemini, .opencode, .amp]

    /// Looks up a template from the short slug an agent's hook system reports
    /// (`claude` / `codex` / `gemini` / `opencode` / `amp`). The slug is what
    /// the user types to launch the CLI — we keyed `initialCommand` to it.
    static func from(hookSlug: String) -> AgentTemplate? {
        all.first { $0.initialCommand == hookSlug }
    }
}
