import Foundation
import CryptoKit
import XCTest
import FloeCore
import FloeEnvironments
import FloePersistence
@testable import FloeExecution
@testable import FloeApp

/// The production App descriptor must retain Linux ownership when its
/// resident base differs from the new-install default or cannot be resolved.
@MainActor final class LinuxResidentImageAppTests: XCTestCase {
    private struct Fixture {
        let registry: EnvironmentRegistry
        let recordID: String
        let provider: AppLinuxGuestEnvironmentProvider
        let resident: URL
        let dependency: URL
        let oldImage: LinuxResidentImageCandidate
    }

    private func fixture(_ root: URL, recordedImageID: String) async throws -> Fixture {
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let roots = EnvironmentRoots(rootURL: root.appendingPathComponent("environments"))
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "unchanged-ABI")
        let record = try await registry.ensureProjectContainer(workspaceID: "owned-fixture",
            workspaceRootPath: workspace.path, executionBackend: .linuxVM)
        let dependency = roots.layerURL(id: record.id, kind: record.kind).appendingPathComponent("retained-package")
        try Data("previously-installed-dependency".utf8).write(to: dependency)
        let imageRoot = root.appendingPathComponent("verified-images")
        try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
        let oldBytes = Data("old-base".utf8), newBytes = Data("new-base".utf8)
        let old = LinuxResidentImageCandidate(imageID: "old-image",
            diskSHA512: SHA512.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined(), diskBytes: Int64(oldBytes.count))
        let new = LinuxResidentImageCandidate(imageID: "new-image",
            diskSHA512: SHA512.hash(data: newBytes).map { String(format: "%02x", $0) }.joined(), diskBytes: Int64(newBytes.count))
        for (image, bytes) in [(old, oldBytes), (new, newBytes)] {
            try bytes.write(to: imageRoot.appendingPathComponent(image.imageID))
        }
        let resident = root.appendingPathComponent("resident")
        let directory = LinuxResidentDiskStorage.directory(in: resident)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("mutable-resident-with-user-packages".utf8).write(to: directory.appendingPathComponent("disk.img"))
        let origin = LinuxGuestRuntimeDiskOrigin(imageID: recordedImageID,
            artifactSHA512: old.diskSHA512, artifactBytes: old.diskBytes)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(origin).write(to: directory.appendingPathComponent("origin.json"))
        let source = ResidentImageSource()
        source.set(LinuxResidentImageResolver(residentRoot: resident, defaultImageID: new.imageID,
            trustedImageIDs: [old.imageID, new.imageID]) { id in
                guard let image = [old, new].first(where: { $0.imageID == id }),
                      let bytes = try? Data(contentsOf: imageRoot.appendingPathComponent(id)),
                      bytes.count == image.diskBytes,
                      SHA512.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == image.diskSHA512 else { return nil }
                return image
            })
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let provider = AppLinuxGuestEnvironmentProvider(registry: registry, residentImageSource: source,
            pinnedImageSource: PinnedImageSource(), workspaceStore: SQLiteWorkspaceStore(database: database))
        return Fixture(registry: registry, recordID: record.id, provider: provider,
            resident: directory, dependency: dependency, oldImage: old)
    }

    func testAppDescriptorRetainsExistingImageAndDependenciesAfterDefaultChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root, recordedImageID: "old-image")
        let disk = try Data(contentsOf: f.resident.appendingPathComponent("disk.img"))
        let origin = try Data(contentsOf: f.resident.appendingPathComponent("origin.json"))
        let before = await f.registry.all()
        let resolved = await f.provider.linuxGuestEnvironment(id: f.recordID)
        let descriptor = try XCTUnwrap(resolved)
        XCTAssertEqual(descriptor.imageID, f.oldImage.imageID)
        XCTAssertNil(descriptor.imageResolutionFailure)
        XCTAssertEqual(descriptor.id, f.recordID)
        XCTAssertTrue(descriptor.networkEnabled)
        let after = await f.registry.all()
        XCTAssertEqual(after.map(\.id).sorted(), before.map(\.id).sorted())
        XCTAssertFalse(try XCTUnwrap(after.first(where: { $0.id == f.recordID })).requiresRebuild)
        XCTAssertEqual(try Data(contentsOf: f.dependency), Data("previously-installed-dependency".utf8))
        XCTAssertEqual(try Data(contentsOf: f.resident.appendingPathComponent("disk.img")), disk)
        XCTAssertEqual(try Data(contentsOf: f.resident.appendingPathComponent("origin.json")), origin)
    }

    func testAppDescriptorKeepsLinuxOwnershipWhenOriginCannotBeResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root, recordedImageID: "unknown-image")
        let origin = try Data(contentsOf: f.resident.appendingPathComponent("origin.json"))
        let resolved = await f.provider.linuxGuestEnvironment(id: f.recordID)
        let descriptor = try XCTUnwrap(resolved, "An unresolved Linux origin must retain the descriptor instead of permitting another backend")
        XCTAssertEqual(descriptor.id, f.recordID)
        XCTAssertTrue(descriptor.imageID.isEmpty)
        XCTAssertFalse(try XCTUnwrap(descriptor.imageResolutionFailure).isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.resident.appendingPathComponent("origin.json")), origin)
        XCTAssertEqual(try Data(contentsOf: f.dependency), Data("previously-installed-dependency".utf8))
        let record = await f.registry.record(id: f.recordID)
        XCTAssertFalse(try XCTUnwrap(record).requiresRebuild)
    }

    func testSharedLinuxDescriptorGetsOnlyItsOwnMaintenanceWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root, recordedImageID: "old-image")
        let resolved = await f.provider.linuxGuestEnvironment(id: EnvironmentRegistry.sharedContainerID)
        let descriptor = try XCTUnwrap(resolved)
        let environmentShare = try XCTUnwrap(descriptor.shares.first {
            $0.tag == LinuxGuestShare.environmentTag
        })
        let workspaceShare = try XCTUnwrap(descriptor.shares.first {
            $0.tag == LinuxGuestShare.workspaceTag
        })
        let expected = root.appendingPathComponent("environments/.LinuxCacheCleanupWorkspace")
        XCTAssertEqual(workspaceShare.hostDirectory.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertNotEqual(workspaceShare.hostDirectory.standardizedFileURL,
                          environmentShare.hostDirectory.standardizedFileURL)
        XCTAssertNotEqual(workspaceShare.hostDirectory.standardizedFileURL,
                          root.appendingPathComponent("workspace").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        let map = LinuxGuestPathMap(shares: descriptor.shares)
        XCTAssertEqual(map.hostPath(forGuestPath: LinuxGuestMountPoint.workspace)?.standardizedFileURL,
                       expected.standardizedFileURL)
        let access = try await f.provider.acquireShareAccess(
            environmentID: EnvironmentRegistry.sharedContainerID, descriptor: descriptor
        )
        XCTAssertNil(access)
        let secondResolved = await f.provider.linuxGuestEnvironment(id: EnvironmentRegistry.sharedContainerID)
        let second = try XCTUnwrap(secondResolved)
        XCTAssertEqual(second.shares.first { $0.tag == LinuxGuestShare.workspaceTag }?.hostDirectory.standardizedFileURL,
                       expected.standardizedFileURL, "A second descriptor read must reuse the existing workspace")
        let secondAccess = try await f.provider.acquireShareAccess(
            environmentID: EnvironmentRegistry.sharedContainerID, descriptor: second
        )
        XCTAssertNil(secondAccess)
        let projectResolved = await f.provider.linuxGuestEnvironment(id: f.recordID)
        let project = try XCTUnwrap(projectResolved)
        XCTAssertEqual(project.shares.first { $0.tag == LinuxGuestShare.workspaceTag }?.hostDirectory,
                       root.appendingPathComponent("workspace"))
    }

    func testSharedLinuxDescriptorRejectsRedirectedMaintenanceWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root, recordedImageID: "old-image")
        let userData = root.appendingPathComponent("user-data", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: false)
        let marker = userData.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("environments/.LinuxCacheCleanupWorkspace"),
            withDestinationURL: userData
        )
        let resolved = await f.provider.linuxGuestEnvironment(id: EnvironmentRegistry.sharedContainerID)
        let descriptor = try XCTUnwrap(resolved)
        XCTAssertNil(descriptor.shares.first { $0.tag == LinuxGuestShare.workspaceTag })
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }
}
