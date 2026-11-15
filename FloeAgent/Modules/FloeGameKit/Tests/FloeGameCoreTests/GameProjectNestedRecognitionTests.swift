// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class NestedFixture {
    let root: URL

    init(_ files: [String: Data] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGameNestedTests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files { try write(path, data) }
    }

    convenience init(_ files: [String: String]) throws {
        try self.init(files.mapValues { Data($0.utf8) })
    }

    func write(_ path: String, _ data: Data) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic])
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private func snapshot(_ root: URL) throws -> [String: Int] {
    var result: [String: Int] = [:]
    let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
    while let item = enumerator?.nextObject() as? URL {
        let relative = String(item.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { continue }
        let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        result[relative] = values.isDirectory == true ? -1 : (values.fileSize ?? 0)
    }
    return result
}

@Test func nestedGameRootsAreRecognizedWithoutRootProjectState() throws {
    let fixture = try NestedFixture([
        "one/project.godot": Data(),
        "two/project.godot": Data(),
        "three/Game.rxproj": Data()
    ])
    #expect(try GameProjectInspector().inspect(rootURL: fixture.root).candidates.isEmpty)
    let before = try snapshot(fixture.root)
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
    #expect(try snapshot(fixture.root) == before)
}

@Test func directGameRootShortCircuitsUnrelatedLargeTrees() throws {
    var files: [String: Data] = ["project.godot": Data()]
    for index in 0..<200 {
        files["docs/page\(index).html"] = Data("<html><body>Documentation</body></html>".utf8)
    }
    let fixture = try NestedFixture(files)
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
}

@Test func nestedGamesInGenericUserFoldersAreNotSilentlySkipped() throws {
    let fixture = try NestedFixture([
        "build/Alpha/project.godot": Data(),
        "dist/Beta/Game.rxproj": Data(),
        "local/Gamma/project.godot": Data()
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
}

@Test func nestedExportedWebRootIsDiscoveredEvenWithoutASourceMarker() throws {
    let fixture = try NestedFixture([
        "Exports/GD/index.html": Data("<!doctype html>".utf8),
        "Exports/GD/data.js": Data("gdjs.projectData = {};".utf8),
        "Exports/GD/gd.js": Data("// unexecuted".utf8),
        "Exports/Blank/index.html": Data("<!doctype html><html>docs</html>".utf8)
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
}

@Test func multipleNestedRootsOfTheSameEngineStayRecognized() throws {
    let fixture = try NestedFixture([
        "a/project.godot": Data(),
        "b/project.godot": Data(),
        "c/project.godot": Data()
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root))
}

@Test func unrelatedNestedNpmPackagesAndProjectJSONReturnFalse() throws {
    let fixture = try NestedFixture([
        "packages/a/package.json": Data(#"{"name":"a","dependencies":{"left-pad":"1.3.0"}}"#.utf8),
        "packages/a/src/index.js": Data("module.exports = 1\n".utf8),
        "tools/project.json": Data(#"{"name":"tool","version":1}"#.utf8),
        "tools/main.py": Data("print('tool')\n".utf8)
    ])
    #expect(try GameProjectInspector.hasGameCandidate(rootURL: fixture.root) == false)
}

@Test func unreadableRootIsAnExplicitError() throws {
    let fixture = try NestedFixture(["README.md": Data()])
    let missing = fixture.root.appendingPathComponent("does-not-exist")
    #expect(throws: GameProjectError.rootUnavailable) {
        try GameProjectInspector.hasGameCandidate(rootURL: missing)
    }
}

@Test func traversalCannotEscapeThroughRelativePaths() throws {
    #expect(throws: GameProjectError.invalidRelativePath) {
        try GameRelativePath("../outside")
    }
    #expect(throws: GameProjectError.invalidRelativePath) {
        try GameRelativePath("nested/../../outside")
    }
}

@Test func symlinkedNestedRootCannotEscapeTheCapturedRoot() throws {
    let outside = try NestedFixture(["project.godot": Data()])
    let fixture = try NestedFixture()
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("nested"),
        withDestinationURL: outside.root)
    #expect(throws: GameProjectError.unsafePath("nested")) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root)
    }
}

@Test func symlinkedNestedManifestCannotEscapeTheCapturedRoot() throws {
    let outside = try NestedFixture(["project.godot": Data()])
    let fixture = try NestedFixture(["nested/keep": Data()])
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("nested/project.godot"),
        withDestinationURL: outside.root.appendingPathComponent("project.godot"))
    #expect(throws: GameProjectError.unsafePath("nested/project.godot")) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root)
    }
}

@Test func importedFifoCannotBlockNestedPreflight() throws {
    let fixture = try NestedFixture(["nested/keep": Data()])
    let path = fixture.root.appendingPathComponent("nested/cart.wasm").path
    #expect(mkfifo(path, 0o600) == 0)
    #expect(throws: GameProjectError.unsafePath("nested/cart.wasm")) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root)
    }
}

@Test func entryBudgetIsExplicitRatherThanFalse() throws {
    let fixture = try NestedFixture([
        "nested/project.godot": Data(),
        "nested/extra.txt": Data()
    ])
    #expect(throws: GameProjectError.limitExceeded("treeEntries")) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root, maximumEntries: 2)
    }
}

@Test func rootCountBudgetIsExplicitRatherThanChoosingOne() throws {
    let fixture = try NestedFixture([
        "a/project.godot": Data(),
        "b/project.godot": Data()
    ])
    #expect(throws: GameProjectError.limitExceeded("projectRoots")) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root,
                                                  maximumEntries: 100,
                                                  maximumRoots: 1)
    }
}

@Test func invalidBudgetsAreRejectedBeforeAnyFileAccess() throws {
    let fixture = try NestedFixture(["project.godot": Data()])
    #expect(throws: GameProjectError.invalidContext) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root, maximumEntries: 0)
    }
    #expect(throws: GameProjectError.invalidContext) {
        try GameProjectInspector.hasGameCandidate(rootURL: fixture.root, maximumRoots: 0)
    }
}

@Test func cancellationIsPropagated() async throws {
    let fixture = try NestedFixture(["nested/project.godot": Data()])
    let root = fixture.root
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let task = Task {
        started.continuation.yield()
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        return try GameProjectInspector.hasGameCandidate(rootURL: root)
    }
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    task.cancel()
    release.continuation.yield()
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError from a cancelled preflight")
    } catch is CancellationError {
        // Expected: the method checks cancellation before and during scanning.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
