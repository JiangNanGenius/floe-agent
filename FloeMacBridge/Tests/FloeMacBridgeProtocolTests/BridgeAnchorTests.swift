#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import FloeMacBridgeProtocol

private final class AnchorOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeSafeFileSystem.Anchor.CreateOutcome] = []
    func append(_ outcome: BridgeSafeFileSystem.Anchor.CreateOutcome) { lock.withLock { storage.append(outcome) } }
    var values: [BridgeSafeFileSystem.Anchor.CreateOutcome] { lock.withLock { storage } }
}

@Suite("Descriptor anchored Bridge state")
struct BridgeAnchorTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func openAnchor(_ directory: URL) throws -> BridgeSafeFileSystem.Anchor {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(descriptor) }
        return try BridgeSafeFileSystem.Anchor(directoryFD: descriptor)
    }
    private func execute(_ binary: String, _ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = arguments
        try child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw BridgeFailure.unsafePath }
    }

    @Test("A separate process replaces the original path but writes stay on the pinned directory")
    func ancestorReplacementDoesNotRedirect() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("isolated", isDirectory: true)
        let moved = base.appendingPathComponent("moved", isDirectory: true)
        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let old = legacy.appendingPathComponent("pair.json")
        try Data("legacy".utf8).write(to: old)
        let anchor = try openAnchor(original)
        try execute("/bin/mv", [original.path, moved.path])
        try execute("/bin/ln", ["-s", legacy.path, original.path])
        #expect(try anchor.createNew(Data("separate".utf8), named: "pair.json") == .published)
        #expect(try anchor.readExisting(named: "pair.json") == Data("separate".utf8))
        #expect(try Data(contentsOf: moved.appendingPathComponent("pair.json")) == Data("separate".utf8))
        #expect(try Data(contentsOf: old) == Data("legacy".utf8))
    }

    @Test("competing creators never overwrite and failed stages are retained")
    func concurrentCreateNoOverwrite() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let anchor = try openAnchor(base), outcomes = AnchorOutcomes()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do { outcomes.append(try anchor.createNew(Data("value-\(index)".utf8), named: "pair.json")) }
            catch { Issue.record("Unexpected create error: \(error)") }
        }
        let values = outcomes.values
        #expect(values.filter { $0 == .published }.count == 1)
        let retained = values.compactMap { outcome -> String? in
            if case .notPublished(let name, let code) = outcome, code == EEXIST { return name }
            return nil
        }
        #expect(retained.count == 11)
        for name in retained {
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path))
        }
        let result = try String(decoding: anchor.readExisting(named: "pair.json"), as: UTF8.self)
        #expect(result.hasPrefix("value-"))
    }

    @Test("directory fsync failure after rename is published but unconfirmed")
    func uncertainDirectorySync() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let fd = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(fd) }
        let anchor = try BridgeSafeFileSystem.Anchor(directoryFD: fd, syncDirectory: { _ in -1 })
        #expect(try anchor.createNew(Data("candidate".utf8), named: "state") == .publishedUnconfirmed)
        #expect(try anchor.readExisting(named: "state") == Data("candidate".utf8))
        let retry = try anchor.createNew(Data("replacement".utf8), named: "state")
        if case .notPublished(_, let code) = retry { #expect(code == EEXIST) }
        else { Issue.record("An unconfirmed published file was overwritten") }
        #expect(try anchor.readExisting(named: "state") == Data("candidate".utf8))
    }

    @Test("a replaced published entry is reported unconfirmed rather than attributed to our fd")
    func replacedEntryAfterPublishIsUnconfirmed() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let fd = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(fd) }
        let anchor = try BridgeSafeFileSystem.Anchor(directoryFD: fd, syncDirectory: { directory in
            guard Darwin.renameat(directory, "state", directory, "moved") == 0 else { return -1 }
            let foreign = Darwin.openat(directory, "state", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard foreign >= 0 else { return -1 }
            let bytes = Array("foreign".utf8)
            let written = bytes.withUnsafeBytes { raw in Darwin.write(foreign, raw.baseAddress!, raw.count) }
            Darwin.close(foreign)
            guard written == bytes.count else { return -1 }
            return Darwin.fsync(directory)
        })
        let outcome = try anchor.createNew(Data("candidate".utf8), named: "state")
        #expect(try Data(contentsOf: base.appendingPathComponent("moved")) == Data("candidate".utf8))
        #expect(try Data(contentsOf: base.appendingPathComponent("state")) == Data("foreign".utf8))
        #expect(outcome == .publishedUnconfirmed)
    }

    @Test("a replaced stage entry is refused without deleting either file")
    func replacedStageBeforePublishIsRefused() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let fd = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(fd) }
        let anchor = try BridgeSafeFileSystem.Anchor(directoryFD: fd, syncDirectory: { Darwin.fsync($0) },
            beforePublish: { directory, staged in
                guard Darwin.renameat(directory, staged, directory, "moved-stage") == 0 else { return }
                let replacement = Darwin.openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard replacement >= 0 else { return }
                let bytes = Array("foreign".utf8)
                _ = bytes.withUnsafeBytes { raw in Darwin.write(replacement, raw.baseAddress!, raw.count) }
                Darwin.close(replacement)
            })
        let outcome = try anchor.createNew(Data("candidate".utf8), named: "state")
        guard case .notPublished(let stage, let code) = outcome else {
            Issue.record("Replaced stage was reported published: \(outcome)"); return
        }
        #expect(code == ESTALE)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("state").path))
        #expect(try Data(contentsOf: base.appendingPathComponent("moved-stage")) == Data("candidate".utf8))
        #expect(try Data(contentsOf: base.appendingPathComponent(stage)) == Data("foreign".utf8))
    }

    @Test("invalid descriptors, untrusted names, oversized data and link reads fail closed")
    func invalidInputs() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let regular = base.appendingPathComponent("file")
        try Data("example".utf8).write(to: regular)
        let file = Darwin.open(regular.path, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else { throw BridgeFailure.unsafePath }
        #expect(throws: (any Error).self) { _ = try BridgeSafeFileSystem.Anchor(directoryFD: file) }
        Darwin.close(file)
        #expect(throws: (any Error).self) { _ = try BridgeSafeFileSystem.Anchor(directoryFD: file) }
        let anchor = try openAnchor(base)
        for name in ["", ".", "..", "a/b", "a\0b", ".floe-stage-injected"] {
            #expect(throws: (any Error).self) { _ = try anchor.createNew(Data(), named: name) }
        }
        #expect(throws: (any Error).self) {
            _ = try anchor.createNew(Data(repeating: 0, count: BridgeSafeFileSystem.Anchor.maximumCreateBytes + 1), named: "big")
        }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: regular)
        #expect(throws: (any Error).self) { _ = try anchor.readExisting(named: "link") }
        #expect(Darwin.link(regular.path, base.appendingPathComponent("hardlink").path) == 0)
        #expect(throws: (any Error).self) { _ = try anchor.readExisting(named: "hardlink") }
        #expect(Darwin.chmod(base.path, 0o755) == 0)
        #expect(throws: (any Error).self) { _ = try openAnchor(base) }
        #expect(throws: (any Error).self) { _ = try anchor.createNew(Data("x".utf8), named: "after-permission-change") }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("after-permission-change").path))
    }
}
#endif
