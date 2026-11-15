// SPDX-License-Identifier: MPL-2.0
// Component-host fixture producer: creates one project + Web artifact per
// engine through the public adapter API so the Node runtime verifier and the
// root native host consume exactly what the App would build.
import Foundation
import FloeGameCore
import FloeGameNarrativeKit

struct Fixture: Encodable {
    let engine: String
    let project: String
    let artifact: String
    let entry: String
    let runtimeVersion: String
    let license: String
    let cartSHA256: String?
    let manifestSHA256: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("fixtures: " + message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments

// Private fixture harness mode: build exactly one existing project folder so
// the headless browser fixture can exercise multi-file/asset artifacts through
// the same public adapter API the App host uses.
if arguments.count >= 2, arguments[1] == "--build" {
    guard arguments.count == 6 || arguments.count == 8 else {
        fail("usage: NarrativeFixtures --build <ink|microStudio> <project> <artifact> <resources> [--entry <path>]")
    }
    let engine = arguments[2].lowercased()
    let project = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let artifact = URL(fileURLWithPath: arguments[4], isDirectory: true)
    let resources = URL(fileURLWithPath: arguments[5], isDirectory: true)
    var entry: String?
    if arguments.count == 8 {
        guard arguments[6] == "--entry" else { fail("unknown option " + arguments[6]) }
        entry = arguments[7]
    }
    do {
        switch engine {
        case "ink":
            try GameInkAdapter.buildArtifact(projectAt: project, to: artifact, resources: resources, entry: entry)
        case "microstudio":
            guard entry == nil else { fail("microStudio has no entry option") }
            try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact, resources: resources)
        default:
            fail("unsupported engine " + engine)
        }
        let index = artifact.appendingPathComponent("index.html")
        let bytes = try Data(contentsOf: index)
        let manifest = try Data(contentsOf: artifact.appendingPathComponent("floe-artifact.json"))
        let result: [String: Any] = ["engine": engine, "project": project.path, "artifact": artifact.path,
                                     "indexSHA256": GameDigest.sha256(bytes), "indexBytes": bytes.count,
                                     "manifestSHA256": GameDigest.sha256(manifest)]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fail(String(describing: error))
    }
    exit(0)
}

guard arguments.count == 3 else { fail("usage: NarrativeFixtures <output-dir> <resources-dir>") }
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
let resources = URL(fileURLWithPath: arguments[2], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var fixtures: [Fixture] = []

    func build(_ engine: GameEngineID, _ name: String, _ title: String,
               _ create: (URL, String) throws -> Void,
               _ build: (URL, URL, URL) throws -> Void) throws {
        let project = output.appendingPathComponent(name + "-project")
        let artifact = output.appendingPathComponent(name + "-artifact")
        if FileManager.default.fileExists(atPath: project.path) { try FileManager.default.removeItem(at: project) }
        if FileManager.default.fileExists(atPath: artifact.path) { try FileManager.default.removeItem(at: artifact) }
        try create(project, title)
        try build(project, artifact, resources)
        var cartHash: String?
        for candidate in ["cart.wasm", "cart.tic"] {
            if let data = try? Data(contentsOf: project.appendingPathComponent(candidate)) {
                cartHash = GameDigest.sha256(data)
            }
        }
        let profile = switch engine {
        case .ink: GameInkAdapter.profile
        case .twine: GameTwineAdapter.profile
        case .wasm4: GameWasm4Adapter.profile
        case .tic80: GameTIC80Adapter.profile
        default: GameMicroStudioAdapter.profile
        }
        let manifestBytes = try Data(contentsOf: artifact.appendingPathComponent("floe-artifact.json"))
        fixtures.append(Fixture(engine: engine.rawValue, project: project.path, artifact: artifact.path,
                                entry: profile.entry, runtimeVersion: profile.runtimeVersion,
                                license: profile.license, cartSHA256: cartHash,
                                manifestSHA256: GameDigest.sha256(manifestBytes)))
    }

    try build(.ink, "ink", "森林邮差", { try GameInkAdapter.createProject(at: $0, title: $1) },
              { try GameInkAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })
    try build(.twine, "twine", "森林邮差", { try GameTwineAdapter.createProject(at: $0, title: $1) },
              { try GameTwineAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })
    try build(.wasm4, "wasm4", "Postie Dot", { try GameWasm4Adapter.createProject(at: $0, title: $1) },
              { try GameWasm4Adapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })
    try build(.tic80, "tic80", "TIC Postie", { try GameTIC80Adapter.createProject(at: $0, title: $1) },
              { try GameTIC80Adapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })
    try build(.microStudio, "microstudio", "micro Postie", { try GameMicroStudioAdapter.createProject(at: $0, title: $1) },
              { try GameMicroStudioAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })

    let data = try JSONEncoder().encode(fixtures.sorted { $0.engine < $1.engine })
    try data.write(to: output.appendingPathComponent("fixtures.json"))
    print(String(decoding: data, as: UTF8.self))
} catch {
    fail(String(describing: error))
}
