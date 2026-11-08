// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeElectronicsCore
@testable import FloeApp

@MainActor @Suite("Electronics multi-file output publication", .serialized)
struct ElectronicsOutputPublicationTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ElectronicsPublication-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func project() -> EDAProject {
        var value = EDAProject(title: "Publication original")
        value.revision = 7
        var board = EDABoard(outline: [.init(0,0),.init(30,0),.init(30,20),.init(0,20)])
        board.edgePlated = false
        board.tracks = [.init(netID: "A", width: 0.3, points: [.init(2,2),.init(8,2)]),
                        .init(netID: "B", layer: "B.Cu", width: 0.4, points: [.init(2,5),.init(8,5)])]
        board.holes = [.init(position: .init(5,8), diameter: 0.8, plated: false),
                       .init(position: .init(12,8), diameter: 1.0, plated: false, endPosition: .init(16,10))]
        value.boards = [board]
        return value
    }
    private func record(_ project: EDAProject) -> PersonalContentRecord {
        .init(id: project.id, kind: .electronics, title: project.title, createdAt: project.createdAt,
              modifiedAt: project.modifiedAt, folders: [], relativePath: "Publication original")
    }
    private func context() -> ToolContext {
        var value = ToolContext(runID: UUID(), toolCallID: "publish-gerber", cancellation: CancellationToken(), conversationID: UUID())
        value.executionToolName = "studio.run"
        return value
    }
    private func runRoot(_ context: ToolContext) throws -> URL {
        try FloeArtifactStore.root().appendingPathComponent("RunOutputs", isDirectory: true)
            .appendingPathComponent(context.runID.uuidString, isDirectory: true)
    }
    private func exact(_ receipt: RunOutputFile, file: EDAExchangeFile, context: ToolContext) throws {
        #expect(receipt.displayName == file.name && receipt.byteCount == file.data.count && receipt.sha256 == file.sha256)
        #expect(receipt.runID == context.runID && receipt.taskID == context.conversationID && receipt.environmentID == context.environmentID)
        #expect(receipt.producerCallID == context.toolCallID && receipt.producerTool == "studio.run" && receipt.role == .userFile)
        #expect(receipt.isCanonicalForCurrentRun && receipt.hasRuntimeConsistentIdentity)
        #expect(RunOutputFile.isValidBoundedField(receipt.slot, maximumCharacters: RunOutputFile.maximumSlotCharacters))
        guard case .verified(let url) = RunOutputSnapshotStore.verify(receipt) else {
            Issue.record("Published bytes did not verify through the real snapshot reader"); return
        }
        #expect(try Data(contentsOf: url) == file.data)
    }
    private func modified(_ receipt: RunOutputFile) throws -> Date {
        let url = try FloeArtifactStore.root().appendingPathComponent(receipt.relativePath)
        return try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    @Test("The actual Host exports all native files and replays one call without changing the saved original")
    func multiFileRuntimePreservesSourceAndReplaysTheSameCall() async throws {
        let directory = try scratch(), original = project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory.appendingPathComponent("Electronics"), project: original)
        let before = try await store.load(), saved = try ElectronicsSavedSnapshot(id: original.id, directory: directory)
        var binding = context()
        defer { if let root = try? runRoot(binding) { try? FileManager.default.removeItem(at: root) } }
        for format in [EDAExportFormat.gerber, .excellon] {
            binding.toolCallID = "publish-" + format.rawValue
            let expected = try EDAExchange.export(original, format: format, boardID: original.boards[0].id)
            #expect(expected.files.count > 1)
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["expectedRevision": "7", "boardID": original.boards[0].id.uuidString, "format": format.rawValue]), as: UTF8.self)
            let first = try await StudioElectronicsRuntime.run(record: record(original), directory: directory, action: "eda.export", inputJSON: input, context: binding) { try saved.validate() }
            #expect(first.outputFiles.map(\.displayName) == expected.files.map(\.name))
            #expect(Set(first.outputFiles.map(\.outputID)).count == expected.files.count)
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(first.summary.utf8)) as? [String: Any])
            #expect(receipt["revision"] as? String == "7" && receipt["sourceSHA256"] as? String == saved.digest)
            #expect((receipt["projectID"] as? String).flatMap(UUID.init(uuidString:)) == original.id)
            var times: [String: Date] = [:]
            for (file, published) in zip(expected.files, first.outputFiles) {
                try exact(published, file: file, context: binding)
                times[published.outputID] = try modified(published)
                if file.mimeType == "application/json" {
                    let manifest = try #require(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
                    #expect(manifest["sourceRevision"] as? String == "7")
                    #expect((manifest["projectID"] as? String).flatMap(UUID.init(uuidString:)) == original.id)
                }
            }
            guard case .sealed(let sealed) = RunOutputSnapshotStore.seal(drafts: first.outputFiles, runID: binding.runID, taskID: binding.conversationID, environmentID: binding.environmentID, callID: try #require(binding.toolCallID), toolName: "studio.run") else {
                Issue.record("Real runtime seal rejected the distinct file identities"); return
            }
            #expect(sealed == first.outputFiles)
            let replay = try await StudioElectronicsRuntime.run(record: record(original), directory: directory, action: "eda.export", inputJSON: input, context: binding) { try saved.validate() }
            #expect(replay.outputFiles == first.outputFiles && replay.summary == first.summary)
            for published in replay.outputFiles { #expect(try modified(published) == times[published.outputID]) }
        }
        #expect(try await store.load() == before)
        #expect(try ElectronicsSavedSnapshot(id: original.id, directory: directory).bytes == saved.bytes)
        #expect(try await store.history().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Electronics/Exports").path).isEmpty)
    }

    @Test("Original names survive reordered staging; changed bytes still conflict and legacy single-output slots stay stable")
    func reorderedRetriesAndChangedBytesKeepHonestIdentities() async throws {
        let directory = try scratch(), binding = context()
        defer {
            try? FileManager.default.removeItem(at: directory)
            if let root = try? runRoot(binding) { try? FileManager.default.removeItem(at: root) }
        }
        var files = try EDAExchange.export(project(), format: .gerber).files
        let longName = "铜区-" + String(repeating: "x", count: 235) + ".gbr"
        #expect(RunOutputFile.isValidDisplayName(longName))
        files.append(.init(name: longName, mimeType: "application/vnd.gerber", data: Data("G04 long-name slot fixture*\nM02*\n".utf8)))
        var first: [String: RunOutputFile] = [:], times: [String: Date] = [:]
        for (stageName, values) in [("stage-A", files), ("stage-B", Array(files.reversed()))] {
            let stage = directory.appendingPathComponent(stageName)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            for file in values {
                let url = stage.appendingPathComponent(file.name)
                try file.data.write(to: url, options: .withoutOverwriting)
                let published = try await StudioResultPublication.publish(file: url, projectRoot: directory, action: "eda.export", fileKey: file.name, context: binding, validateSource: {}).file
                try exact(published, file: file, context: binding)
                if stageName == "stage-A" { first[file.name] = published; times[file.name] = try modified(published) }
                else { #expect(published == first[file.name]); #expect(try modified(published) == times[file.name]) }
            }
        }
        #expect(Set(first.values.map(\.outputID)).count == files.count)
        let changed = try #require(files.first), source = directory.appendingPathComponent("stage-B").appendingPathComponent(changed.name)
        try Data("different bytes under the same logical file".utf8).write(to: source)
        do {
            _ = try await StudioResultPublication.publish(file: source, projectRoot: directory, action: "eda.export", fileKey: changed.name, context: binding, validateSource: {})
            Issue.record("Same-call same-name changed bytes were silently accepted")
        } catch let error as RunOutputSnapshotError { #expect(error == .conflict(displayName: changed.name)) }
        for file in files { try exact(try #require(first[file.name]), file: file, context: binding) }
        var anotherCall = binding; anotherCall.toolCallID = "different-real-call"
        let originalSource = directory.appendingPathComponent("stage-A").appendingPathComponent(changed.name)
        let next = try await StudioResultPublication.publish(file: originalSource, projectRoot: directory, action: "eda.export", fileKey: changed.name, context: anotherCall, validateSource: {}).file
        #expect(next.outputID != first[changed.name]?.outputID)
        var legacy = binding; legacy.toolCallID = "legacy-single-output"
        let single = try await StudioResultPublication.publish(file: originalSource, projectRoot: directory, action: "eda.netlist", context: legacy, validateSource: {}).file
        #expect(single.slot == "studio-eda.netlist")
        #expect(single.outputID == RunOutputFile.derivedOutputID(runID: legacy.runID, producerCallID: "legacy-single-output", slot: "studio-eda.netlist"))
    }

    @Test("A file key grants no path access and an aliased export directory cannot publish")
    func sourceAndExportDirectoryBoundariesStillRefuseAliases() async throws {
        let directory = try scratch(), binding = context(), original = project()
        defer {
            try? FileManager.default.removeItem(at: directory)
            if let root = try? runRoot(binding) { try? FileManager.default.removeItem(at: root) }
        }
        let authorized = directory.appendingPathComponent("Original"), outside = directory.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = outside.appendingPathComponent("Copper-L01.gbr")
        try Data("G04 outside-root fixture*\nM02*\n".utf8).write(to: source)
        let alias = authorized.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        for file in [source, alias] {
            do {
                _ = try await StudioResultPublication.publish(file: file, projectRoot: authorized, action: "eda.export", fileKey: file.lastPathComponent, context: binding, validateSource: {})
                Issue.record("A file key bypassed the real anchored source boundary")
            } catch is PersonalContentPreviewError { }
        }
        let store = try await EDAProjectStore.create(root: authorized.appendingPathComponent("Electronics"), project: original)
        let before = try await store.load()
        try FileManager.default.createSymbolicLink(at: authorized.appendingPathComponent("Electronics/Exports"), withDestinationURL: outside)
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["expectedRevision": "7", "format": "gerber"]), as: UTF8.self)
        do {
            _ = try await StudioElectronicsRuntime.run(record: record(original), directory: authorized, action: "eda.export", inputJSON: input, context: binding, validateOwner: {})
            Issue.record("An aliased export directory was accepted")
        } catch let error as PersonalContentError {
            guard case .changedDocument = error else { Issue.record("Unexpected native export error"); return }
        }
        #expect(try await store.load() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == [source.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: try runRoot(binding).path))
    }
}
#endif
