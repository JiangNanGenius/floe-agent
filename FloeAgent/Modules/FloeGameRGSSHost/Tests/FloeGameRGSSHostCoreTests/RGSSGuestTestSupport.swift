// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeRPGCore

enum RGSSGuestTestSupport {
    static func temporaryDirectory(_ label: String = "floe-rgss") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    /// Minimal recognizable project. The script archive is intentionally not
    /// a valid Marshal payload for play tests; components that need a real
    /// archive construct one with RPGScriptArchive.
    static func makeProject(engine: GameEngineID = .rpgMakerXP,
                            validScriptArchive: Bool = false) throws -> URL {
        let root = try temporaryDirectory("rgss-source")
        let profile = try RGSSEngineProfiles.profile(for: engine)
        try write("RTP=RTP", to: root.appendingPathComponent("Game.ini"))
        try write("marker", to: root.appendingPathComponent("Game." + profile.markerExtension))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Data"), withIntermediateDirectories: true)
        let archive: Data
        if validScriptArchive {
            archive = try RPGScriptArchiveFixture.archive(engine: engine)
        } else {
            archive = Data("not-a-real-archive".utf8)
        }
        try archive.write(to: root.appendingPathComponent(profile.scriptsPath))
        try write("unknown bytes", to: root.appendingPathComponent("Plugins/custom.rb"))
        try write("MZ", to: root.appendingPathComponent("Game.exe"))
        try write("DLL", to: root.appendingPathComponent("RGSS104E.dll"))
        try write("encrypted", to: root.appendingPathComponent("Game.rgssad"))
        try write("audio", to: root.appendingPathComponent("Audio/BGM/theme.wma"))
        return root
    }

    static func context(for projectID: UUID, owner: GameProjectOwner,
                        root: URL, revision: String = "rev-1",
                        environmentID: String = "linux-env-1") throws -> GameProjectContext {
        try GameProjectContext(projectID: projectID, owner: owner, rootURL: root,
                               savedRevision: revision, environmentID: environmentID)
    }

    static func staged(_ request: RGSSGuestRunRequest) async throws -> RGSSGuestStagedRun {
        let base = try temporaryDirectory("rgss-runs")
        let stager = RGSSGuestRunStager(layout: try RGSSGuestRunLayout(baseDirectory: base))
        return try await stager.stage(request)
    }
}

/// Builds a real RGSS script archive for overlay/developer tests.
enum RPGScriptArchiveFixture {
    static func archive(engine: GameEngineID) throws -> Data {
        let scripts = [
            RPGScript(magic: 1, title: .utf8("Main"), source: Data("puts 'fixture'".utf8)),
            RPGScript(magic: 2, title: .utf8("Scene_Title"), source: Data("# scene".utf8)),
        ]
        return try RPGScriptArchive.encode(scripts)
    }
}

enum RGSSGuestTestOwner {
    static func space(_ id: UUID) -> GameProjectOwner { .space(recordID: id) }
}
