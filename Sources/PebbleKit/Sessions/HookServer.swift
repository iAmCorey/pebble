import Darwin
import Foundation

/// Listens on a per-user unix socket for one-shot JSON event lines from agent
/// hooks (sent by the `pebble-hook` CLI). Wire format is one line per event:
/// `{"event":"running|attention|idle","surface":"<UUID>"}`.
///
/// The hooks themselves run as short-lived child processes of the agent (e.g.
/// Claude Code spawns them per Stop / UserPromptSubmit / Notification). They
/// connect, write one line, close — we accept and read in a single pass.
/// Lifecycle signal an agent's hook fired. Wire format is the raw String
/// case names; the enum lets `WorkspaceStore` switch exhaustively.
enum HookEvent: String {
    case running, attention, idle, ended

    var activityState: SessionActivityState {
        switch self {
        case .running: return .running
        case .attention: return .attention
        case .idle, .ended: return .idle
        }
    }
}

@MainActor
final class HookServer {
    typealias Handler = (_ agent: AgentTemplate, _ event: HookEvent, _ sessionId: UUID) -> Void

    private let handler: Handler
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?

    init(handler: @escaping Handler) { self.handler = handler }

    /// Path agents and the CLI both target. Public so the CLI doesn't have to
    /// hardcode the same string in two places — but agents run in their own
    /// processes and read it via `PebbleHook` reaching into `Application
    /// Support`, not via this property.
    static let socketPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("pebble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("socket").path
    }()

    func start() {
        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("pebble: HookServer socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            NSLog("pebble: HookServer socket path too long")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else {
            NSLog("pebble: HookServer bind() failed errno=\(errno)")
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("pebble: HookServer listen() failed errno=\(errno)")
            close(fd)
            return
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        try? FileManager.default.removeItem(atPath: Self.socketPath)
    }

    private func acceptOne() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        defer { close(clientFd) }

        // Single read up to 4 KiB. Hook payloads are < 200 B and unix
        // SOCK_STREAM kernel-buffers small writes whole, so partial reads
        // aren't a practical concern at our message size.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { read(clientFd, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        let data = Data(bytes: buffer, count: n)
        guard
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agentSlug = dict["agent"] as? String,
            let eventName = dict["event"] as? String,
            let surface = dict["surface"] as? String,
            let id = UUID(uuidString: surface),
            let agent = AgentTemplate.from(hookSlug: agentSlug),
            let event = HookEvent(rawValue: eventName)
        else { return }
        handler(agent, event, id)
    }
}
