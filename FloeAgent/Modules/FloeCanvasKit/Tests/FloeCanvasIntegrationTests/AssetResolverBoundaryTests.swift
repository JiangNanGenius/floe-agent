import XCTest
import Darwin
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

@MainActor
final class AssetResolverBoundaryTests: XCTestCase {
    private func rejected(_ resolver: FileCanvasAssetResolver, path: String, follow: Bool) async {
        do {
            _ = try await resolver.resolve(.init(relativePath: path),
                options: .init(followSymlinks: follow), cancellation: nil)
            XCTFail("Expected asset path rejection")
        } catch { }
    }

    func testSymlinkModesCannotEscapeAndDisabledModeRejectsContainedLink() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("floe-assets-boundary-\(UUID())")
        let assets = directory.appendingPathComponent("assets")
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let bytes = Data("synthetic asset".utf8)
        try bytes.write(to: assets.appendingPathComponent("inside.bin"))
        try bytes.write(to: directory.appendingPathComponent("outside.bin"))
        try manager.createSymbolicLink(atPath: assets.appendingPathComponent("internal.bin").path,
            withDestinationPath: "inside.bin")
        try manager.createSymbolicLink(atPath: assets.appendingPathComponent("external.bin").path,
            withDestinationPath: "../outside.bin")
        let resolver = try FileCanvasAssetResolver(root: assets)
        await rejected(resolver, path: "external.bin", follow: true)
        await rejected(resolver, path: "external.bin", follow: false)
        await rejected(resolver, path: "internal.bin", follow: false)
        let resolved = try await resolver.resolve(.init(relativePath: "internal.bin"),
            options: .init(followSymlinks: true), cancellation: nil)
        XCTAssertEqual(resolved.data, bytes)
        XCTAssertEqual(resolved.fileByteCount, Int64(bytes.count))
        XCTAssertEqual(resolved.resolvedURL.lastPathComponent, "inside.bin")
    }

    func testExplicitSymlinkRootIsCanonicalizedAndFIFONeverBlocks() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("floe-assets-root-\(UUID())")
        let assets = directory.appendingPathComponent("assets")
        let alias = directory.appendingPathComponent("alias")
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: assets.appendingPathComponent("asset.bin"))
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: assets.path)
        let resolver = try FileCanvasAssetResolver(root: alias)
        let resolved = try await resolver.resolve(.init(relativePath: "asset.bin"),
            options: .init(maxByteCount: 3, followSymlinks: false), cancellation: nil)
        XCTAssertEqual(resolved.data, Data([1, 2, 3]))
        let pipe = assets.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, mode_t(0o600)), 0)
        // The descriptor is nonblocking and must reject non-regular files.
        await rejected(resolver, path: "pipe", follow: true)
        do {
            _ = try await resolver.resolve(.init(relativePath: "asset.bin"),
                options: .init(maxByteCount: 2), cancellation: nil)
            XCTFail("Expected bounded read rejection")
        } catch { }
    }
}
