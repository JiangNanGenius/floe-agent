import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class AssetResolverTests: XCTestCase {
    private var root: URL!
    private var resolver: FileCanvasAssetResolver!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        resolver = try FileCanvasAssetResolver(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeFile(
        _ bytes: Data, relativePath: String
    ) throws -> CanvasAssetLocator {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: url)
        return CanvasAssetLocator(
            relativePath: relativePath, mimeType: "application/octet-stream")
    }

    func testResolveWithinRootReturnsBoundedData() async throws {
        let locator = try writeFile(Data([1, 2, 3]), relativePath: "a/b.bin")
        let resolved = try await resolver.resolve(
            locator,
            options: .init(maxByteCount: 1024),
            cancellation: nil)
        XCTAssertEqual(resolved.data, Data([1, 2, 3]))
        XCTAssertEqual(resolved.fileByteCount, 3)
    }

    func testPathTraversalEscapingRootRejected() async throws {
        let locator = CanvasAssetLocator(relativePath: "../outside.bin")
        await XCTAssertThrowsErrorAsync({
            try await self.resolver.resolve(
                locator, options: .init(), cancellation: nil)
        }) { error in
            guard case CanvasKitError.repositoryRootViolation = error else {
                XCTFail("expected repositoryRootViolation, got \(error)")
                return
            }
        }
    }

    func testSymlinkEscapingRootRejected() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-outside-\(UUID().uuidString).bin")
        try Data([9]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: outside.path)
        let locator = CanvasAssetLocator(relativePath: "link.bin")
        await XCTAssertThrowsErrorAsync({
            try await self.resolver.resolve(
                locator, options: .init(), cancellation: nil)
        }) { error in
            guard case CanvasKitError.repositoryRootViolation = error else {
                XCTFail("expected repositoryRootViolation, got \(error)")
                return
            }
        }
    }

    func testSymlinkWithinRootAccepted() async throws {
        let target = try writeFile(Data([7]), relativePath: "real.bin")
        let link = root.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: root.appendingPathComponent("real.bin").path)
        let locator = CanvasAssetLocator(relativePath: "alias.bin")
        let resolved = try await resolver.resolve(
            locator, options: .init(), cancellation: nil)
        XCTAssertEqual(resolved.data, Data([7]))
        // The locator identity is preserved; the resolved path follows the
        // symlink to the real file inside the root.
        XCTAssertEqual(resolved.locator.relativePath, "alias.bin")
        XCTAssertEqual(resolved.resolvedURL.lastPathComponent, "real.bin")
        _ = target
    }

    func testOversizedAssetRefusedNotTruncated() async throws {
        let locator = try writeFile(
            Data(count: 2048), relativePath: "big.bin")
        await XCTAssertThrowsErrorAsync({
            try await self.resolver.resolve(
                locator,
                options: .init(maxByteCount: 1024),
                cancellation: nil)
        }) { error in
            guard case CanvasKitError.io(let message) = error else {
                XCTFail("expected io, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("limit"))
        }
    }

    func testCancellationThrowsWithoutEffects() async throws {
        let locator = try writeFile(Data([1]), relativePath: "c.bin")
        let token = CanvasCancellationToken()
        token.cancel()
        await XCTAssertThrowsErrorAsync({
            try await self.resolver.resolve(
                locator, options: .init(), cancellation: token)
        }) { error in
            guard case CanvasKitError.cancelled = error else {
                XCTFail("expected cancelled, got \(error)")
                return
            }
        }
    }

    func testFilesystemRootRefused() {
        XCTAssertThrowsError(try FileCanvasAssetResolver(root: URL(fileURLWithPath: "/"))) { error in
            guard case CanvasKitError.repositoryRootViolation = error else {
                XCTFail("expected repositoryRootViolation, got \(error)")
                return
            }
        }
    }

    func testMetadataCacheInsertGetRemove() async {
        let cache = CanvasAssetMetadataCache()
        let id = UUID()
        let missing = await cache.metadata(for: id)
        XCTAssertNil(missing)
        await cache.insert(
            CanvasAssetMetadata(byteCount: 5, mimeType: "image/png"), for: id)
        let entry = await cache.metadata(for: id)
        XCTAssertEqual(entry?.byteCount, 5)
        await cache.remove(for: id)
        let removed = await cache.metadata(for: id)
        XCTAssertNil(removed)
    }
}
