import Foundation

@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    /// Project root. New tabs spawn here; the active pane's active tab's OSC 7
    /// reports keep this in sync — `cd` in any visible terminal updates the
    /// workspace, the next new pane / tab inherits the latest path.
    var workingDirectory: URL
    /// Single split tree per workspace. Always non-nil; a fresh workspace
    /// holds one Pane with one Session.
    var root: PaneNode
    /// Currently focused leaf-pane id. Splits/closes update this so cwd
    /// tracking and ⌘D act on what the user is looking at.
    var activePaneId: UUID?
    /// Empty / whitespace input via `renameWorkspace` clears this back to
    /// `nil` so the sidebar label resumes tracking the cwd.
    var customTitle: String? = nil

    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if workingDirectory.path == NSHomeDirectory() { return "Home" }
        let last = workingDirectory.lastPathComponent
        return last.isEmpty ? workingDirectory.path : last
    }

    var activePane: Pane? {
        if let id = activePaneId, let pane = root.pane(id: id) { return pane }
        return root.firstPane
    }

    var activeSession: Session? { activePane?.activeTab }

    /// Distinct non-terminal agents and aggregated activity, computed in a
    /// single tree walk. Sidebar reads all three per render. The walk runs
    /// to completion (no short-circuit) so each field reflects the whole
    /// tree — short-circuiting on attention previously left `hasFailure`
    /// false when a sibling pane held a non-zero exit.
    var sidebarReadout: (agents: [AgentTemplate], state: SessionActivityState, hasCommandFailure: Bool) {
        var seen: Set<String> = []
        var agents: [AgentTemplate] = []
        var state: SessionActivityState = .idle
        var hasFailure = false
        walk(root) { pane in
            for tab in pane.tabs {
                if tab.agent.id != AgentTemplate.terminal.id, !seen.contains(tab.agent.id) {
                    seen.insert(tab.agent.id)
                    agents.append(tab.agent)
                }
                if let exit = tab.lastCommandExit, exit != 0 { hasFailure = true }
                switch tab.activityState {
                case .attention: state = .attention
                case .running where state != .attention: state = .running
                default: break
                }
            }
        } shouldStop: { false }
        return (agents, state, hasFailure)
    }

    var distinctAgents: [AgentTemplate] { sidebarReadout.agents }
    var activityState: SessionActivityState { sidebarReadout.state }
    /// True when any tab's last command exited non-zero. Sidebar uses this
    /// (with attention > failure > running > idle precedence) so a
    /// background-pane failure surfaces at the workspace level too.
    var hasCommandFailure: Bool { sidebarReadout.hasCommandFailure }

    private func walk(_ node: PaneNode, visit: (Pane) -> Void, shouldStop: () -> Bool) {
        switch node.content {
        case .pane(let p):
            visit(p)
        case .split(_, let a, let b, _):
            walk(a, visit: visit, shouldStop: shouldStop)
            if shouldStop() { return }
            walk(b, visit: visit, shouldStop: shouldStop)
        }
    }

    init(id: UUID = UUID(), workingDirectory: URL, root: PaneNode) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.root = root
        self.activePaneId = root.firstPane?.id
    }
}
