// Compile with the production helper in FloeApp/Execution/LinuxGuestBackend.swift:
// swiftc -swift-version 6 LinuxGuestBackend.swift Host.swift -o /tmp/linux-workspace-host
// This host runs on macOS; it neither boots a guest nor touches an iOS device.
import Foundation
import Darwin

private enum CheckFailure: Error { case failed(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct LinuxMaintenanceWorkspaceHost {
    static func main() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-linux-maintenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Environments", isDirectory: true)
        let layer = root.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        let retained = layer.appendingPathComponent("installed-package-marker")
        try Data("retained".utf8).write(to: retained)

        let first = try SharedLinuxMaintenanceWorkspace.prepare(nextTo: layer)
        let second = try SharedLinuxMaintenanceWorkspace.prepare(nextTo: layer)
        try require(first.standardizedFileURL == second.standardizedFileURL,
                    "Existing directory was not reused")
        let retainedData = try Data(contentsOf: retained)
        try require(retainedData == Data("retained".utf8),
                    "Shared environment data was modified")

        // The Settings descriptor and its lease may read the same path in
        // parallel. Only one caller needs to create it; all must converge.
        let concurrent = root.appendingPathComponent("Concurrent", isDirectory: true)
        let concurrentLayer = concurrent.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: concurrentLayer, withIntermediateDirectories: true)
        let paths = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<16 {
                group.addTask { try SharedLinuxMaintenanceWorkspace.prepare(nextTo: concurrentLayer) }
            }
            var paths: [URL] = []
            for try await path in group { paths.append(path) }
            return paths
        }
        try require(paths.count == 16 && paths.allSatisfy({ $0.standardizedFileURL == paths[0].standardizedFileURL }),
                    "Concurrent callers did not converge")

        // /var is a symlink to /private/var on Apple systems. Both spellings
        // must resolve to the same owned directory when this alias exists.
        var aliasChecked = false
        let layerPath = layer.path
        let aliasPath: String?
        if layerPath.hasPrefix("/var/") {
            aliasPath = "/private" + layerPath
        } else if layerPath.hasPrefix("/private/var/") {
            aliasPath = String(layerPath.dropFirst("/private".count))
        } else {
            aliasPath = nil
        }
        if let aliasPath {
            let aliased = URL(fileURLWithPath: aliasPath, isDirectory: true)
            let fromAlias = try SharedLinuxMaintenanceWorkspace.prepare(nextTo: aliased)
            var originalInfo = stat(), aliasInfo = stat()
            let originalStatus = first.path.withCString { lstat($0, &originalInfo) }
            let aliasStatus = fromAlias.path.withCString { lstat($0, &aliasInfo) }
            try require(originalStatus == 0 && aliasStatus == 0
                        && originalInfo.st_dev == aliasInfo.st_dev
                        && originalInfo.st_ino == aliasInfo.st_ino,
                        "/var and /private/var resolved to different directories")
            aliasChecked = true
        }

        // A relocated App container must derive the workspace from its new
        // Shared layer path, without consulting an old persisted absolute path.
        let relocated = fixture.appendingPathComponent("Relocated/Environments", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: relocated)
        let relocatedWorkspace = try SharedLinuxMaintenanceWorkspace.prepare(
            nextTo: relocated.appendingPathComponent("Shared", isDirectory: true)
        )
        try require(relocatedWorkspace.deletingLastPathComponent().standardizedFileURL == relocated.standardizedFileURL,
                    "Relocated root was not used")

        let unsafeRoot = fixture.appendingPathComponent("Unsafe/Environments", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
        let unsafeLayer = unsafeRoot.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeLayer, withIntermediateDirectories: false)
        let unsafeWorkspace = unsafeRoot.appendingPathComponent(".LinuxCacheCleanupWorkspace")
        try Data("user data".utf8).write(to: unsafeWorkspace)
        do {
            _ = try SharedLinuxMaintenanceWorkspace.prepare(nextTo: unsafeLayer)
            throw CheckFailure.failed("An existing file was accepted")
        } catch SharedLinuxMaintenanceWorkspace.Failure.unsafeDirectory {}
        try FileManager.default.removeItem(at: unsafeWorkspace)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideMarker = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: outsideMarker)
        try FileManager.default.createSymbolicLink(at: unsafeWorkspace, withDestinationURL: outside)
        do {
            _ = try SharedLinuxMaintenanceWorkspace.prepare(nextTo: unsafeLayer)
            throw CheckFailure.failed("A symbolic link was accepted")
        } catch SharedLinuxMaintenanceWorkspace.Failure.unsafeDirectory {}
        let outsideData = try Data(contentsOf: outsideMarker)
        try require(outsideData == Data("keep".utf8),
                    "A rejected link changed its target")
        print("PASS: existing, concurrent, relocated and unsafe workspace paths; /var alias checked=\(aliasChecked)")
    }
}
