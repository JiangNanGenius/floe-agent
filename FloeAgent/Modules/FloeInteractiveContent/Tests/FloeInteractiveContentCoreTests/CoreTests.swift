// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeInteractiveContentCore

private func owner() -> ContentOwner {
    ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
}
private func document(_ identity: ContentOwner = owner(), html: String = "<p>Example</p>") throws -> InteractiveDocument {
    try InteractiveDocument(owner: identity, kind: "custom-demonstration", title: "Example",
                            html: html, fallbackText: "Text alternative")
}
private func fixtureDirectory() throws -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CodexBuild/FloeInteractiveContent/test-fixtures")
    let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func boundedJSONAndNonFiniteValuesFail() throws {
    #expect(throws: (any Error).self) { try InteractiveLimits.checkState(.number(.infinity)) }
    #expect(throws: (any Error).self) {
        try InteractiveLimits.checkState(.string(String(repeating: "字", count: 12_000)))
    }
    let deep = Data((String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)).utf8)
    #expect(throws: InteractiveError.self) {
        try InteractiveLimits.checkJSON(deep, maximum: 100)
    }
}

@Test func documentVersionAndCustomKinds() throws {
    let doc = try document()
    let encoded = try JSONEncoder().encode(doc)
    #expect(try InteractiveDocument.decode(encoded) == doc)
    #expect(throws: InteractiveError.self) {
        try InteractiveDocument(owner: owner(), kind: "anything", title: "", html: "<p>x</p>",
                                fallbackText: "Text", schemaVersion: 2)
    }
    let textCode = InteractiveResponsePart.text("Example: <button>Code, not active HTML</button>")
    let parts = [textCode, .interactive(InteractiveReference(document: doc)),
                 .existingQuestion(.init(requestID: "trusted-request-id")), .text("After")]
    #expect(try JSONDecoder().decode([InteractiveResponsePart].self,
                                    from: JSONEncoder().encode(parts)) == parts)
}

@Test func fileStateReopensAndRejectsStaleCAS() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let doc = try document()
    let first = try FileInteractiveStateRepository(directory: directory)
    let state = try await first.compareAndSwap(document: doc, expectedRevision: 0,
        modelContent: .object(["total": .number(2_100)]), privateContent: .object(["people": .number(20)]))
    #expect(state.revision == 1)
    let reopened = try FileInteractiveStateRepository(directory: directory)
    #expect(try await reopened.load(document: doc) == state)
    await #expect(throws: InteractiveError.self) {
        try await reopened.compareAndSwap(document: doc, expectedRevision: 0,
                                           modelContent: .null, privateContent: .null)
    }
    #expect(try await first.load(document: doc) == state)
}

@Test func independentStoresDoNotLoseConcurrentUpdates() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let doc = try document()
    let first = try FileInteractiveStateRepository(directory: directory)
    let second = try FileInteractiveStateRepository(directory: directory)
    let successes = await withTaskGroup(of: Int.self, returning: Int.self) { group in
        for index in 0..<12 {
            group.addTask {
                do {
                    let store = index.isMultiple(of: 2) ? first : second
                    _ = try await store.compareAndSwap(document: doc, expectedRevision: 0,
                        modelContent: .number(Double(index)), privateContent: .null)
                    return 1
                } catch { return 0 }
            }
        }
        var count = 0
        for await result in group { count += result }
        return count
    }
    #expect(successes == 1)
    #expect(try await first.load(document: doc).revision == 1)
}

@Test func changedContentCannotAdoptOldState() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = owner()
    let original = try document(identity)
    let store = try FileInteractiveStateRepository(directory: directory)
    _ = try await store.compareAndSwap(document: original, expectedRevision: 0,
                                       modelContent: .number(10), privateContent: .null)
    let changed = try document(identity, html: "<p>Unversioned replacement</p>")
    await #expect(throws: InteractiveError.self) { try await store.load(document: changed) }
    #expect(try await store.load(document: original).modelContent == .number(10))
}

@Test func corruptRecordIsPreservedAndFailsClosed() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let doc = try document()
    let url = directory.appendingPathComponent(doc.owner.storageKey + ".json")
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: url)
    let store = try FileInteractiveStateRepository(directory: directory)
    await #expect(throws: (any Error).self) {
        try await store.compareAndSwap(document: doc, expectedRevision: 0,
                                       modelContent: .null, privateContent: .null)
    }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func symlinkStateAndDirectoryAreRejected() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("untouched")
    try Data("original".utf8).write(to: target)
    let doc = try document()
    let statePath = directory.appendingPathComponent(doc.owner.storageKey + ".json")
    try FileManager.default.createSymbolicLink(at: statePath, withDestinationURL: target)
    let store = try FileInteractiveStateRepository(directory: directory)
    await #expect(throws: InteractiveError.self) { try await store.load(document: doc) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    #expect(throws: InteractiveError.self) { try FileInteractiveStateRepository(directory: alias) }
}

@Test func temporarySessionIgnoresSuppliedDiskAndFencesLateWrites() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = try FileInteractiveStateRepository(directory: directory)
    let doc = try document()
    let session = try InteractiveSession(document: doc, expectedOwner: doc.owner,
                                        persistence: .temporary, durableRepository: disk)
    let seed = try await session.activateRenderer()
    _ = try await session.receive(.init(leaseID: seed.leaseID, sequence: 1, event: .state,
        expectedRevision: 0, modelContent: .number(7), privateContent: .string("draft")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    try await session.close()
    await #expect(throws: InteractiveError.self) {
        try await session.receive(.init(leaseID: seed.leaseID, sequence: 2, event: .ready))
    }
    let replacement = try InteractiveSession(document: doc, expectedOwner: doc.owner, persistence: .temporary)
    #expect(try await replacement.snapshot().revision == 0)
}

