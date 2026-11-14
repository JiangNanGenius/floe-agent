import Darwin
import Foundation
import FloeCore
import XCTest
@testable import FloeExecution

final class RuntimeV2BlobCopySpaceTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let margin: Int64 = 32 << 20
    private let diskBytes: Int64 = 64 << 20

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func makeStore(available: Int64, allowClone: Bool) async throws -> RuntimeV2Store {
        let layout = RuntimeV2Layout(root: root)
        let seams = RuntimeV2BlobStore.Seams(
            cloneFile: { source, destination in allowClone && clonefile(source, destination, 0) == 0 },
            availableBytes: { _ in available }
        )
        let store = RuntimeV2Store(layout: layout, blobSeams: seams)
        _ = try await store.prepareAndRecover(build: "test")
        return store
    }

    private func sparseSource() throws -> URL {
        let url = root.appendingPathComponent("disk")
        try Data("first".utf8).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(diskBytes - 4))
        try file.write(contentsOf: Data("last".utf8))
        return url
    }

    func testSparseImageCanBeIngestedAndExpandedUsingOnlyCloneHeadroom() async throws {
        let store = try await makeStore(available: margin, allowClone: true)
        let source = try sparseSource()
        let digest = try FloeDigest.sha512Hex(ofFileAt: source)
        _ = try await store.blobs.ingest(sourceURL: source, expectedSHA512: digest, expectedBytes: diskBytes, retainFor: "image")
        let output = root.appendingPathComponent("expanded")
        let report = try await store.blobs.materialize(digest: digest, at: output, writable: true)
        XCTAssertEqual(report.mode, .clone)
        XCTAssertEqual(report.logicalBytes, diskBytes)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: output), digest)
        let handle = try FileHandle(forWritingTo: output)
        try handle.write(contentsOf: Data("edit".utf8))
        try handle.close()
        try await store.blobs.verify(digest: digest)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: source), digest)
    }

    func testForcedCopyPreservesHolesAndFullContentsWithLessThanLogicalSizeFree() async throws {
        let store = try await makeStore(available: margin + (1 << 20), allowClone: false)
        let source = try sparseSource()
        let digest = try FloeDigest.sha512Hex(ofFileAt: source)
        _ = try await store.blobs.ingest(sourceURL: source, expectedSHA512: digest, expectedBytes: diskBytes, retainFor: "image")
        let output = root.appendingPathComponent("expanded")
        let report = try await store.blobs.materialize(digest: digest, at: output)
        XCTAssertEqual(report.mode, .copy)
        XCTAssertEqual(report.logicalBytes, diskBytes)
        XCTAssertLessThan(try XCTUnwrap(report.allocatedBytes), 1 << 20)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: output), digest)
    }

    func testInsufficientSpaceForDenseCopyPreservesSourceAndReleasesClaim() async throws {
        let store = try await makeStore(available: margin + 8192, allowClone: false)
        let source = root.appendingPathComponent("kernel")
        let data = Data(repeating: 0x2a, count: 65536)
        try data.write(to: source)
        let digest = FloeDigest.sha512Hex(data)
        do {
            _ = try await store.blobs.ingest(sourceURL: source, expectedSHA512: digest, expectedBytes: Int64(data.count), retainFor: "image")
            XCTFail("the copy should exceed its budget")
        } catch RuntimeV2Error.insufficientSpace(let required, let available) {
            XCTAssertEqual(required, margin + Int64(data.count))
            XCTAssertEqual(available, margin + 8192)
        }
        let row = try await store.registry.blob(digest: digest)
        XCTAssertEqual(row?.staged, 0)
        let placed = try await store.blobs.blobExists(digest: digest)
        XCTAssertFalse(placed)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
}
