import Foundation

final class TestFiles {
    let baseURL: URL
    let logURL: URL
    let readyURL: URL
    let heartbeatURL: URL
    let heartbeatLogURL: URL
    let commandURL: URL
    let finalURL: URL
    let processedURL: URL

    private let logLock = NSLock()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseURL = documents.appendingPathComponent("canary", isDirectory: true)
        logURL = baseURL.appendingPathComponent("engine-test.log")
        readyURL = baseURL.appendingPathComponent("engine-ready.json")
        heartbeatURL = baseURL.appendingPathComponent("engine-heartbeat.json")
        heartbeatLogURL = baseURL.appendingPathComponent("engine-heartbeat.log")
        commandURL = baseURL.appendingPathComponent("command.json")
        finalURL = baseURL.appendingPathComponent("engine-final.json")
        processedURL = baseURL.appendingPathComponent("processed", isDirectory: true)
        ensureDirectories()
    }

    func ensureDirectories() {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
    }

    func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func log(_ message: String) {
        let line = "\(timestamp()) pid=\(ProcessInfo.processInfo.processIdentifier) " +
            "main=\(Thread.isMainThread ? 1 : 0) \(message)\n"
        logLock.lock()
        defer { logLock.unlock() }
        appendRaw(line, to: logURL)
    }

    func appendHeartbeatLine(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        appendRaw(line + "\n", to: heartbeatLogURL)
    }

    private func appendRaw(_ string: String, to url: URL) {
        guard let data = string.data(using: .utf8) else { return }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base.advanced(by: offset), data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        fsync(descriptor)
    }

    @discardableResult
    func writeJSON(_ object: Any, to url: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(object) else {
            log("json_invalid_object target=\(url.lastPathComponent)")
            return false
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try writeData(data, to: url)
            return true
        } catch {
            log("json_write_failed target=\(url.lastPathComponent) error=\(error.localizedDescription)")
            return false
        }
    }

    func writeData(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open failed for \(url.path)"]
            )
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base.advanced(by: offset), data.count - offset)
                if written <= 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "write failed for \(url.path)"]
                    )
                }
                offset += written
            }
        }
        fsync(descriptor)
    }

    func readCommand() -> [String: Any]? {
        guard let data = try? Data(contentsOf: commandURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    func moveCommandToProcessed(identifier: String) {
        let safe = TestFiles.safeIdentifier(identifier)
        let destination = processedURL.appendingPathComponent("command-\(safe).json")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: commandURL, to: destination)
    }

    static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars.prefix(80))
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
