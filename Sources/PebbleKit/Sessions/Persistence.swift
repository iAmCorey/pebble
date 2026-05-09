import Foundation

/// On-disk shape of `WorkspaceStore`. Just the metadata — engine state
/// (scrollback, in-flight processes) can't survive PTY exit, so a restored
/// workspace re-spawns a fresh `LibghosttyEngine` per leaf and lands it in
/// the saved cwd via `TerminalSessionConfig.workingDirectory`.
struct PersistedState: Codable, Equatable {
    var workspaces: [PersistedWorkspace]
    var activeWorkspaceId: UUID?
    var sidebarMode: SidebarMode?
}

struct PersistedWorkspace: Codable, Equatable {
    var id: UUID
    var workingDirectoryPath: String
    var root: PersistedPaneNode
    var activePaneId: UUID?
    var customTitle: String?

    @MainActor
    init(_ ws: Workspace) {
        self.id = ws.id
        self.workingDirectoryPath = ws.workingDirectory.path
        self.root = PersistedPaneNode(ws.root)
        self.activePaneId = ws.activePaneId
        self.customTitle = ws.customTitle
    }

    init(id: UUID, workingDirectoryPath: String, root: PersistedPaneNode, activePaneId: UUID? = nil, customTitle: String? = nil) {
        self.id = id
        self.workingDirectoryPath = workingDirectoryPath
        self.root = root
        self.activePaneId = activePaneId
        self.customTitle = customTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id, workingDirectoryPath, root, activePaneId, customTitle
        // Legacy keys
        case tabs, activeTabId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try c.encode(root, forKey: .root)
        try c.encodeIfPresent(activePaneId, forKey: .activePaneId)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workingDirectoryPath = try c.decode(String.self, forKey: .workingDirectoryPath)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        if let root = try c.decodeIfPresent(PersistedPaneNode.self, forKey: .root) {
            self.root = root
            self.activePaneId = try c.decodeIfPresent(UUID.self, forKey: .activePaneId)
        } else {
            // Legacy schema: flat `tabs: [PersistedTab]`. Wrap into a single Pane.
            let legacy = try c.decode([PersistedTab].self, forKey: .tabs)
            let activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
            let pane = PersistedPane(
                id: UUID(),
                tabs: legacy,
                activeTabId: activeTabId
            )
            self.root = PersistedPaneNode(id: pane.id, kind: .pane(pane))
            self.activePaneId = pane.id
        }
    }
}

struct PersistedPaneNode: Codable, Equatable {
    var id: UUID
    var kind: PersistedPaneKind
}

indirect enum PersistedPaneKind: Equatable {
    case pane(PersistedPane)
    case split(orientation: SplitOrientation, first: PersistedPaneNode, second: PersistedPaneNode, fraction: Double)
}

extension PersistedPaneNode {
    @MainActor
    init(_ node: PaneNode) {
        self.id = node.id
        switch node.content {
        case .pane(let pane):
            self.kind = .pane(PersistedPane(pane))
        case .split(let orientation, let first, let second, let fraction):
            self.kind = .split(
                orientation: orientation,
                first: PersistedPaneNode(first),
                second: PersistedPaneNode(second),
                fraction: fraction
            )
        }
    }
}

extension PersistedPaneKind: Codable {
    private enum CodingKeys: String, CodingKey { case pane, split }

    private struct SplitPayload: Codable, Equatable {
        var orientation: SplitOrientation
        var first: PersistedPaneNode
        var second: PersistedPaneNode
        var fraction: Double
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let p):
            try c.encode(p, forKey: .pane)
        case .split(let orient, let first, let second, let fraction):
            try c.encode(
                SplitPayload(orientation: orient, first: first, second: second, fraction: fraction),
                forKey: .split
            )
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try c.decodeIfPresent(PersistedPane.self, forKey: .pane) {
            self = .pane(pane)
        } else if let payload = try c.decodeIfPresent(SplitPayload.self, forKey: .split) {
            self = .split(
                orientation: payload.orientation,
                first: payload.first,
                second: payload.second,
                fraction: payload.fraction
            )
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .pane, in: c,
                debugDescription: "PersistedPaneKind requires either pane or split"
            )
        }
    }
}

struct PersistedPane: Codable, Equatable {
    var id: UUID
    var tabs: [PersistedTab]
    var activeTabId: UUID?

    @MainActor
    init(_ pane: Pane) {
        self.id = pane.id
        self.tabs = pane.tabs.map(PersistedTab.init)
        self.activeTabId = pane.activeTabId
    }

    init(id: UUID, tabs: [PersistedTab], activeTabId: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

struct PersistedTab: Codable, Equatable {
    var id: UUID
    var agentId: String
    var currentDirectoryPath: String
    var customTitle: String?

    @MainActor
    init(_ session: Session) {
        self.id = session.id
        self.agentId = session.agent.id
        self.currentDirectoryPath = session.currentDirectory.path
        self.customTitle = session.customTitle
    }

    init(id: UUID, agentId: String, currentDirectoryPath: String, customTitle: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.currentDirectoryPath = currentDirectoryPath
        self.customTitle = customTitle
    }
}

@MainActor
protocol Persistence {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

@MainActor
final class FilePersistence: Persistence {
    static let shared = FilePersistence()

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("pebble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
