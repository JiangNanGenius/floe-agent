#if os(macOS)
import Foundation
import Darwin
import CBridgePTY
import FloeMacBridgeProtocol

final class BridgeJob: @unchecked Sendable {
    let id: String
    let clientID: String
    let workspaceID: String
    let output: URL
    let pid: pid_t
    let master: Int32
    private let lock = NSLock()
    private var finished: Int32?
    private var written: Int64 = 0
    private var inputBytes: Int64 = 0
    init(id: String, clientID: String, workspaceID: String, output: URL, pid: pid_t, master: Int32) {
        self.id = id; self.clientID = clientID; self.workspaceID = workspaceID
        self.output = output; self.pid = pid; self.master = master
    }
    func status() -> (code: Int32?, bytes: Int64, input: Int64) { lock.withLock { (finished, written, inputBytes) } }
    func drain() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let writer = try? FileHandle(forWritingTo: output) else { signal(SIGTERM); return }
            defer { try? writer.close(); lock.withLock { _ = Darwin.close(master) } }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                do {
                    try writer.write(contentsOf: Data(buffer.prefix(count)))
                    lock.withLock { written += Int64(count) }
                } catch { signal(SIGTERM); break }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            lock.withLock { finished = code }
            // Persist outcome separately from the unbounded user output.
            if let data = try? BridgeWire.encode(["exitCode": code]) {
                try? data.write(to: output.deletingLastPathComponent().appendingPathComponent("result.json"), options: .atomic)
            }
        }
    }
    func write(_ data: Data) throws {
        let descriptor = lock.withLock { finished == nil ? Darwin.dup(master) : -1 }
        guard descriptor >= 0 else { throw BridgeFailure.remote("This terminal has ended.") }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeFailure.disconnected }
                offset += count
            }
            lock.withLock { inputBytes += Int64(raw.count) }
        }
    }
    func resize(columns: Int, rows: Int) throws {
        try lock.withLock {
            guard finished == nil else { return }
            guard floe_resize_pty(master, UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1))) == 0 else { throw BridgeFailure.remote("Cannot resize this terminal.") }
        }
    }
    func signal(_ signal: Int32) { if status().code == nil { _ = Darwin.kill(-pid, signal) } }
}

actor BridgeJobs {
    let paths: BridgePaths
    private var jobs: [String: BridgeJob] = [:]
    init(paths: BridgePaths) { self.paths = paths }
    func start(id: String, clientID: String, workspaceID: String, command: String, commandFile: URL? = nil, cwd: URL,
               environment: [String: String], columns: Int, rows: Int) throws -> [String: BridgeValue] {
        guard UUID(uuidString: id) != nil, jobs[id] == nil else { throw BridgeFailure.remote("This job already exists; inspect its result.") }
        let taskRoot = try paths.managed("Tasks", id: id)
        // A previous process's receipt is not permission to rerun the command.
        guard !FileManager.default.fileExists(atPath: taskRoot.path) else { throw BridgeFailure.ambiguous }
        try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let output = taskRoot.appendingPathComponent("output.bin")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeFailure.remote("Cannot save terminal output.") }
        let receipt = ["workspace": workspaceID, "client": clientID]
        try BridgeWire.encode(receipt).write(to: taskRoot.appendingPathComponent("owner.json"), options: .atomic)
        let argvStrings: [String]
        if let commandFile {
            let privateScript = taskRoot.appendingPathComponent("command.zsh")
            try FileManager.default.moveItem(at: commandFile, to: privateScript)
            argvStrings = ["/bin/zsh", "-l", privateScript.path]
        } else { argvStrings = command.isEmpty ? ["/bin/zsh", "-il"] : ["/bin/zsh", "-lc", command] }
        let argv = argvStrings.map { strdup($0) } + [nil]
        var variables = ProcessInfo.processInfo.environment
        variables.merge(environment) { _, new in new }
        // No Linux/app-container HOME/PATH may enter the host process.
        variables["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        variables["TERM"] = "xterm-256color"
        let search = ["/opt/homebrew/bin", "/usr/local/bin"] + (variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seenPaths = Set<String>()
        variables["PATH"] = search.filter { seenPaths.insert($0).inserted }.joined(separator: ":")
        variables["FLOE_EXECUTION_BACKEND"] = "macBridge"
        let envp = variables.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { vars in
            floe_spawn_pty(&master, cwd.path, args.baseAddress, vars.baseAddress,
                           UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)))
        } }
        guard pid > 0, master >= 0 else { throw BridgeFailure.remote("The Mac terminal could not start.") }
        let job = BridgeJob(id: id, clientID: clientID, workspaceID: workspaceID, output: output, pid: pid, master: master)
        jobs[id] = job; job.drain()
        return ["jobID": .string(id), "alive": .bool(true)]
    }
    func owned(_ id: String, clientID: String) throws -> BridgeJob {
        guard let job = jobs[id], job.clientID == clientID else { throw BridgeFailure.remote("This terminal is unavailable. It was not restarted.") }
        return job
    }
    func poll(id: String, clientID: String, offset: Int64, limit: Int) throws -> [String: BridgeValue] {
        if jobs[id] == nil {
            let directory = try paths.managed("Tasks", id: id)
            let owner = try BridgeWire.decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("owner.json")))
            guard owner["client"] == clientID else { throw BridgeFailure.authentication }
            let output = directory.appendingPathComponent("output.bin")
            let total = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard offset >= 0, offset <= total else { throw BridgeFailure.unsafePath }
            let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(offset))
            let data = try reader.read(upToCount: min(max(limit, 1), BridgeWire.pageBytes)) ?? Data()
            let receipt = try? BridgeWire.decode([String: Int32].self, from: Data(contentsOf: directory.appendingPathComponent("result.json")))
            return ["data": .string(data.base64EncodedString()), "offset": .integer(offset + Int64(data.count)), "totalBytes": .integer(total),
                    "alive": .bool(false), "outcomeUnknown": .bool(receipt == nil),
                    "exitCode": receipt?["exitCode"].map { .integer(Int64($0)) } ?? .null]
        }
        let job = try owned(id, clientID: clientID)
        let status = job.status()
        guard offset >= 0, offset <= status.bytes else { throw BridgeFailure.remote("Invalid output position.") }
        let reader = try FileHandle(forReadingFrom: job.output); defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let bytes = try reader.read(upToCount: min(max(limit, 1), BridgeWire.pageBytes)) ?? Data()
        return ["data": .string(bytes.base64EncodedString()), "offset": .integer(offset + Int64(bytes.count)),
                "totalBytes": .integer(status.bytes), "inputBytes": .integer(status.input),
                "alive": .bool(status.code == nil), "exitCode": status.code.map { .integer(Int64($0)) } ?? .null]
    }
    func activeWorkspaceIDs() -> Set<String> { Set(jobs.values.filter { $0.status().code == nil }.map(\.workspaceID)) }
    func activeTaskIDs() -> Set<String> { Set(jobs.values.filter { $0.status().code == nil }.map(\.id)) }
    func cancelAll(clientID: String) { for job in jobs.values where job.clientID == clientID { job.signal(SIGTERM) } }
    func stopAllAndWait() async {
        for job in jobs.values { job.signal(SIGTERM) }
        for attempt in 0..<80 {
            let active = jobs.values.filter { $0.status().code == nil }
            if active.isEmpty { return }
            if attempt == 30 { for job in active { job.signal(SIGKILL) } }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    func resize(id: String, clientID: String, columns: Int, rows: Int) throws {
        let job = try owned(id, clientID: clientID)
        try job.resize(columns: columns, rows: rows)
    }
}
#endif
