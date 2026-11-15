// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameNarrativeKit

/// Shared fixtures for the narrative adapter tests. The prepared resource pack
/// is produced by `Scripts/prepare_narrative.py` (offline after preparation).
enum NarrativeTestSupport {
    static var repositoryRoot: URL {
        if let explicit = ProcessInfo.processInfo.environment["FLOE_GAME_REPOSITORY_ROOT"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL.resolvingSymlinksInPath()
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() } // .../FloeGameNarrativeKitTests -> repository root
        return url
    }

    static var resources: URL {
        if let override = ProcessInfo.processInfo.environment["FLOE_NARRATIVE_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // The reviewed narrative resource pack is qualification data and is
        // not part of this package. Tests skip until a caller supplies it.
        return repositoryRoot.appendingPathComponent("Fixtures/NarrativeResources")
    }

    static func requireResources() throws {
        let url = resources
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("inkjs/inkjs.js").path) else {
            throw XCTSkip("Prepared narrative resources are missing; run Scripts/prepare_narrative.py first: \(url.path)")
        }
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-narrative-\(label)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context(root: URL, projectID: UUID = UUID()) throws -> GameProjectContext {
        try GameProjectContext(projectID: projectID, owner: .space(recordID: projectID), rootURL: root, savedRevision: "rev-1")
    }

    static func artifactPackage(sourceRoot: URL, engine: GameEngineID, entry: String = "index.html") throws -> GameWebArtifactPackage {
        let source = try context(root: sourceRoot)
        let target = sourceRoot.deletingLastPathComponent().appendingPathComponent("artifact-" + UUID().uuidString)
        return try GameWebArtifactPackage.build(source: source, engine: engine,
                                                entry: GameRelativePath(entry), to: target)
    }

    static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    static func supportFiles(in artifact: URL) throws -> [String] {
        let directory = artifact.appendingPathComponent("support")
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".js") || $0.hasSuffix(".css") }
            .sorted()
    }

    static func supportText(in artifact: URL) throws -> String {
        try supportFiles(in: artifact).map {
            try text(artifact.appendingPathComponent("support").appendingPathComponent($0))
        }.joined(separator: "\n")
    }

    static func manifest(in artifact: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(
            with: read(artifact.appendingPathComponent("floe-artifact.json"))) as? [String: Any])
    }

    static func suiteDirectory(_ label: String) throws -> URL {
        try temporaryDirectory(label)
    }
}
