import XCTest
@testable import PebbleKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/tmp/projectA")
    private let projectB = URL(fileURLWithPath: "/tmp/projectB")
    private let projectC = URL(fileURLWithPath: "/tmp/projectC")

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        for path in ["/tmp/projectA", "/tmp/projectA/sub", "/tmp/projectA/deep", "/tmp/projectB", "/tmp/projectC"] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func makeStore(initial: PersistedState? = nil) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(initial: initial),
            engineFactory: { TestEngine() }
        )
    }

    private func engine(_ session: Session) -> TestEngine {
        guard let e = session.engine as? TestEngine else { preconditionFailure("expected TestEngine") }
        return e
    }

    private func firstPane(_ ws: Workspace) -> Pane {
        guard let pane = ws.root.firstPane else { preconditionFailure("expected at least one pane") }
        return pane
    }

    func testInitialStateHasOneWorkspaceWithOnePaneAndOneTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(ws).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, ws.id)
    }

    func testFirstWorkspaceUsesHomeDirectory() {
        let store = makeStore()
        XCTAssertEqual(store.workspaces.first?.workingDirectory.path, NSHomeDirectory())
        XCTAssertEqual(store.workspaces.first?.title, "Home")
    }

    func testAddWorkspaceCreatesNewWorkspaceAndActivatesIt() {
        let store = makeStore()
        let first = store.workspaces[0]
        let second = store.addWorkspace(workingDirectory: projectA)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(second.root.allPanes.count, 1)
        XCTAssertEqual(firstPane(second).tabs.count, 1)
        XCTAssertEqual(store.activeWorkspaceId, second.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testAddWorkspaceTitleDefaultsToLastPathComponent() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/sample-project"))
        XCTAssertEqual(ws.title, "sample-project")
    }

    func testAddTabAppendsToActivePaneAndStartsEngine() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = store.addTab(in: ws, template: .terminal)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTabId, session.id)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, projectA.path)
    }

    func testActiveTabPwdReportSyncsToWorkspace() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        let session = pane.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    func testCommandFinishedUpdatesSessionStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let session = firstPane(ws).tabs[0]
        XCTAssertNil(session.lastCommandExit)
        XCTAssertNil(session.lastCommandDuration)
        engine(session).emitCommandFinished(exit: 1, duration: 0.42)
        XCTAssertEqual(session.lastCommandExit, 1)
        XCTAssertEqual(session.lastCommandDuration, 0.42)
        // Subsequent zero-exit overwrites the failure (so the dot disappears
        // when the next command succeeds, instead of sticking forever).
        engine(session).emitCommandFinished(exit: 0, duration: 0.05)
        XCTAssertEqual(session.lastCommandExit, 0)
    }

    func testWorkspaceFailureAggregatesAcrossPanes() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        // Failure-bearing tab must live in a different pane from the active
        // one to verify the DFS picks it up regardless of focus.
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        XCTAssertFalse(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
        engine(secondPaneTab).emitCommandFinished(exit: 0, duration: 0.1)
        XCTAssertFalse(ws.hasCommandFailure)
        engine(firstTab).emitCommandFinished(exit: 2, duration: 0.1)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testFailureSurfacesEvenWhenAttentionFiresFirstInDFS() {
        // Regression: `sidebarReadout`'s walk used to short-circuit on attention,
        // leaving `hasCommandFailure` false when a sibling pane held a non-zero
        // exit. The walk now runs to completion so each field is independent.
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.splitPane(pane, orientation: .horizontal, in: ws)
        let firstPaneTab = pane.tabs[0]
        let secondPaneTab = ws.root.allPanes.last!.tabs[0]
        firstPaneTab.activityState = .attention
        engine(secondPaneTab).emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertEqual(ws.activityState, .attention)
        XCTAssertTrue(ws.hasCommandFailure)
    }

    func testNewTabInheritsLatestPwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        engine(pane.tabs[0]).emitPwd("/tmp/projectA/sub")
        let session = store.addTab(in: ws)
        XCTAssertEqual(engine(session).startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testAddTabRespectsTemplate() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let session = store.addTab(in: ws, template: .claudeCode)
        XCTAssertEqual(session.agent.id, "claude-code")
        XCTAssertEqual(engine(session).startedConfigs.first?.environment["PEBBLE_AGENT"], "claude")
    }

    func testClosingActiveTabActivatesNeighbor() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let first = pane.tabs[0]
        let second = store.addTab(in: ws)
        XCTAssertEqual(pane.activeTabId, second.id)
        store.closeTab(second, in: ws)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.activeTabId, first.id)
        XCTAssertEqual(engine(second).terminateCount, 1)
    }

    func testClosingLastTabClosesPaneAndWorkspaceWhenSinglePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        store.closeTab(pane.tabs[0], in: ws)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    func testClosingMiddleWorkspaceActivatesNextNeighbor() {
        let store = makeStore()
        let a = store.workspaces[0]
        let b = store.addWorkspace(workingDirectory: projectB)
        let c = store.addWorkspace(workingDirectory: projectC)
        store.activateWorkspace(b)
        store.closeWorkspace(b)
        XCTAssertEqual(store.workspaces.map(\.id), [a.id, c.id])
        XCTAssertEqual(store.activeWorkspaceId, c.id)
    }

    func testClosingLastWorkspaceClearsActiveId() {
        let store = makeStore()
        store.closeWorkspace(store.workspaces[0])
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.activeWorkspaceId)
    }

    // MARK: Splits

    func testSplitPaneCreatesSiblingPaneAndFocusesIt() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)
        XCTAssertNotNil(new)
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, new?.id)
        XCTAssertEqual(new?.tabs.count, 1)
    }

    func testSplitPaneInheritsActiveTabAgentAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let pane = firstPane(ws)
        store.addTab(in: ws, template: .claudeCode)
        engine(pane.tabs.last!).emitPwd("/tmp/projectA/sub")
        let new = store.splitPane(pane, orientation: .vertical, in: ws)
        let newSession = new?.tabs.first
        XCTAssertEqual(newSession?.agent.id, "claude-code")
        XCTAssertEqual((newSession?.engine as? TestEngine)?.startedConfigs.last?.workingDirectory, "/tmp/projectA/sub")
    }

    func testClosePaneCollapsesSiblingUp() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.closePane(new, in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testClosingLastTabInSecondPaneCollapsesSplit() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        // Close the lone tab in `new`. Should collapse the split, leaving `pane` alone.
        store.closeTab(new.tabs[0], in: ws)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertEqual(ws.root.allPanes.first?.id, pane.id)
    }

    func testFocusPaneSwitchesActivePane() {
        let store = makeStore()
        let ws = store.workspaces[0]
        let pane = firstPane(ws)
        let new = store.splitPane(pane, orientation: .horizontal, in: ws)!
        store.focusPane(pane, in: ws)
        XCTAssertEqual(ws.activePaneId, pane.id)
        store.focusPane(new, in: ws)
        XCTAssertEqual(ws.activePaneId, new.id)
    }

    func testCrossPaneMoveOfRootSoleTabKeepsWorkspaceAlive() {
        // Regression: after splitPane, the root PaneNode kept the original
        // pane's id; the wrapper for that pane (now `firstChild`) reused the
        // same id. Closing the now-empty source pane via id-equality would
        // route to closeWorkspace and terminate the freshly-moved session.
        let store = makeStore()
        let ws = store.workspaces[0]
        let original = firstPane(ws)
        let originalSession = original.tabs[0]
        let new = store.splitPane(original, orientation: .horizontal, in: ws)!
        XCTAssertEqual(ws.root.allPanes.count, 2)
        store.moveTab(originalSession, to: new, at: new.tabs.count, in: ws)
        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertEqual(ws.root.allPanes.count, 1)
        XCTAssertTrue(new.tabs.contains { $0.id == originalSession.id })
        XCTAssertEqual(engine(originalSession).terminateCount, 0)
    }

    func testCrossPaneMoveSyncsWorkspaceWorkingDirectory() {
        let store = makeStore()
        let ws = store.addWorkspace(workingDirectory: projectA)
        let source = firstPane(ws)
        let session = source.tabs[0]
        engine(session).emitPwd("/tmp/projectA/sub")
        let dest = store.splitPane(source, orientation: .horizontal, in: ws)!
        // splitPane spawns a new session in dest; switch active away first so
        // the move into dest is the thing that has to sync the cwd.
        store.focusPane(source, in: ws)
        store.moveTab(session, to: dest, at: dest.tabs.count, in: ws)
        XCTAssertEqual(ws.workingDirectory.path, "/tmp/projectA/sub")
    }

    // MARK: Persistence

    func testRestoreSinglePaneWorkspace() {
        let wsId = UUID()
        let paneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [
                                PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA"),
                                PersistedTab(id: leafB, agentId: "claude-code", currentDirectoryPath: "/tmp/projectA/sub"),
                            ],
                            activeTabId: leafB
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        XCTAssertEqual(store.workspaces.count, 1)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.id, wsId)
        XCTAssertEqual(ws.title, "projectA")
        let pane = firstPane(ws)
        XCTAssertEqual(pane.tabs.map(\.id), [leafA, leafB])
        XCTAssertEqual(pane.tabs[1].agent.id, "claude-code")
        XCTAssertEqual(pane.activeTabId, leafB)
        XCTAssertEqual(ws.activePaneId, paneId)
    }

    func testRestoreSpawnsEngineWithSavedWorkingDirectory() {
        let wsId = UUID()
        let paneId = UUID()
        let leafId = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: paneId,
                        kind: .pane(PersistedPane(
                            id: paneId,
                            tabs: [PersistedTab(id: leafId, agentId: "terminal", currentDirectoryPath: "/tmp/projectA/deep")],
                            activeTabId: leafId
                        ))
                    ),
                    activePaneId: paneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let pane = firstPane(store.workspaces[0])
        XCTAssertEqual(engine(pane.tabs[0]).startedConfigs.last?.workingDirectory, "/tmp/projectA/deep")
    }

    func testRestoreSplitTreeReconstructsBothPanes() {
        let wsId = UUID()
        let rootId = UUID()
        let firstPaneId = UUID()
        let secondPaneId = UUID()
        let leafA = UUID()
        let leafB = UUID()
        let initial = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: wsId,
                    workingDirectoryPath: "/tmp/projectA",
                    root: PersistedPaneNode(
                        id: rootId,
                        kind: .split(
                            orientation: .horizontal,
                            first: PersistedPaneNode(id: firstPaneId, kind: .pane(PersistedPane(id: firstPaneId, tabs: [PersistedTab(id: leafA, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafA))),
                            second: PersistedPaneNode(id: secondPaneId, kind: .pane(PersistedPane(id: secondPaneId, tabs: [PersistedTab(id: leafB, agentId: "terminal", currentDirectoryPath: "/tmp/projectA")], activeTabId: leafB))),
                            fraction: 0.6
                        )
                    ),
                    activePaneId: secondPaneId
                )
            ],
            activeWorkspaceId: wsId
        )
        let store = makeStore(initial: initial)
        let ws = store.workspaces[0]
        XCTAssertEqual(ws.root.allPanes.count, 2)
        XCTAssertEqual(ws.activePaneId, secondPaneId)
        if case .split(_, _, _, let fraction) = ws.root.content {
            XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("expected split content at root")
        }
    }

    func testFlushPersistenceWritesCurrentSnapshot() throws {
        let persistence = InMemoryPersistence()
        let store = WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() })
        store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/projectB"))
        store.flushPersistence()
        let saved = try XCTUnwrap(persistence.saved)
        XCTAssertEqual(saved.workspaces.count, 2)
        XCTAssertEqual(saved.workspaces.last?.workingDirectoryPath, "/tmp/projectB")
        XCTAssertEqual(saved.activeWorkspaceId, store.activeWorkspaceId)
    }
}
