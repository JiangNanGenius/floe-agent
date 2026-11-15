// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

/// Adapter whose parameter files are "binary": a 4-byte magic prefix plus
/// JSON payload. Mirrors an RPG rxdata/rvdata owner binding without claiming
/// the real format (that is FloeRPGProjectKit's job).
private struct BinaryParameterAdapter: GameEditingAdapter {
    let engine: GameEngineID = .rpgMakerVXAce
    static let magic = Data("BIN1".utf8)

    func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind? {
        path.value.hasSuffix(".rvdata") ? .data : nil
    }
    func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema] {
        [TestSupport.sampleSchema()]
    }
    func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding? { nil }
    func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding? { nil }
    func parameterBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterBinding? {
        guard path.value.hasSuffix(".rvdata") else { return nil }
        return GameParameterBinding(
            decodeDataToJSON: { data in
                guard data.count > 4, data.prefix(4) == Self.magic else {
                    throw GameProjectError.invalidManifest("parameter.magic")
                }
                return Data(data.dropFirst(4))
            },
            encodeJSONToData: { json in Self.magic + json })
    }
}

@Suite("Engine parameter codec binding")
struct ParameterBindingTests {
    func makeSession(_ name: String) async throws -> (FileGameProjectRepository, GameEditingSession) {
        let (_, repository) = try TestSupport.makeRepository(name: name)
        let projectRoot = try TestSupport.makeTemporaryDirectory(name + "-source")
        try TestSupport.createSampleProject(at: projectRoot)
        // Add a binary parameter document alongside the JSON sample.
        let binary = BinaryParameterAdapter.magic + (try TestSupport.jsonBytes([
            "characters": [["id": 1, "name": "Mira", "level": 3, "class": "mage",
                            "customField": ["note": "keep"]]]
        ]))
        try binary.write(to: projectRoot.appendingPathComponent("data/Actors.rvdata"))
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample", engine: .rpgMakerVXAce)
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: BinaryParameterAdapter())
        return (repository, session)
    }

    @Test("Binary parameter files edit through the codec and stay binary")
    @MainActor
    func binaryRoundTrip() async throws {
        let (repository, session) = try await makeSession("parambind")
        let path = try GameRelativePath("data/Actors.rvdata")
        let adapter = BinaryParameterAdapter()
        let binding = try #require(adapter.parameterBinding(for: path, in: session.baseProject))
        let schema = TestSupport.sampleSchema()

        let document = try await session.parameterDocument(at: path, binding: binding, schema: schema)
        #expect(document.value(for: schema.fields[0]) == .string("Mira"))

        try await session.editParameterDocument(at: path, binding: binding, schema: schema,
            summary: GameEditCopy("Set level", "设置等级")) { document in
            try document.set(.number(12), for: schema.fields[1])
        }
        #expect(session.isDirty)

        // The working bytes remain engine-native binary with the magic prefix.
        let working = try await session.documentBytes(at: path)
        #expect(working.prefix(4) == BinaryParameterAdapter.magic)

        let saved = try await session.save()
        let storedBytes = try await repository.read(session.projectID, owner: TestSupport.owner,
                                                    revision: saved.revision, path: path)
        #expect(storedBytes.prefix(4) == BinaryParameterAdapter.magic)
        let decoded = try binding.decodeDataToJSON(storedBytes)
        let reopened = try ParameterDocument(bytes: decoded, schema: schema)
        #expect(reopened.value(for: schema.fields[1]) == .number(12))
        #expect(reopened.value(for: schema.fields[0]) == .string("Mira"))
        #expect(try JSONValue.parse(decoded)["characters"]?[0]?["customField"]?["note"] == .string("keep"))

        // Undo restores the exact original binary bytes.
        try await session.undo()
        let reverted = try await session.documentBytes(at: path)
        #expect(reverted == (BinaryParameterAdapter.magic + (try TestSupport.jsonBytes([
            "characters": [["id": 1, "name": "Mira", "level": 3, "class": "mage",
                            "customField": ["note": "keep"]]]
        ]))))
    }

    @Test("Default adapters expose no parameter codec and JSON keeps working")
    @MainActor
    func defaultIsRawJSON() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "paramdefault")
        let projectRoot = try TestSupport.makeTemporaryDirectory("paramdefault-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        let path = try GameRelativePath("data/characters.json")
        #expect(session.adapter.parameterBinding(for: path, in: session.baseProject) == nil)
        let schema = TestSupport.sampleSchema()
        let document = try await session.parameterDocument(at: path, binding: nil, schema: schema)
        #expect(document.value(for: schema.fields[0]) == .string("Mira"))
        try await session.editParameterDocument(at: path, binding: nil, schema: schema,
            summary: GameEditCopy("Rename", "改名")) { document in
            try document.set(.string("Aster"), for: document.schema.fields[0])
        }
        let bytes = try await session.documentBytes(at: path)
        let json = try JSONValue.parse(bytes)
        #expect(json["characters"]?[0]?["name"] == .string("Aster"))
    }

    @Test("A codec that cannot read the file fails without touching bytes")
    @MainActor
    func codecFailureIsHonest() async throws {
        let (_, session) = try await makeSession("paramfail")
        let path = try GameRelativePath("data/Actors.rvdata")
        let adapter = BinaryParameterAdapter()
        let binding = try #require(adapter.parameterBinding(for: path, in: session.baseProject))
        // Corrupt the prefix: decode must throw, and the session must not write.
        try await session.editDocument(at: path, summary: GameEditCopy("Corrupt", "损坏")) { bytes in
            var data = bytes
            if data.count > 4 { data.replaceSubrange(0..<4, with: Data("XXXX".utf8)) }
            return data
        }
        let before = try await session.documentBytes(at: path)
        do {
            _ = try await session.parameterDocument(at: path, binding: binding, schema: TestSupport.sampleSchema())
            Issue.record("Decode should fail on a foreign prefix")
        } catch {}
        #expect(try await session.documentBytes(at: path) == before)
    }
}
