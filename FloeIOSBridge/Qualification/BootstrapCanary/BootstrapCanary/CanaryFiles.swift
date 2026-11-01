import Foundation

enum CanaryFiles {
    static let directoryName = "canary"

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var baseURL: URL {
        documentsURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var logURL: URL { baseURL.appendingPathComponent("bootstrap.log") }
    static var hostStatusURL: URL { baseURL.appendingPathComponent("host-status.json") }
    static var commandURL: URL { baseURL.appendingPathComponent("command.json") }
    static var startRequestURL: URL { baseURL.appendingPathComponent("start-request.json") }
    static var engineReadyURL: URL { baseURL.appendingPathComponent("engine-ready.json") }
    static var heartbeatURL: URL { baseURL.appendingPathComponent("engine-heartbeat.json") }
    static var processedURL: URL { baseURL.appendingPathComponent("processed", isDirectory: true) }

    static func prepare() {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func appendLog(_ message: String) {
        FBCAppendLog(logURL.path, message)
    }

    @discardableResult
    static func writeJSON(_ object: Any, to url: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(object) else {
            appendLog("json_invalid_object target=\(url.lastPathComponent)")
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
            appendLog("json_write_failed target=\(url.lastPathComponent) error=\(error.localizedDescription)")
            return false
        }
    }

    static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars.prefix(80))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func buildInfo() -> [String: Any] {
        let bundle = Bundle.main
        return [
            "bundleIdentifier": bundle.bundleIdentifier ?? "<missing>",
            "bundleVersion": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "<missing>",
            "shortVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<missing>",
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "bundlePath": bundle.bundlePath,
            "executablePath": bundle.executablePath ?? "<missing>",
            "systemUptime": ProcessInfo.processInfo.systemUptime,
        ]
    }

    static func testBundleInfo() -> [String: Any] {
        let path = Bundle.main.bundlePath + "/PlugIns/BootstrapCanaryUITests.xctest"
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        var info: [String: Any] = [
            "path": path,
            "exists": exists,
            "isDirectory": isDirectory.boolValue,
        ]
        let plistPath = path + "/Info.plist"
        if let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] {
            info["bundleIdentifier"] = plist["CFBundleIdentifier"] as? String ?? "<missing>"
            info["containsUITests"] = (plist["XCTContainsUITests"] as? NSNumber)?.boolValue ?? false
        } else {
            info["plistReadable"] = false
        }
        return info
    }
}
