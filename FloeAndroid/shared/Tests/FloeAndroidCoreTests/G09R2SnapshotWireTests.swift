// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeAndroidCore

final class G09R2SnapshotWireTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_765_000.456789)
    private let projectID = UUID()
    private let token = "snapshot-wire-owner"

    private func fixture(canonical: Bool = true) throws
        -> (G09R2SnapshotLeases, G09R2RenderSnapshotLeaseDTO) {
        let expiry = canonical ? G09R2SnapshotLeases.expiration(createdAt: now)
            : now.addingTimeInterval(G09R2SnapshotLeases.lifetimeSeconds)
        let root = FileManager.default.temporaryDirectory.path
        let record = G09R2SnapshotLeaseRecord(
            leaseID: UUID().uuidString, epoch: 101, projectID: projectID,
            revision: 3, timelineDigest: "timeline-digest", mediaRootPath: root,
            relativePath: "snapshot.json", sha256: String(repeating: "a", count: 64),
            byteCount: 10, storage: .init(kind: .appOwned), origin: nil,
            ownerReference: G09CreativeAssetHost.sessionDigest(token),
            createdAt: now, expiresAt: expiry, pinnedAssets: [])
        let registry = G09R2SnapshotLeases()
        try registry.insert(record, snapshotURL: URL(fileURLWithPath: root)
            .appendingPathComponent("snapshot.json"))
        let lease = G09R2RenderSnapshotLeaseDTO(
            leaseID: record.leaseID, mediaRootPath: root,
            relativePath: record.relativePath, sha256: record.sha256,
            byteCount: record.byteCount, expiresAt: expiry)
        // Kotlin forwards this date string unchanged; exercise the actual
        // production encoder/decoder rather than an in-memory DTO-only test.
        let wire = try G09CreativeWire.encoder().encode(lease)
        return (registry, try G09CreativeWire.decoder().decode(
            G09R2RenderSnapshotLeaseDTO.self, from: wire))
    }

    private func verify(_ registry: G09R2SnapshotLeases,
                        _ lease: G09R2RenderSnapshotLeaseDTO,
                        at time: Date? = nil, owner: String? = nil) throws {
        _ = try registry.verify(lease, epoch: 101, projectID: projectID,
            revision: 3, timelineDigest: "timeline-digest",
            storage: .init(kind: .appOwned), sessionToken: owner ?? token,
            now: time ?? now)
    }

    func testFreshLeaseSurvivesProductionWireWithExactExpiry() throws {
        let (registry, lease) = try fixture()
        XCTAssertEqual(lease.expiresAt, registry.record(for: lease.leaseID)?.expiresAt)
        XCTAssertLessThanOrEqual(lease.expiresAt.timeIntervalSince(now), 900)
        XCTAssertGreaterThan(lease.expiresAt.timeIntervalSince(now), 899)
        try verify(registry, lease)
    }

    func testOriginalFractionalAuthorityReproducesWireMismatch() throws {
        let (registry, lease) = try fixture(canonical: false)
        XCTAssertNotEqual(lease.expiresAt, registry.record(for: lease.leaseID)?.expiresAt)
        XCTAssertThrowsError(try verify(registry, lease)) { error in
            XCTAssertEqual((error as? G09R2Error)?.detail, "leaseExpired")
        }
    }

    func testExpiredLeaseRemainsRefused() throws {
        let (registry, lease) = try fixture()
        XCTAssertThrowsError(try verify(registry, lease, at: lease.expiresAt)) { error in
            XCTAssertEqual((error as? G09R2Error)?.code, "renderTicketExpired")
        }
    }

    func testTamperedExpiryAndForeignOwnerRemainRefused() throws {
        let (registry, lease) = try fixture()
        var tampered = lease
        tampered.expiresAt = lease.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try verify(registry, tampered))
        XCTAssertThrowsError(try verify(registry, lease, owner: "foreign-owner"))
    }
}
