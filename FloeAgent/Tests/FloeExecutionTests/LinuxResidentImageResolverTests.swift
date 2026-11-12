import Foundation
import CryptoKit
import XCTest
@testable import FloeExecution

/// Real small image files/manifests and the production origin Codable model.
/// The lookup verifies source bytes instead of returning a canned if/else.
final class LinuxResidentImageResolverTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let images: URL
        let resident: URL
        let old: LinuxResidentImageCandidate
        let new: LinuxResidentImageCandidate

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-origin-" + UUID().uuidString)
            images = root.appendingPathComponent("images", isDirectory: true)
            resident = root.appendingPathComponent("resident", isDirectory: true)
            let oldData = Data("old-qualified-base".utf8)
            let newData = Data("new-qualified-base".utf8)
            let oldDigest = SHA512.hash(data: oldData).map { String(format: "%02x", $0) }.joined()
            let newDigest = SHA512.hash(data: newData).map { String(format: "%02x", $0) }.joined()
            old = LinuxResidentImageCandidate(imageID: "trusted-v2", diskSHA512: oldDigest, diskBytes: Int64(oldData.count),
                compatibleOrigins: [.init(imageID: "trusted-v1", artifactSHA512: oldDigest, artifactBytes: Int64(oldData.count))])
            new = LinuxResidentImageCandidate(imageID: "trusted-v3", diskSHA512: newDigest, diskBytes: Int64(newData.count))
            try writeImage(old, bytes: oldData)
            try writeImage(new, bytes: newData)
        }

        var directory: URL { LinuxResidentDiskStorage.directory(in: resident) }
        var disk: URL { directory.appendingPathComponent(LinuxResidentDiskStorage.diskFileName) }
        var origin: URL { directory.appendingPathComponent(LinuxResidentDiskStorage.originFileName) }

        func writeImage(_ image: LinuxResidentImageCandidate, bytes: Data) throws {
            let directory = images.appendingPathComponent(image.imageID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(image).write(to: directory.appendingPathComponent("manifest.json"))
            try bytes.write(to: directory.appendingPathComponent("base.ext4"))
        }

        func lookup(_ id: String) async -> LinuxResidentImageCandidate? {
            let directory = images.appendingPathComponent(id, isDirectory: true)
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let image = try? JSONDecoder().decode(LinuxResidentImageCandidate.self, from: data), image.imageID == id,
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent("base.ext4")),
                  Int64(bytes.count) == image.diskBytes,
                  SHA512.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == image.diskSHA512 else { return nil }
            return image
        }

        func resolver(defaultID: String = "trusted-v3") -> LinuxResidentImageResolver {
            LinuxResidentImageResolver(residentRoot: resident, defaultImageID: defaultID,
                trustedImageIDs: [old.imageID, new.imageID], lookup: { await lookup($0) })
        }

        func writeResident(_ image: LinuxResidentImageCandidate, imageID: String? = nil,
                           writeDisk: Bool = true) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Mutable disk deliberately differs from the pristine source. The
            // resolver must preserve it and compare provenance, not its hash.
            if writeDisk { try Data("user-installed-dependencies-and-project-state".utf8).write(to: disk) }
            let value = LinuxGuestRuntimeDiskOrigin(imageID: imageID ?? image.imageID,
                artifactSHA512: image.diskSHA512, artifactBytes: image.diskBytes,
                logicalCapacityBytes: Int64("user-installed-dependencies-and-project-state".utf8.count))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: origin)
        }

        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for p in [disk, origin] where FileManager.default.fileExists(atPath: p.path) {
                result[p.lastPathComponent] = try Data(contentsOf: p)
            }
            return result
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func expect(_ expected: LinuxResidentImageResolutionError, fixture: Fixture) async throws {
        let before = try fixture.snapshot()
        do {
            _ = try await fixture.resolver().resolve()
            XCTFail("Expected explicit origin failure")
        } catch let error as LinuxResidentImageResolutionError {
            XCTAssertEqual(error, expected)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testFreshStorageSelectsDefaultWithoutCreatingAnything() async throws {
        let f = try Fixture(); defer { f.remove() }
        let selected = try await f.resolver().resolve()
        XCTAssertEqual(selected, f.new.imageID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.resident.path))
    }

    func testCleanupRequiresExistingDiskWithoutSelectingDefaultOrCreatingStorage() async throws {
        let f = try Fixture(); defer { f.remove() }
        do {
            _ = try await f.resolver().resolve(requireExistingDisk: true)
            XCTFail("Cleanup must not select the first-creation default")
        } catch let error as LinuxResidentImageResolutionError {
            XCTAssertEqual(error, .missingDisk)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.resident.path))
    }

    func testCleanupReusesVerifiedOldOriginWithoutChangingAnyBytes() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        let before = try f.snapshot()
        let selected = try await f.resolver().resolve(requireExistingDisk: true)
        XCTAssertEqual(selected, f.old.imageID)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testExistingOldOriginWinsOverNewDefaultAndPreservesMutableDisk() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        let before = try f.snapshot()
        let selected = try await f.resolver().resolve()
        XCTAssertEqual(selected, f.old.imageID)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testExistingNewOriginWinsEvenIfDefaultReturnsToOld() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.new)
        let selected = try await f.resolver(defaultID: f.old.imageID).resolve()
        XCTAssertEqual(selected, f.new.imageID)
    }

    func testExistingExactV1PredecessorContinuesUsingVerifiedV2() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old, imageID: "trusted-v1")
        let before = try f.snapshot()
        let selected = try await f.resolver().resolve()
        XCTAssertEqual(selected, f.old.imageID)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testUnknownOriginCannotPickEitherInstalledImage() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old, imageID: "unknown-base")
        try await expect(.unknownOrigin, fixture: f)
    }

    func testCorruptOriginIsNotFirstUse() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try Data("{damaged".utf8).write(to: f.origin)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testDiskWithMissingOriginNeverUsesDefault() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try FileManager.default.removeItem(at: f.origin)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testOriginWithMissingDiskIsNotFirstUse() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old, writeDisk: false)
        try await expect(.missingDisk, fixture: f)
    }

    func testMissingOldSourceDoesNotFallBackToInstalledNewImage() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try FileManager.default.removeItem(at: f.images.appendingPathComponent(f.old.imageID))
        try await expect(.sourceUnavailable(imageID: f.old.imageID), fixture: f)
    }

    func testSourceDigestFailureDoesNotFallBackToNewImage() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try Data("tampered-base".utf8).write(to: f.images.appendingPathComponent(f.old.imageID + "/base.ext4"))
        try await expect(.sourceUnavailable(imageID: f.old.imageID), fixture: f)
    }

    func testRecordedWrongDigestFailsWithoutChangingOrigin() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(.init(imageID: f.old.imageID, diskSHA512: String(repeating: "a", count: 128), diskBytes: f.old.diskBytes))
        try await expect(.originMismatch, fixture: f)
    }

    func testFutureOriginSchemaFailsInsteadOfRewritingIt() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.origin)) as? [String: Any])
        json["version"] = 3
        try JSONSerialization.data(withJSONObject: json).write(to: f.origin)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testOversizedSidecarIsBoundedAndRetained() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try Data(repeating: 32, count: 16 * 1024 + 1).write(to: f.origin)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testSourceByteCountConflictFails() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(.init(imageID: f.old.imageID, diskSHA512: f.old.diskSHA512, diskBytes: f.old.diskBytes + 1))
        try await expect(.originMismatch, fixture: f)
    }

    func testTruncatedMutableDiskCannotBeRecreatedAsFresh() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        try Data([1]).write(to: f.disk)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testSymlinkDiskIsNotFollowedOrReplaced() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        let preserved = try f.snapshot()
        let external = f.root.appendingPathComponent("external-disk")
        try XCTUnwrap(preserved["disk.img"]).write(to: external)
        try FileManager.default.removeItem(at: f.disk)
        try FileManager.default.createSymbolicLink(at: f.disk, withDestinationURL: external)
        try await expect(.invalidOrigin, fixture: f)
        XCTAssertEqual(try Data(contentsOf: external), preserved["disk.img"])
    }

    func testSymlinkOriginIsNotAccepted() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        let external = f.root.appendingPathComponent("external-origin")
        try Data(contentsOf: f.origin).write(to: external)
        try FileManager.default.removeItem(at: f.origin)
        try FileManager.default.createSymbolicLink(at: f.origin, withDestinationURL: external)
        try await expect(.invalidOrigin, fixture: f)
    }

    func testAmbiguousPredecessorIsNotResolvedByCatalogOrder() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old, imageID: "trusted-v1")
        let second = LinuxResidentImageCandidate(imageID: f.new.imageID,
            diskSHA512: f.new.diskSHA512, diskBytes: f.new.diskBytes, compatibleOrigins: f.old.compatibleOrigins)
        try f.writeImage(second, bytes: Data("new-qualified-base".utf8))
        try await expect(.ambiguousOrigin, fixture: f)
    }

    func testConcurrentReadsKeepOneExistingBaseAndNeverWrite() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.writeResident(f.old)
        let before = try f.snapshot()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await f.resolver().resolve() } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(ids, Array(repeating: f.old.imageID, count: 8))
        XCTAssertEqual(try f.snapshot(), before)
    }
}