@Test func leaseReplacementRestoresStateAndRejectsOldRenderer() async throws {
    let doc = try document()
    let session = try InteractiveSession(document: doc, expectedOwner: doc.owner, persistence: .temporary)
    let initial = try await session.activateRenderer()
    _ = try await session.receive(.init(leaseID: initial.leaseID, sequence: 1, event: .state,
        expectedRevision: 0, modelContent: .null, privateContent: .object(["slider": .number(42)])))
    let expanded = try await session.activateRenderer()
    #expect(expanded.leaseID != initial.leaseID)
    #expect(expanded.state.privateContent["slider"] == .number(42))
    await #expect(throws: InteractiveError.self) {
        try await session.receive(.init(leaseID: initial.leaseID, sequence: 2, event: .state,
            expectedRevision: 1, modelContent: .null, privateContent: .number(0)))
    }
    #expect(try await session.snapshot().revision == 1)
}

@Test func duplicateMessagesAndForeignOwnerAreRejected() async throws {
    let doc = try document()
    #expect(throws: InteractiveError.self) {
        try InteractiveSession(document: doc, expectedOwner: owner(), persistence: .temporary)
    }
    let session = try InteractiveSession(document: doc, expectedOwner: doc.owner, persistence: .temporary)
    let seed = try await session.activateRenderer()
    _ = try await session.receive(.init(leaseID: seed.leaseID, sequence: 1, event: .ready))
    await #expect(throws: InteractiveError.self) {
        try await session.receive(.init(leaseID: seed.leaseID, sequence: 1, event: .ready))
    }
    #expect(throws: (any Error).self) {
        try RuntimeMessage.decode(Data(#"{"version":1,"event":"callTool"}"#.utf8))
    }
}

@Test func malformedResizeDoesNotChangeState() async throws {
    let doc = try document()
    let session = try InteractiveSession(document: doc, expectedOwner: doc.owner, persistence: .temporary)
    let seed = try await session.activateRenderer()
    await #expect(throws: InteractiveError.self) {
        try await session.receive(.init(leaseID: seed.leaseID, sequence: 1, event: .resize, height: 1_000_000))
    }
    #expect(try await session.snapshot().revision == 0)
}

@Test func explicitNullSurvivesWireDecodeAndClearsState() async throws {
    let doc = try document()
    let session = try InteractiveSession(document: doc, expectedOwner: doc.owner, persistence: .temporary)
    let seed = try await session.activateRenderer()
    let message = RuntimeMessage(leaseID: seed.leaseID, sequence: 1, event: .state,
                                  expectedRevision: 0, modelContent: .null, privateContent: .null)
    let decoded = try RuntimeMessage.decode(JSONEncoder().encode(message))
    #expect(decoded.modelContent == .some(.null))
    #expect(decoded.privateContent == .some(.null))
    let receipt = try await session.receive(decoded)
    #expect(receipt.state.revision == 1)
    #expect(receipt.state.privateContent == .null)
}

@Test func exportedShellContainsNoHostIdentityAndCannotInlineInjectParent() throws {
    let doc = try document(html: #"<script>window.parent.document.body.innerHTML="escaped";</script>"#)
    let state = InteractiveState(document: doc, privateContent: .object(["slider": .number(42)]))
    let seed = RuntimeSeed(leaseID: UUID(), state: state)
    let rendered = try InteractiveHTML.render(document: doc, seed: seed)
    let exported = String(decoding: try InteractiveHTML.export(document: doc, state: state), as: UTF8.self)
    #expect(rendered.contains(#"sandbox="allow-scripts""#))
    #expect(!rendered.contains("allow-same-origin"))
    #expect(!rendered.contains(doc.html))
    for value in [doc.owner.conversationID.uuidString, doc.owner.runID.uuidString,
                  doc.owner.messageID.uuidString, seed.leaseID.uuidString] {
        #expect(!exported.contains(value))
    }
    let marker = "const seed=JSON.parse(decode('"
    let start = try #require(exported.range(of: marker)?.upperBound)
    let end = try #require(exported[start...].firstIndex(of: "'"))
    let payload = try #require(Data(base64Encoded: String(exported[start..<end])))
    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(object["native"] as? Bool == false)
    #expect(object["privateContent"] != nil)
    #expect(object["owner"] == nil)
    #expect(object["leaseID"] as? String != seed.leaseID.uuidString)
    let data = try InteractiveHTML.exportData(document: doc, state: state)
    let dataObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(dataObject["owner"] == nil)
    #expect(dataObject["privateContent"] != nil)
}

@Test func examplesAreBilingualAndNotAnEngineWhitelist() throws {
    for example in InteractiveExample.allCases {
        let zh = try InteractiveExamples.document(example, owner: owner(), chinese: true)
        let en = try InteractiveExamples.document(example, owner: owner(), chinese: false)
        #expect(zh.title != en.title)
        #expect(zh.html.contains("floeInteractive"))
        #expect(try InteractiveHTML.export(document: zh, state: InteractiveState(document: zh)).count > 1_000)
    }
    let custom = try document(html: "<button onclick='this.textContent=7'>Independent content</button>")
    #expect(custom.kind == "custom-demonstration")
}
