// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

// Development-only read-only inspector; it is not an App execution tool.
struct InspectionReport: Encodable {
    struct Candidate: Encodable {
        struct Evidence: Encodable { let path: String; let kind: String; let versionHint: String? }
        let engine: GameEngineID
        let evidence: [Evidence]
    }
    let sample: String
    let candidates: [Candidate]
    let inspectedPaths: [String]
    let engineExecuted = false

    init(sample: String, inspection: GameProjectInspection) {
        self.sample = sample
        candidates = inspection.candidates.map { candidate in
            .init(engine: candidate.engine, evidence: candidate.evidence.map {
                .init(path: $0.path.value, kind: $0.kind.rawValue, versionHint: $0.versionHint)
            })
        }
        inspectedPaths = inspection.inspectedPaths.map(\.value)
    }
}

func inspect(_ root: URL, sample: String) throws -> InspectionReport {
    .init(sample: sample, inspection: try GameProjectInspector().inspect(rootURL: root))
}

func demo() throws -> [InspectionReport] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeGamePreflight-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // All fixtures are original synthetic metadata. No engine, artwork or game scripts are bundled.
    let samples: [(String, [String: String])] = [
        ("xp", ["Game.rxproj": "RPGXP 1.02\n"]),
        ("vx", ["Game.rvproj": "RPGVX 1.02\n"]),
        ("vxAce", ["Game.rvproj2": "RPGVXAce 1.00\n"]),
        ("mv", ["Game.rpgproject": "RPGMV 1.6.1\n"]),
        ("mz", ["Game.rmmzproject": "RPGMZ 1.0.0\n"]),
        ("godot", ["project.godot": "config_version=5\n"]),
        ("unity", ["ProjectSettings/ProjectVersion.txt": "m_EditorVersion: 6000.3.0f1\n", "Assets/.keep": ""]),
        ("phaser", ["package.json": #"{"dependencies":{"phaser":"^3.90.0"}}"#]),
        ("kaplay", ["package.json": #"{"dependencies":{"kaplay":"^3001.0.19"}}"#]),
        ("babylon", ["package.json": #"{"devDependencies":{"@babylonjs/core":"^9.0.0"}}"#]),
        ("playcanvas", ["package.json": #"{"dependencies":{"playcanvas":"^2.0.0"}}"#])
    ]
    return try samples.map { name, files in
        let directory = root.appendingPathComponent(name)
        for (path, text) in files {
            let target = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        return try inspect(directory, sample: name)
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let reports: [InspectionReport]
    if arguments == ["--demo"] { reports = try demo() }
    else if arguments.count == 1 {
        reports = [try inspect(URL(fileURLWithPath: arguments[0], isDirectory: true), sample: "suppliedRoot")]
    } else {
        FileHandle.standardError.write(Data("Usage: floe-game-preflight --demo | PROJECT_DIRECTORY\n".utf8))
        exit(2)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(reports))
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Project inspection failed: \(error)\n".utf8))
    exit(1)
}
