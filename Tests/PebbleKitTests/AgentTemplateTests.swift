import XCTest
@testable import PebbleKit

final class AgentTemplateTests: XCTestCase {
    func testTerminalTemplateHasNoAgentEnv() {
        XCTAssertNil(AgentTemplate.terminal.makeSessionConfig().environment["PEBBLE_AGENT"])
    }

    func testAgentTemplatesPublishPebbleAgentEnv() {
        XCTAssertEqual(AgentTemplate.claudeCode.makeSessionConfig().environment["PEBBLE_AGENT"], "claude")
        XCTAssertEqual(AgentTemplate.codex.makeSessionConfig().environment["PEBBLE_AGENT"], "codex")
        XCTAssertEqual(AgentTemplate.gemini.makeSessionConfig().environment["PEBBLE_AGENT"], "gemini")
        XCTAssertEqual(AgentTemplate.opencode.makeSessionConfig().environment["PEBBLE_AGENT"], "opencode")
        XCTAssertEqual(AgentTemplate.amp.makeSessionConfig().environment["PEBBLE_AGENT"], "amp")
    }

    func testAllTemplatesAreUniqueAndIncludeTerminal() {
        let ids = AgentTemplate.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        XCTAssertTrue(ids.contains("terminal"))
    }

    func testTerminalTemplateUsesUserDefaultShell() {
        let expected = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        XCTAssertEqual(AgentTemplate.terminal.makeSessionConfig().command, expected)
    }

    func testAgentTemplatesPickAShellWithIntegrationWrapper() {
        // Agent must run under one of our wrappers (zsh ZDOTDIR or bash
        // --rcfile) — anything else means PEBBLE_AGENT never fires.
        for template in [AgentTemplate.claudeCode, .codex, .gemini, .opencode, .amp] {
            let cmd = template.makeSessionConfig().command
            XCTAssertTrue(
                cmd == "/bin/zsh" || cmd.contains("pebble-bash-launch-"),
                "agent template \(template.id) launched without a pebble shell wrapper: \(cmd)"
            )
        }
    }
}
