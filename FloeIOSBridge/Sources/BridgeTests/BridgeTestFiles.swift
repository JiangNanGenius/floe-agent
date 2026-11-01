import Foundation
import BridgeCore

final class BridgeTestFiles: @unchecked Sendable {
    let baseURL = BridgePaths.root
    let logURL = BridgePaths.engineLogFile
    let heartbeatLogURL = BridgePaths.logs.appendingPathComponent("engine-heartbeat.log")
    private let lock = NSLock()

    func ensureDirectories() {
        BridgePaths.prepare()
    }

    func log(_ message: String) {
        let line = "\(BridgeClock.timestamp()) pid=\(ProcessInfo.processInfo.processIdentifier) " +
            "main=\(Thread.isMainThread ? 1 : 0) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        appendRaw(line, to: logURL)
    }

    func appendHeartbeatLine(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        appendRaw(line + "\n", to: heartbeatLogURL)
    }

    private func appendRaw(_ string: String, to url: URL) {
        guard let data = string.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base.advanced(by: offset), data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        fsync(descriptor)
    }
}
