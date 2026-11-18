import Foundation

/// All test data stays in the task's declared scratch scope. No test writes to
/// /tmp, /var/folders, or another fixed path outside the authorized workspace.
enum MacToolboxTestRoot {
    static var directory: URL {
        if let root = ProcessInfo.processInfo.environment["FLOE_MAC_TOOLBOX_TEST_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("FloeMacToolboxTests", isDirectory: true)
    }

    static func unique(_ label: String) throws -> URL {
        let url = directory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
