// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

/// CanvasTrustedFileAssetResolver confinement and bounds: symlink escape,
//  `..` traversal, non-regular files and oversized reads must fail closed;
/// contained regular files read back exactly.
final class AssetResolverTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func locator(_ path: String?) -> CanvasAssetLocator {
        CanvasAssetLocator(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, relativePath: path)
    }

    func testContainedFileResolvesExactly() async throws {
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: root.appendingPathComponent("asset.bin"))
        let resolver = CanvasTrustedFileAssetResolver(root: root)
        let data = try await resolver.data(for: locator("asset.bin"))
        XCTAssertEqual(data, bytes)
    }

    func testEscapingSymlinkIsRefused() async throws {
        let secret = Data("secret".utf8)
        try secret.write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        let resolver = CanvasTrustedFileAssetResolver(root: root)
        await XCTAssertThrowsAsyncError(try await resolver.data(for: locator("link"))) { error in
            guard case CanvasExchangeError.assetUnavailable = error else {
                return XCTFail("assetUnavailable expected, got \(error)")
            }
        }
    }

    func testDotDotTraversalIsRefused() async throws {
        try Data("x".utf8).write(to: outside.appendingPathComponent("x.txt"))
        let resolver = CanvasTrustedFileAssetResolver(root: root)
        await XCTAssertThrowsAsyncError(try await resolver.data(for: locator("../outside/x.txt"))) { error in
            guard case CanvasExchangeError.assetUnavailable = error else {
                return XCTFail("assetUnavailable expected, got \(error)")
            }
        }
    }

    func testOversizedFileFailsLimit() async throws {
        try Data([UInt8](repeating: 7, count: 4096)).write(to: root.appendingPathComponent("big.bin"))
        let resolver = CanvasTrustedFileAssetResolver(root: root, maximumBytes: 1024)
        await XCTAssertThrowsAsyncError(try await resolver.data(for: locator("big.bin"))) { error in
            guard case CanvasExchangeError.limitExceeded = error else {
                return XCTFail("limitExceeded expected, got \(error)")
            }
        }
    }

    func testDirectoryIsNotARegularFile() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subdir"),
            withIntermediateDirectories: true
        )
        let resolver = CanvasTrustedFileAssetResolver(root: root)
        await XCTAssertThrowsAsyncError(try await resolver.data(for: locator("subdir"))) { error in
            guard case CanvasExchangeError.assetUnavailable = error else {
                return XCTFail("assetUnavailable expected, got \(error)")
            }
        }
    }

    func testMissingRelativePathFails() async throws {
        let resolver = CanvasTrustedFileAssetResolver(root: root)
        await XCTAssertThrowsAsyncError(try await resolver.data(for: locator(nil))) { error in
            guard case CanvasExchangeError.assetUnavailable = error else {
                return XCTFail("assetUnavailable expected, got \(error)")
            }
        }
    }

    func testJSONCanvasTrustedRootUsesBoundedRegularFileRead() throws {
        // The same bounded reader backs JSON Canvas trusted-root byte
        // resolution: a contained regular file resolves to media; a
        // directory reference is refused (regular-file check).
        let bytes = Data("document bytes".utf8)
        try bytes.write(to: root.appendingPathComponent("note.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subdir"),
            withIntermediateDirectories: true
        )
        let json = """
        {"nodes":[
          {"id":"ok","type":"file","x":0,"y":0,"width":100,"height":40,"file":"note.md"},
          {"id":"dir","type":"file","x":0,"y":200,"width":100,"height":40,"file":"subdir"}
        ]}
        """.data(using: .utf8)!
        let bundle = try CanvasJSONCanvasCodec.decode(
            json,
            options: .init(trustedAssetRoot: root, resolveAssetBytes: true)
        )
        let media = bundle.snapshot.pages.first?.nodes.first(where: { $0.id == CanvasExchangeIDs.stable(CanvasJSONCanvasCodec.namespace, "ok") })
        guard case .media(let locator)? = media?.content else {
            return XCTFail("contained file must resolve to media; issues: \(bundle.issues)")
        }
        XCTAssertEqual(bundle.assets[locator.id], bytes)
        let directory = bundle.snapshot.pages.first?.nodes.first(where: { $0.id == CanvasExchangeIDs.stable(CanvasJSONCanvasCodec.namespace, "dir") })
        XCTAssertEqual(directory?.content.unknownKind, "floe.jsoncanvas.file", "directory reference stays a reference")
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "jsoncanvas.file.unresolved" }))
    }
}
