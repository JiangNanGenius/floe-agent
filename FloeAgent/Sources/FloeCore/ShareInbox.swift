// SPDX-License-Identifier: MPL-2.0
//
// FloeCore — durable inbound share transport (S5 P1).
//
// This is the producer/consumer boundary between the Share extension and the
// main app. It owns ONLY transport bytes in the shared App Group container:
// the extension stages a bounded multi-item envelope, and the app claims one
// envelope at a time, applies it to the reviewed draft, and acknowledges it
// only after that draft is durably committed.
//
// Invariants:
// * An envelope is visible only after its manifest is written last and the
//   whole `.staging/<id>` directory is atomically renamed to `<id>/`.
// * A claim is an exclusive OS file lock (`flock`) on `<id>/.claim`, not a
//   wall-clock timeout. A live owner can never be stolen from; a crashed
//   owner's lock is released by the kernel, and recovery additionally waits
//   the configured grace period before reusing the envelope.
// * `ack` renames the envelope out of the active namespace before deleting
//   it, so a successful ack can never leave a re-claimable record.
// * Every manifest path is a generated relative name validated against a
//   strict pattern; absolute paths, `..`, aliases and symlinks are rejected.
// * All file reads are bounded and streamed. Digests are verified when the
//   envelope is claimed, so the consumer never stages bytes that changed
//   after staging.
//
// This file deliberately does not import UIKit/AppKit. The extension owns
// provider decoding (UIImage/PNG fallback); FloeCore owns bytes, paths,
// limits and ownership.

import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Model

public enum ShareInboxItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case url
    case image
    case file
}

public struct ShareInboxItem: Codable, Sendable, Equatable {
    public var kind: ShareInboxItemKind
    /// Inline text for `.text`; the absolute URL string for `.url`.
    public var text: String?
    /// Human-readable original name. Metadata only: never used as a path.
    public var fileName: String?
    /// App-generated path relative to the envelope directory
    /// (`items/item-<n>[.<ext>]`). Never a user-supplied path.
    public var storageName: String?
    public var typeIdentifier: String?
    public var byteCount: Int
    public var sha256: String?

    public init(
        kind: ShareInboxItemKind,
        text: String? = nil,
        fileName: String? = nil,
        storageName: String? = nil,
        typeIdentifier: String? = nil,
        byteCount: Int = 0,
        sha256: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.fileName = fileName
        self.storageName = storageName
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ShareEnvelope: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var createdAt: Date
    public var schemaVersion: Int
    public var producer: String
    public var items: [ShareInboxItem]
    public var totalByteCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        schemaVersion: Int = ShareEnvelope.currentSchemaVersion,
        producer: String = "Floe",
        items: [ShareInboxItem],
        totalByteCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.producer = producer
        self.items = items
        self.totalByteCount = totalByteCount
    }

    public var textItems: [ShareInboxItem] {
        items.filter { $0.kind == .text || $0.kind == .url }
    }

    public var attachmentItems: [ShareInboxItem] {
        items.filter { $0.kind == .image || $0.kind == .file }
    }
}

/// Every bound is explicit and injectable so focused tests use small values
/// while production uses the product limits from the P1 contract.
public struct ShareInboxLimits: Sendable, Equatable {
    public var maxItems: Int
    public var maxTextBytes: Int
    public var maxItemBytes: Int
    public var maxEnvelopeBytes: Int
    public var maxPendingEnvelopes: Int
    public var maxPendingBytes: Int
    public var ttl: TimeInterval
    /// A claim younger than this cannot be reused even when its process lock
    /// is already free (crash recovery is intentionally delayed).
    public var claimRecoveryGrace: TimeInterval
    public var stagingCleanupAge: TimeInterval
    public var trashCleanupAge: TimeInterval
    public var copyChunkBytes: Int

    public init(
        maxItems: Int = 5,
        maxTextBytes: Int = 1_048_576,
        maxItemBytes: Int = 67_108_864,
        maxEnvelopeBytes: Int = 134_217_728,
        maxPendingEnvelopes: Int = 20,
        maxPendingBytes: Int = 268_435_456,
        ttl: TimeInterval = 604_800,
        claimRecoveryGrace: TimeInterval = 300,
        stagingCleanupAge: TimeInterval = 86_400,
        trashCleanupAge: TimeInterval = 3_600,
        copyChunkBytes: Int = 1_048_576
    ) {
        self.maxItems = max(1, maxItems)
        self.maxTextBytes = max(1, maxTextBytes)
        self.maxItemBytes = max(1, maxItemBytes)
        self.maxEnvelopeBytes = max(1, maxEnvelopeBytes)
        self.maxPendingEnvelopes = max(1, maxPendingEnvelopes)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.ttl = max(0, ttl)
        self.claimRecoveryGrace = max(0, claimRecoveryGrace)
        self.stagingCleanupAge = max(0, stagingCleanupAge)
        self.trashCleanupAge = max(0, trashCleanupAge)
        self.copyChunkBytes = max(4_096, min(copyChunkBytes, 1_048_576))
    }

    public static let standard = ShareInboxLimits()
}

// MARK: - Errors

public enum ShareInboxIOStage: String, Sendable, Equatable {
    case create
    case read
    case copy
    case write
    case commit
    case verify
    case delete
    case claim
}

public enum ShareInboxError: Error, LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case invalidState
    case emptyEnvelope
    case itemLimitExceeded(limit: Int)
    case textTooLarge(byteCount: Int, limit: Int)
    case itemTooLarge(byteCount: Int, limit: Int)
    case envelopeTooLarge(byteCount: Int, limit: Int)
    case queueFull(envelopes: Int, bytes: Int)
    case insufficientSpace
    case unsupportedItem(reason: String)
    case invalidEnvelope(reason: String)
    case envelopeNotFound
    case claimBusy
    case claimTokenMismatch
    case ioFailure(stage: ShareInboxIOStage, detail: String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return FloeL10n.l("share.error.app_group_unavailable")
        case .invalidState:
            return FloeL10n.l("share.error.invalid_state")
        case .emptyEnvelope:
            return FloeL10n.l("share.error.empty")
        case .itemLimitExceeded(let limit):
            return FloeL10n.l("share.error.item_limit", limit)
        case .textTooLarge:
            return FloeL10n.l("share.error.text_too_large")
        case .itemTooLarge:
            return FloeL10n.l("share.error.item_too_large")
        case .envelopeTooLarge:
            return FloeL10n.l("share.error.envelope_too_large")
        case .queueFull:
            return FloeL10n.l("share.error.queue_full")
        case .insufficientSpace:
            return FloeL10n.l("share.error.insufficient_space")
        case .unsupportedItem:
            return FloeL10n.l("share.error.unsupported_item")
        case .invalidEnvelope:
            return FloeL10n.l("share.error.invalid_envelope")
        case .envelopeNotFound:
            return FloeL10n.l("share.error.not_found")
        case .claimBusy:
            return FloeL10n.l("share.error.claim_busy")
        case .claimTokenMismatch:
            return FloeL10n.l("share.error.claim_token_mismatch")
        case .ioFailure:
            return FloeL10n.l("share.error.io_failure")
        }
    }
}

// MARK: - Claim model

public struct ShareInboxClaimRecord: Codable, Sendable, Equatable {
    public var token: String
    public var processEpoch: String
    public var claimedAt: Date
    public var processIdentifier: Int32

    public init(token: String, processEpoch: String, claimedAt: Date, processIdentifier: Int32) {
        self.token = token
        self.processEpoch = processEpoch
        self.claimedAt = claimedAt
        self.processIdentifier = processIdentifier
    }
}

public enum ShareInboxProcessEpoch {
    /// Identity of this process for claim diagnostics. Live ownership itself
    /// is the OS lock, not this string.
    public static let value = UUID().uuidString
}

/// A single exclusive claim. The lease keeps the claim file's `flock`
/// descriptor open; dropping the claim (including on process death) releases
/// it. Tokens are part of the identity, so a stale claimant cannot ack or
/// release a newer claim.
public final class ShareInboxClaim: @unchecked Sendable {
    public let envelope: ShareEnvelope
    public let envelopeURL: URL
    public let token: String
    public let claimedAt: Date
    fileprivate let lease: ShareInboxClaimLease

    fileprivate init(
        envelope: ShareEnvelope,
        envelopeURL: URL,
        token: String,
        claimedAt: Date,
        lease: ShareInboxClaimLease
    ) {
        self.envelope = envelope
        self.envelopeURL = envelopeURL
        self.token = token
        self.claimedAt = claimedAt
        self.lease = lease
    }
}

fileprivate final class ShareInboxClaimLease: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    let claimURL: URL
    private var closed = false

    init(descriptor: Int32, claimURL: URL) {
        self.descriptor = descriptor
        self.claimURL = claimURL
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = flock(descriptor, LOCK_UN)
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }

    deinit {
        close()
    }
}

// MARK: - Diagnostics

public struct ShareInboxDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case unreadableEnvelope
        case invalidIdentifier
        case rootUnavailable
        case stagingCleanupFailed
        case trashCleanupFailed
    }

    public var kind: Kind
    public var id: UUID?
    public var detail: String

    public init(kind: Kind, id: UUID? = nil, detail: String) {
        self.kind = kind
        self.id = id
        self.detail = detail
    }
}

public struct ShareInboxMaintenanceReport: Sendable, Equatable {
    public var expiredEnvelopes: Int
    public var recoveredClaims: Int
    public var removedStagingDirectories: Int
    public var removedTrashDirectories: Int
    public var diagnostics: [ShareInboxDiagnostic]

    public init(
        expiredEnvelopes: Int = 0,
        recoveredClaims: Int = 0,
        removedStagingDirectories: Int = 0,
        removedTrashDirectories: Int = 0,
        diagnostics: [ShareInboxDiagnostic] = []
    ) {
        self.expiredEnvelopes = expiredEnvelopes
        self.recoveredClaims = recoveredClaims
        self.removedStagingDirectories = removedStagingDirectories
        self.removedTrashDirectories = removedTrashDirectories
        self.diagnostics = diagnostics
    }
}

// MARK: - Producer input

public struct ShareInboxInput: Sendable {
    public enum Payload: Sendable {
        case text(String)
        case url(String)
        case file(URL)
        case data(Data)
    }

    public var kind: ShareInboxItemKind
    public var payload: Payload
    public var displayName: String?
    public var typeIdentifier: String?

    public init(
        kind: ShareInboxItemKind,
        payload: Payload,
        displayName: String? = nil,
        typeIdentifier: String? = nil
    ) {
        self.kind = kind
        self.payload = payload
        self.displayName = displayName
        self.typeIdentifier = typeIdentifier
    }
}

// MARK: - Inbox

public struct ShareInbox: Sendable {
    /// App Group entitlement shared by the app and the Share extension. The
    /// container lookup and the extension's entitlement must name the same
    /// group; FloeL10n is the single project constant for it.
    public static let appGroupIdentifier = FloeL10n.appGroupIdentifier

    public let rootURL: URL
    public let limits: ShareInboxLimits

    public init(rootURL: URL, limits: ShareInboxLimits = .standard) {
        self.rootURL = rootURL
        self.limits = limits
    }

    /// The production inbox inside the shared container. Throws explicitly
    /// when the App Group is not available (unsigned build, missing
    /// entitlement) instead of falling back to a private directory.
    public static func applicationGroup(limits: ShareInboxLimits = .standard) throws -> ShareInbox {
        #if canImport(Darwin)
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ShareInboxError.appGroupUnavailable
        }
        return ShareInbox(
            rootURL: container.appendingPathComponent("ShareInbox", isDirectory: true),
            limits: limits
        )
        #else
        throw ShareInboxError.appGroupUnavailable
        #endif
    }

    public var stagingURL: URL {
        rootURL.appendingPathComponent(".staging", isDirectory: true)
    }

    public var trashURL: URL {
        rootURL.appendingPathComponent(".trash", isDirectory: true)
    }

    // MARK: Producer

    /// Begins one atomic staging session. Nothing is visible to readers until
    /// `commit()` writes the manifest and renames the staging directory.
    public func beginStaging(
        producer: String = "Floe",
        createdAt: Date = Date()
    ) throws -> ShareInboxStagingSession {
        try ensureRoot()
        let id = UUID()
        let sessionRoot = stagingURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let itemsRoot = sessionRoot.appendingPathComponent("items", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: itemsRoot, withIntermediateDirectories: true)
            try Self.applyFileProtection(to: itemsRoot)
        } catch {
            try? FileManager.default.removeItem(at: sessionRoot)
            throw ioError(.create, error)
        }
        return ShareInboxStagingSession(
            inbox: self,
            envelopeID: id,
            createdAt: createdAt,
            producer: sanitizedProducer(producer),
            stagingRoot: sessionRoot,
            itemsRoot: itemsRoot
        )
    }

    /// Convenience producer for tests and non-extension callers. File inputs
    /// are COPIED; the caller's file is never moved or modified.
    public func stage(
        inputs: [ShareInboxInput],
        producer: String = "Floe",
        createdAt: Date = Date()
    ) throws -> ShareEnvelope {
        let session = try beginStaging(producer: producer, createdAt: createdAt)
        do {
            for input in inputs {
                try session.append(input)
            }
            return try session.commit()
        } catch {
            session.cancel()
            throw error
        }
    }

    // MARK: Reads

    /// Valid manifests that are still inside their TTL, in stable FIFO order.
    /// Claimed envelopes remain listed; claiming the head is what rejects a
    /// second live consumer.
    public func pending(now: Date = Date()) throws -> [ShareEnvelope] {
        try ensureRoot()
        var result: [ShareEnvelope] = []
        for entry in try envelopeDirectories() {
            guard let envelope = try? decodeEnvelope(in: entry.url, expectedID: entry.id) else {
                continue
            }
            guard now.timeIntervalSince(envelope.createdAt) <= limits.ttl else { continue }
            result.append(envelope)
        }
        result.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return result
    }

    public func diagnostics() -> [ShareInboxDiagnostic] {
        do {
            try ensureRoot()
            return try envelopeDirectories().compactMap { entry in
                do {
                    _ = try decodeEnvelope(in: entry.url, expectedID: entry.id)
                    return nil
                } catch {
                    return ShareInboxDiagnostic(
                        kind: .unreadableEnvelope,
                        id: entry.id,
                        detail: Self.diagnosticCode(for: error)
                    )
                }
            }
        } catch {
            return [ShareInboxDiagnostic(kind: .rootUnavailable, detail: Self.diagnosticCode(for: error))]
        }
    }

    /// Resolves one item to its real file URL after validating the relative
    /// name, regular-file type and byte count. Digest verification happens
    /// once at claim time, not on every UI refresh.
    public func payloadURL(for item: ShareInboxItem, in envelope: ShareEnvelope) throws -> URL {
        guard item.kind == .image || item.kind == .file else {
            throw ShareInboxError.unsupportedItem(reason: "textPayload")
        }
        let directory = envelopeDirectory(for: envelope.id)
        return try itemURL(item, in: directory)
    }

    // MARK: Claims

    public func claim(
        id: UUID,
        now: Date = Date(),
        epoch: String = ShareInboxProcessEpoch.value,
        verifyDigests: Bool = true
    ) throws -> ShareInboxClaim {
        try ensureRoot()
        let directory = envelopeDirectory(for: id)
        guard Self.isRegularDirectory(directory) else {
            throw ShareInboxError.envelopeNotFound
        }
        let claimURL = directory.appendingPathComponent(".claim")
        let existedBefore = FileManager.default.fileExists(atPath: claimURL.path)
        if existedBefore, !Self.isRegularFile(claimURL) {
            throw ShareInboxError.invalidEnvelope(reason: "claimFile")
        }
        let descriptor = open(claimURL.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else {
            throw Self.posixError(.claim, code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            throw ShareInboxError.claimBusy
        }
        var handedOff = false
        defer {
            if !handedOff {
                _ = flock(descriptor, LOCK_UN)
                #if canImport(Darwin)
                _ = Darwin.close(descriptor)
                #elseif canImport(Glibc)
                _ = Glibc.close(descriptor)
                #endif
            }
        }

        // The directory may have been acknowledged between listing and lock.
        guard Self.isRegularDirectory(directory) else {
            if !existedBefore { try? FileManager.default.removeItem(at: claimURL) }
            throw ShareInboxError.envelopeNotFound
        }

        let envelope: ShareEnvelope
        do {
            envelope = try decodeEnvelope(in: directory, expectedID: id)
            if verifyDigests {
                try verifyAttachmentDigests(in: envelope, directory: directory)
            }
        } catch {
            if !existedBefore { try? FileManager.default.removeItem(at: claimURL) }
            throw error
        }

        let previous = Self.readClaimRecord(at: claimURL)
        if let previous,
           now.timeIntervalSince(previous.claimedAt) < limits.claimRecoveryGrace {
            throw ShareInboxError.claimBusy
        }
        if previous == nil, existedBefore,
           let modified = Self.modificationDate(of: claimURL),
           now.timeIntervalSince(modified) < limits.claimRecoveryGrace {
            // A claim file exists but no readable record: it is mid-write or
            // corrupt. Keep the grace window, then let maintenance replace it.
            throw ShareInboxError.claimBusy
        }

        let record = ShareInboxClaimRecord(
            token: UUID().uuidString,
            processEpoch: epoch,
            claimedAt: now,
            processIdentifier: getpid()
        )
        do {
            try Self.writeClaimRecord(record, to: descriptor)
        } catch {
            if !existedBefore { try? FileManager.default.removeItem(at: claimURL) }
            throw error
        }
        handedOff = true
        return ShareInboxClaim(
            envelope: envelope,
            envelopeURL: directory,
            token: record.token,
            claimedAt: now,
            lease: ShareInboxClaimLease(descriptor: descriptor, claimURL: claimURL)
        )
    }

    /// Strict FIFO: the oldest valid envelope is the only candidate. A live
    /// claim on it blocks the queue (no younger envelope overtakes it); a
    /// corrupt or already-acknowledged head is skipped so one bad record
    /// cannot wedge every later share.
    public func claimNext(
        now: Date = Date(),
        epoch: String = ShareInboxProcessEpoch.value
    ) throws -> ShareInboxClaim? {
        for envelope in try pending(now: now) {
            do {
                return try claim(id: envelope.id, now: now, epoch: epoch)
            } catch ShareInboxError.claimBusy {
                throw ShareInboxError.claimBusy
            } catch ShareInboxError.invalidEnvelope, ShareInboxError.envelopeNotFound {
                continue
            }
        }
        return nil
    }

    /// Settles a claimed envelope. Only the live lease holder with the exact
    /// token can reach the directory rename. The source leaves the active
    /// namespace atomically before any best-effort deletion.
    public func ack(_ claim: ShareInboxClaim) throws {
        guard !claim.lease.isClosed else { throw ShareInboxError.invalidState }
        guard let record = Self.readClaimRecord(at: claim.lease.claimURL),
              record.token == claim.token else {
            throw ShareInboxError.claimTokenMismatch
        }
        guard Self.isRegularDirectory(claim.envelopeURL) else {
            claim.lease.close()
            throw ShareInboxError.envelopeNotFound
        }
        let destination = trashURL.appendingPathComponent(
            "\(claim.envelope.id.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: claim.envelopeURL, to: destination)
        } catch {
            throw ioError(.delete, error)
        }
        claim.lease.close()
        // The envelope is already unreachable; a failed physical deletion is
        // recovered by maintenance and must not turn the receipt into failure.
        try? FileManager.default.removeItem(at: destination)
        syncDirectory(rootURL)
        syncDirectory(trashURL)
    }

    public func release(_ claim: ShareInboxClaim) throws {
        guard !claim.lease.isClosed else { throw ShareInboxError.invalidState }
        guard let record = Self.readClaimRecord(at: claim.lease.claimURL),
              record.token == claim.token else {
            claim.lease.close()
            throw ShareInboxError.claimTokenMismatch
        }
        let claimURL = claim.lease.claimURL
        // Unlink while the exclusive lock is still held: closing first would
        // let another consumer claim the envelope and then have its fresh
        // claim file deleted by this stale release.
        do {
            try FileManager.default.removeItem(at: claimURL)
        } catch {
            claim.lease.close()
            throw ioError(.delete, error)
        }
        claim.lease.close()
    }

    /// Token-based settlement for crash recovery/tests. It still requires the
    /// exclusive lock, so a live claim (even in this process) is never
    /// settled behind its owner's back.
    @discardableResult
    public func ack(id: UUID, claimToken: String) throws -> Bool {
        let directory = envelopeDirectory(for: id)
        let claimURL = directory.appendingPathComponent(".claim")
        guard Self.isRegularFile(claimURL) else { return false }
        let descriptor = open(claimURL.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            throw ShareInboxError.claimBusy
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        guard let record = Self.readClaimRecord(at: claimURL),
              record.token == claimToken,
              Self.isRegularDirectory(directory) else {
            return false
        }
        let destination = trashURL.appendingPathComponent(
            "\(id.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: directory, to: destination)
        } catch {
            throw ioError(.delete, error)
        }
        try? FileManager.default.removeItem(at: destination)
        syncDirectory(rootURL)
        return true
    }

    @discardableResult
    public func release(id: UUID, claimToken: String) throws -> Bool {
        let directory = envelopeDirectory(for: id)
        let claimURL = directory.appendingPathComponent(".claim")
        guard Self.isRegularFile(claimURL) else { return false }
        let descriptor = open(claimURL.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            throw ShareInboxError.claimBusy
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        guard let record = Self.readClaimRecord(at: claimURL),
              record.token == claimToken else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: claimURL)
        } catch {
            throw ioError(.delete, error)
        }
        return true
    }

    // MARK: Maintenance

    /// Launch/foreground reconciliation. Non-throwing by design: a cleanup
    /// failure is reported, never allowed to erase pending shares or block
    /// the app.
    public func maintain(now: Date = Date()) -> ShareInboxMaintenanceReport {
        var report = ShareInboxMaintenanceReport()
        do {
            try ensureRoot()
        } catch {
            report.diagnostics.append(
                ShareInboxDiagnostic(kind: .rootUnavailable, detail: Self.diagnosticCode(for: error))
            )
            return report
        }

        // Only staging directories created by an aborted extension are
        // removed: they are dot-prefixed and were never committed.
        if let stagingDirectories = try? FileManager.default.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in stagingDirectories {
                guard Self.isRegularDirectory(url) else { continue }
                guard let modified = Self.modificationDate(of: url),
                      now.timeIntervalSince(modified) >= limits.stagingCleanupAge else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    report.removedStagingDirectories += 1
                } catch {
                    report.diagnostics.append(ShareInboxDiagnostic(
                        kind: .stagingCleanupFailed, detail: Self.diagnosticCode(for: error)
                    ))
                }
            }
        }

        if let trashDirectories = try? FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in trashDirectories {
                guard let modified = Self.modificationDate(of: url),
                      now.timeIntervalSince(modified) >= limits.trashCleanupAge else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    report.removedTrashDirectories += 1
                } catch {
                    report.diagnostics.append(ShareInboxDiagnostic(
                        kind: .trashCleanupFailed, detail: Self.diagnosticCode(for: error)
                    ))
                }
            }
        }

        guard let entries = try? envelopeDirectories() else {
            report.diagnostics.append(ShareInboxDiagnostic(
                kind: .rootUnavailable, detail: "enumerate"
            ))
            return report
        }
        for entry in entries {
            guard let envelope = try? decodeEnvelope(in: entry.url, expectedID: entry.id) else {
                report.diagnostics.append(ShareInboxDiagnostic(
                    kind: .unreadableEnvelope, id: entry.id, detail: "decode"
                ))
                continue
            }
            if now.timeIntervalSince(envelope.createdAt) > limits.ttl {
                if expireEnvelope(at: entry.url) { report.expiredEnvelopes += 1 }
                continue
            }
            let claimURL = entry.url.appendingPathComponent(".claim")
            guard FileManager.default.fileExists(atPath: claimURL.path) else { continue }
            if recoverClaimIfUnused(claimURL: claimURL, now: now) {
                report.recoveredClaims += 1
            }
        }
        return report
    }

    // MARK: Envelope helpers

    public func envelopeDirectory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func envelopeDirectories() throws -> [(id: UUID, url: URL)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ioError(.read, error)
        }
        var result: [(id: UUID, url: URL)] = []
        for url in contents {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), Self.isRegularDirectory(url) else { continue }
            guard let id = UUID(uuidString: name) else { continue }
            result.append((id, url))
        }
        return result
    }

    fileprivate func ensureRoot() throws {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            try Self.applyFileProtection(to: rootURL)
        } catch {
            throw ioError(.create, error)
        }
    }

    fileprivate func decodeEnvelope(in directory: URL, expectedID: UUID) throws -> ShareEnvelope {
        guard Self.isRegularDirectory(directory) else {
            throw ShareInboxError.invalidEnvelope(reason: "directory")
        }
        let manifestURL = directory.appendingPathComponent("envelope.json")
        guard Self.isRegularFile(manifestURL) else {
            throw ShareInboxError.invalidEnvelope(reason: "manifestMissing")
        }
        let manifestSize: Int
        do {
            manifestSize = try Self.regularFileSize(at: manifestURL)
        } catch {
            throw ShareInboxError.invalidEnvelope(reason: "manifestRead")
        }
        guard manifestSize > 0, manifestSize <= 65_536 else {
            throw ShareInboxError.invalidEnvelope(reason: "manifestTooLarge")
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ioError(.read, error)
        }
        guard data.count == manifestSize else {
            throw ShareInboxError.invalidEnvelope(reason: "manifestChanged")
        }
        let envelope: ShareEnvelope
        do {
            envelope = try Self.decoder().decode(ShareEnvelope.self, from: data)
        } catch {
            throw ShareInboxError.invalidEnvelope(reason: "manifestDecode")
        }
        guard envelope.schemaVersion == ShareEnvelope.currentSchemaVersion,
              envelope.id == expectedID,
              envelope.items.isEmpty == false,
              envelope.items.count <= limits.maxItems else {
            throw ShareInboxError.invalidEnvelope(reason: "schema")
        }
        var total = 0
        for item in envelope.items {
            guard item.byteCount >= 0 else {
                throw ShareInboxError.invalidEnvelope(reason: "itemSize")
            }
            total += item.byteCount
            guard total <= limits.maxEnvelopeBytes else {
                throw ShareInboxError.invalidEnvelope(reason: "envelopeSize")
            }
            switch item.kind {
            case .text, .url:
                guard item.storageName == nil, let text = item.text, !text.isEmpty else {
                    throw ShareInboxError.invalidEnvelope(reason: "textItem")
                }
                let textBytes = text.utf8.count
                guard textBytes == item.byteCount, textBytes <= limits.maxTextBytes else {
                    throw ShareInboxError.invalidEnvelope(reason: "textSize")
                }
            case .image, .file:
                guard item.byteCount > 0,
                      item.byteCount <= limits.maxItemBytes,
                      item.typeIdentifier?.isEmpty == false,
                      let digest = item.sha256,
                      digest.count == 64,
                      digest.allSatisfy({ $0.isHexDigit }) else {
                    throw ShareInboxError.invalidEnvelope(reason: "fileItem")
                }
                _ = try itemURL(item, in: directory)
            }
        }
        guard envelope.totalByteCount == total else {
            throw ShareInboxError.invalidEnvelope(reason: "total")
        }
        return envelope
    }

    fileprivate func itemURL(_ item: ShareInboxItem, in directory: URL) throws -> URL {
        guard let storageName = item.storageName,
              Self.isValidStorageName(storageName) else {
            throw ShareInboxError.invalidEnvelope(reason: "storageName")
        }
        let allowedRoot = directory.standardizedFileURL
        let url = allowedRoot.appendingPathComponent(storageName).standardizedFileURL
        let prefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard url.path.hasPrefix(prefix + "items/") else {
            throw ShareInboxError.invalidEnvelope(reason: "storagePath")
        }
        guard Self.isRegularFile(url) else {
            throw ShareInboxError.invalidEnvelope(reason: "storageFile")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              Int(info.st_size) == item.byteCount else {
            throw ShareInboxError.invalidEnvelope(reason: "storageSize")
        }
        return url
    }

    fileprivate func verifyAttachmentDigests(in envelope: ShareEnvelope, directory: URL) throws {
        for item in envelope.attachmentItems {
            let url = try itemURL(item, in: directory)
            let digest: String
            do {
                digest = try FloeDigest.sha256Hex(ofFileAt: url)
            } catch {
                throw ioError(.verify, error)
            }
            guard digest == item.sha256 else {
                throw ShareInboxError.invalidEnvelope(reason: "digestMismatch")
            }
        }
    }

    fileprivate func commitStaging(_ directory: URL, envelope: ShareEnvelope) throws {
        let lock = try acquireGlobalLock()
        defer {
            _ = flock(lock, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(lock)
            #elseif canImport(Glibc)
            _ = Glibc.close(lock)
            #endif
        }
        var pendingCount = 0
        var pendingBytes = 0
        let now = Date()
        for entry in try envelopeDirectories() {
            guard let existing = try? decodeEnvelope(in: entry.url, expectedID: entry.id) else {
                continue
            }
            // Expired envelopes are no longer pending. They are removed by
            // the app's maintenance pass; a share must not be rejected only
            // because unreviewed old bytes are still waiting for cleanup.
            guard now.timeIntervalSince(existing.createdAt) <= limits.ttl else { continue }
            pendingCount += 1
            pendingBytes += existing.totalByteCount
        }
        guard pendingCount < limits.maxPendingEnvelopes,
              pendingBytes + envelope.totalByteCount <= limits.maxPendingBytes else {
            throw ShareInboxError.queueFull(envelopes: pendingCount, bytes: pendingBytes)
        }
        let destination = envelopeDirectory(for: envelope.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ShareInboxError.ioFailure(stage: .commit, detail: "destinationExists")
        }
        do {
            try FileManager.default.moveItem(at: directory, to: destination)
        } catch {
            throw ioError(.commit, error)
        }
        syncDirectory(rootURL)
    }

    fileprivate func writeManifest(_ envelope: ShareEnvelope, in directory: URL) throws {
        let data: Data
        do {
            data = try Self.encoder().encode(envelope)
        } catch {
            throw ShareInboxError.ioFailure(stage: .write, detail: "manifestEncode")
        }
        let url = directory.appendingPathComponent("envelope.json")
        do {
            try data.write(to: url, options: [.atomic])
            try Self.applyFileProtection(to: url)
            try syncFile(url)
            syncDirectory(directory)
        } catch {
            throw ioError(.write, error)
        }
    }

    fileprivate func copyFileIntoStaging(
        from source: URL,
        to destination: URL,
        maxBytes: Int
    ) throws -> (byteCount: Int, sha256: String) {
        do {
            return try Self.copyRegularFile(
                from: source,
                to: destination,
                maxBytes: maxBytes,
                chunkBytes: limits.copyChunkBytes
            )
        } catch let error as ShareInboxError {
            throw error
        } catch {
            throw ioError(.copy, error)
        }
    }

    fileprivate func adoptFileIntoStaging(
        from source: URL,
        to destination: URL,
        maxBytes: Int
    ) throws -> (byteCount: Int, sha256: String) {
        // Only files inside this process's temporary directory may be moved.
        // Provider URLs and user documents are never adopted this way.
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard sourcePath.hasPrefix(temporaryRoot.hasSuffix("/") ? temporaryRoot : temporaryRoot + "/") else {
            throw ShareInboxError.invalidState
        }
        let size: Int
        do {
            size = try Self.regularFileSize(at: source)
        } catch {
            throw error
        }
        guard size <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: size, limit: maxBytes)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ShareInboxError.ioFailure(stage: .commit, detail: "destinationExists")
        }
        var moved = false
        #if canImport(Darwin) || canImport(Glibc)
        moved = rename(source.path, destination.path) == 0
        #endif
        if !moved {
            return try copyFileIntoStaging(from: source, to: destination, maxBytes: maxBytes)
        }
        do {
            try Self.applyFileProtection(to: destination)
            let finalSize = try Self.regularFileSize(at: destination)
            guard finalSize <= maxBytes else {
                try? FileManager.default.removeItem(at: destination)
                throw ShareInboxError.itemTooLarge(byteCount: finalSize, limit: maxBytes)
            }
            let digest = try FloeDigest.sha256Hex(ofFileAt: destination)
            return (finalSize, digest)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let error = error as? ShareInboxError { throw error }
            throw ioError(.verify, error)
        }
    }

    fileprivate func acquireGlobalLock() throws -> Int32 {
        let url = rootURL.appendingPathComponent(".lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else {
            throw Self.posixError(.commit, code: errno)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            throw ShareInboxError.claimBusy
        }
        return descriptor
    }

    fileprivate func expireEnvelope(at directory: URL) -> Bool {
        let claimURL = directory.appendingPathComponent(".claim")
        let descriptor = open(claimURL.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            return false
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        let destination = trashURL.appendingPathComponent(
            "\(directory.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        guard (try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.moveItem(at: directory, to: destination)) != nil else {
            return false
        }
        try? FileManager.default.removeItem(at: destination)
        syncDirectory(rootURL)
        return true
    }

    fileprivate func recoverClaimIfUnused(claimURL: URL, now: Date) -> Bool {
        let descriptor = open(claimURL.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
            return false
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        if let record = Self.readClaimRecord(at: claimURL),
           now.timeIntervalSince(record.claimedAt) < limits.claimRecoveryGrace {
            return false
        }
        if Self.readClaimRecord(at: claimURL) == nil,
           let modified = Self.modificationDate(of: claimURL),
           now.timeIntervalSince(modified) < limits.claimRecoveryGrace {
            return false
        }
        do {
            try FileManager.default.removeItem(at: claimURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: Static I/O

    /// Bounded POSIX copy used by the extension to take provider bytes into
    /// its own temporary directory before the provider URL expires. Never
    /// loads the file into memory and never follows a symlink source.
    @discardableResult
    public static func copyFileBounded(from source: URL, to destination: URL, maxBytes: Int) throws -> Int {
        do {
            return try copyRegularFile(
                from: source,
                to: destination,
                maxBytes: maxBytes,
                chunkBytes: 1_048_576
            ).byteCount
        } catch let error as ShareInboxError {
            throw error
        } catch {
            throw ShareInboxError.ioFailure(stage: .copy, detail: "copy")
        }
    }

    fileprivate static func copyRegularFile(
        from source: URL,
        to destination: URL,
        maxBytes: Int,
        chunkBytes: Int
    ) throws -> (byteCount: Int, sha256: String) {
        let size = try regularFileSize(at: source)
        guard size > 0 else {
            throw ShareInboxError.unsupportedItem(reason: "emptyFile")
        }
        guard size <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: size, limit: maxBytes)
        }
        #if canImport(Darwin) || canImport(Glibc)
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw posixError(.read, code: errno)
        }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(sourceDescriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(sourceDescriptor)
            #endif
        }
        var info = stat()
        guard fstat(sourceDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw ShareInboxError.unsupportedItem(reason: "notRegular")
        }
        guard Int(info.st_size) <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: Int(info.st_size), limit: maxBytes)
        }
        let destinationDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard destinationDescriptor >= 0 else {
            throw posixError(.write, code: errno)
        }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(destinationDescriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(destinationDescriptor)
            #endif
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 1)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total = 0
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        while true {
            let count = read(sourceDescriptor, buffer, chunkBytes)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(.read, code: code)
            }
            if count == 0 { break }
            total += count
            guard total <= maxBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: total, limit: maxBytes)
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let result = write(
                    destinationDescriptor,
                    buffer.advanced(by: written),
                    count - written
                )
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posixError(.write, code: code)
                }
                written += result
            }
        }
        guard total > 0 else {
            throw ShareInboxError.unsupportedItem(reason: "emptyFile")
        }
        if fsync(destinationDescriptor) != 0, errno != EINVAL {
            throw posixError(.write, code: errno)
        }
        try Self.applyFileProtection(to: destination)
        succeeded = true
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (total, digest)
        #else
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ShareInboxError.ioFailure(stage: .read, detail: "read")
        }
        guard data.count == size, data.count <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: maxBytes)
        }
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw ShareInboxError.ioFailure(stage: .write, detail: "write")
        }
        return (data.count, FloeDigest.sha256Hex(data))
        #endif
    }

    fileprivate static func regularFileSize(at url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw posixError(.read, code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ShareInboxError.unsupportedItem(reason: "notRegular")
        }
        return Int(info.st_size)
    }

    fileprivate static func writeClaimRecord(_ record: ShareInboxClaimRecord, to descriptor: Int32) throws {
        let data: Data
        do {
            data = try encoder().encode(record)
        } catch {
            throw ShareInboxError.ioFailure(stage: .claim, detail: "encode")
        }
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw posixError(.claim, code: errno)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posixError(.claim, code: code)
                }
                written += result
            }
        }
        if fsync(descriptor) != 0, errno != EINVAL {
            throw posixError(.claim, code: errno)
        }
    }

    fileprivate static func readClaimRecord(at url: URL) -> ShareInboxClaimRecord? {
        guard let size = try? regularFileSize(at: url), size > 0, size <= 4_096 else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), data.count == size else { return nil }
        return try? decoder().decode(ShareInboxClaimRecord.self, from: data)
    }

    fileprivate static func isValidStorageName(_ name: String) -> Bool {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "items" else { return false }
        let leaf = String(components[1])
        guard !leaf.isEmpty, leaf.count <= 64,
              !leaf.hasPrefix("."), !leaf.contains("\\"), !leaf.contains(":"),
              !leaf.contains("\0") else { return false }
        return leaf.range(
            of: #"^item-[0-9]{1,3}(?:\.[a-z0-9]{1,16})?$"#,
            options: .regularExpression
        ) != nil
    }

    fileprivate static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    fileprivate static func isRegularDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    fileprivate static func modificationDate(of url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    fileprivate static func diagnosticCode(for error: Error) -> String {
        switch error {
        case ShareInboxError.invalidEnvelope: return "invalidEnvelope"
        case ShareInboxError.envelopeNotFound: return "envelopeNotFound"
        case ShareInboxError.appGroupUnavailable: return "appGroupUnavailable"
        case ShareInboxError.ioFailure(let stage, _): return "ioFailure.\(stage.rawValue)"
        default: return "unreadable"
        }
    }

    fileprivate static func posixError(_ stage: ShareInboxIOStage, code: Int32) -> ShareInboxError {
        if code == ENOSPC { return .insufficientSpace }
        let detail = String(cString: strerror(code))
        return .ioFailure(stage: stage, detail: String(detail.prefix(120)))
    }

    fileprivate func ioError(_ stage: ShareInboxIOStage, _ error: Error) -> ShareInboxError {
        if let inboxError = error as? ShareInboxError { return inboxError }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .insufficientSpace
        }
        var detail = nsError.localizedDescription
        let root = rootURL.standardizedFileURL.path
        if !root.isEmpty {
            detail = detail.replacingOccurrences(of: root, with: "<path>")
        }
        detail = detail.replacingOccurrences(
            of: FileManager.default.temporaryDirectory.path,
            with: "<tmp>"
        )
        return .ioFailure(stage: stage, detail: String(detail.prefix(200)))
    }

    fileprivate func syncDirectory(_ url: URL) {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
        #endif
    }

    fileprivate func syncFile(_ url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw Self.posixError(.write, code: errno) }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
        if fsync(descriptor) != 0, errno != EINVAL {
            throw Self.posixError(.write, code: errno)
        }
        #endif
    }

    fileprivate static func applyFileProtection(to url: URL) throws {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    fileprivate func sanitizedProducer(_ producer: String) -> String {
        let trimmed = producer.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        return String(filtered.prefix(64)).isEmpty ? "Floe" : String(filtered.prefix(64))
    }

    fileprivate static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    fileprivate static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

// MARK: - Staging session

/// One producer transaction. Not thread-safe: the extension drives it
/// sequentially from its own process. After `commit()` the session never
/// touches the committed directory again, even if `cancel()` is called.
public final class ShareInboxStagingSession {
    private enum State {
        case open
        case committed
        case cancelled
    }

    public let envelopeID: UUID
    public let createdAt: Date

    private let inbox: ShareInbox
    private let producer: String
    private let stagingRoot: URL
    private let itemsRoot: URL
    private var items: [ShareInboxItem] = []
    private var totalBytes = 0
    private var state: State = .open

    fileprivate init(
        inbox: ShareInbox,
        envelopeID: UUID,
        createdAt: Date,
        producer: String,
        stagingRoot: URL,
        itemsRoot: URL
    ) {
        self.inbox = inbox
        self.envelopeID = envelopeID
        self.createdAt = createdAt
        self.producer = producer
        self.stagingRoot = stagingRoot
        self.itemsRoot = itemsRoot
    }

    public var stagedItemCount: Int { items.count }
    public var stagedByteCount: Int { totalBytes }

    public func append(_ input: ShareInboxInput) throws {
        switch input.payload {
        case .text(let text):
            try appendText(text, kind: .text, typeIdentifier: input.typeIdentifier)
        case .url(let value):
            try appendText(value, kind: .url, typeIdentifier: input.typeIdentifier)
        case .file(let url):
            try appendFile(
                at: url,
                displayName: input.displayName,
                typeIdentifier: input.typeIdentifier ?? "public.data",
                kind: input.kind == .image ? .image : .file
            )
        case .data(let data):
            guard input.kind != .text, input.kind != .url else {
                throw ShareInboxError.unsupportedItem(reason: "dataText")
            }
            try appendData(
                data,
                displayName: input.displayName,
                typeIdentifier: input.typeIdentifier ?? "public.data",
                kind: input.kind
            )
        }
    }

    public func appendText(
        _ text: String,
        kind: ShareInboxItemKind,
        typeIdentifier: String? = nil
    ) throws {
        try ensureOpen()
        guard kind == .text || kind == .url else {
            throw ShareInboxError.unsupportedItem(reason: "textKind")
        }
        let byteCount = text.utf8.count
        guard byteCount > 0 else {
            throw ShareInboxError.unsupportedItem(reason: "emptyText")
        }
        guard items.count < inbox.limits.maxItems else {
            throw ShareInboxError.itemLimitExceeded(limit: inbox.limits.maxItems)
        }
        guard byteCount <= inbox.limits.maxTextBytes else {
            throw ShareInboxError.textTooLarge(byteCount: byteCount, limit: inbox.limits.maxTextBytes)
        }
        guard totalBytes + byteCount <= inbox.limits.maxEnvelopeBytes else {
            throw ShareInboxError.envelopeTooLarge(
                byteCount: totalBytes + byteCount,
                limit: inbox.limits.maxEnvelopeBytes
            )
        }
        let resolvedType = typeIdentifier ?? (kind == .url ? "public.url" : "public.plain-text")
        items.append(ShareInboxItem(
            kind: kind,
            text: text,
            typeIdentifier: resolvedType,
            byteCount: byteCount
        ))
        totalBytes += byteCount
    }

    public func appendFile(
        at url: URL,
        displayName: String? = nil,
        typeIdentifier: String = "public.data",
        kind: ShareInboxItemKind = .file
    ) throws {
        try appendFile(
            at: url,
            displayName: displayName,
            typeIdentifier: typeIdentifier,
            kind: kind,
            adoptTemporary: false
        )
    }

    /// Moves a file that THIS process created inside its own temporary
    /// directory into the envelope. Provider URLs and user documents must use
    /// `appendFile` so their originals are never moved.
    public func adoptTemporaryFile(
        at url: URL,
        displayName: String? = nil,
        typeIdentifier: String = "public.data",
        kind: ShareInboxItemKind = .file
    ) throws {
        try appendFile(
            at: url,
            displayName: displayName,
            typeIdentifier: typeIdentifier,
            kind: kind,
            adoptTemporary: true
        )
    }

    public func appendData(
        _ data: Data,
        displayName: String? = nil,
        typeIdentifier: String = "public.data",
        kind: ShareInboxItemKind = .image
    ) throws {
        try ensureOpen()
        guard kind == .image || kind == .file else {
            throw ShareInboxError.unsupportedItem(reason: "dataKind")
        }
        guard !data.isEmpty else {
            throw ShareInboxError.unsupportedItem(reason: "emptyData")
        }
        guard items.count < inbox.limits.maxItems else {
            throw ShareInboxError.itemLimitExceeded(limit: inbox.limits.maxItems)
        }
        guard data.count <= inbox.limits.maxItemBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: inbox.limits.maxItemBytes)
        }
        guard totalBytes + data.count <= inbox.limits.maxEnvelopeBytes else {
            throw ShareInboxError.envelopeTooLarge(
                byteCount: totalBytes + data.count,
                limit: inbox.limits.maxEnvelopeBytes
            )
        }
        let storageName = storageName(
            index: items.count,
            sourceURL: nil,
            displayName: displayName,
            typeIdentifier: typeIdentifier
        )
        let destination = stagingRoot.appendingPathComponent(storageName)
        do {
            try data.write(to: destination, options: [.atomic])
            try ShareInbox.applyFileProtection(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw inbox.ioError(.write, error)
        }
        let digest = FloeDigest.sha256Hex(data)
        items.append(ShareInboxItem(
            kind: kind,
            fileName: normalizedDisplayName(displayName),
            storageName: storageName,
            typeIdentifier: typeIdentifier,
            byteCount: data.count,
            sha256: digest
        ))
        totalBytes += data.count
    }

    public func commit() throws -> ShareEnvelope {
        guard state == .open else {
            throw ShareInboxError.invalidState
        }
        guard !items.isEmpty, totalBytes > 0 else {
            throw ShareInboxError.emptyEnvelope
        }
        let envelope = ShareEnvelope(
            id: envelopeID,
            createdAt: createdAt,
            schemaVersion: ShareEnvelope.currentSchemaVersion,
            producer: producer,
            items: items,
            totalByteCount: totalBytes
        )
        // Manifest last: until this succeeds the directory is staging-only.
        try inbox.writeManifest(envelope, in: stagingRoot)
        try inbox.commitStaging(stagingRoot, envelope: envelope)
        state = .committed
        return envelope
    }

    /// Removes only this session's uncommitted staging bytes. Provider
    /// originals and other envelopes are never touched.
    public func cancel() {
        guard state == .open else { return }
        state = .cancelled
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: Private

    private func appendFile(
        at url: URL,
        displayName: String?,
        typeIdentifier: String,
        kind: ShareInboxItemKind,
        adoptTemporary: Bool
    ) throws {
        try ensureOpen()
        guard kind == .image || kind == .file else {
            throw ShareInboxError.unsupportedItem(reason: "fileKind")
        }
        guard items.count < inbox.limits.maxItems else {
            throw ShareInboxError.itemLimitExceeded(limit: inbox.limits.maxItems)
        }
        let size: Int
        do {
            size = try ShareInbox.regularFileSize(at: url)
        } catch let error as ShareInboxError {
            throw error
        } catch {
            throw inbox.ioError(.read, error)
        }
        guard size > 0 else {
            throw ShareInboxError.unsupportedItem(reason: "emptyFile")
        }
        guard size <= inbox.limits.maxItemBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: size, limit: inbox.limits.maxItemBytes)
        }
        guard totalBytes + size <= inbox.limits.maxEnvelopeBytes else {
            throw ShareInboxError.envelopeTooLarge(
                byteCount: totalBytes + size,
                limit: inbox.limits.maxEnvelopeBytes
            )
        }
        let storageName = storageName(
            index: items.count,
            sourceURL: url,
            displayName: displayName,
            typeIdentifier: typeIdentifier
        )
        let destination = stagingRoot.appendingPathComponent(storageName)
        let maxBytes = min(inbox.limits.maxItemBytes, inbox.limits.maxEnvelopeBytes - totalBytes)
        let copied: (byteCount: Int, sha256: String)
        if adoptTemporary {
            copied = try inbox.adoptFileIntoStaging(from: url, to: destination, maxBytes: maxBytes)
        } else {
            copied = try inbox.copyFileIntoStaging(from: url, to: destination, maxBytes: maxBytes)
        }
        guard totalBytes + copied.byteCount <= inbox.limits.maxEnvelopeBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw ShareInboxError.envelopeTooLarge(
                byteCount: totalBytes + copied.byteCount,
                limit: inbox.limits.maxEnvelopeBytes
            )
        }
        items.append(ShareInboxItem(
            kind: kind,
            fileName: normalizedDisplayName(displayName) ?? normalizedDisplayName(url.lastPathComponent),
            storageName: storageName,
            typeIdentifier: typeIdentifier,
            byteCount: copied.byteCount,
            sha256: copied.sha256
        ))
        totalBytes += copied.byteCount
    }

    private func storageName(
        index: Int,
        sourceURL: URL?,
        displayName: String?,
        typeIdentifier: String
    ) -> String {
        let base = "items/item-\(index)"
        if let suffix = ShareInboxStagingSession.fileExtension(
            sourceURL: sourceURL,
            displayName: displayName,
            typeIdentifier: typeIdentifier
        ) {
            return "\(base).\(suffix)"
        }
        return base
    }

    private func normalizedDisplayName(_ name: String?) -> String? {
        guard let name else { return nil }
        let leaf = (name as NSString).lastPathComponent
        let filtered = leaf.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }

    private func ensureOpen() throws {
        guard state == .open else { throw ShareInboxError.invalidState }
    }

    private static func fileExtension(
        sourceURL: URL?,
        displayName: String?,
        typeIdentifier: String
    ) -> String? {
        var candidate = sourceURL?.pathExtension ?? ""
        if candidate.isEmpty, let displayName {
            candidate = (displayName as NSString).pathExtension
        }
        if candidate.isEmpty {
            candidate = extensionForType(typeIdentifier) ?? ""
        }
        let cleaned = candidate.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard !cleaned.isEmpty, cleaned.count <= 16 else { return nil }
        return cleaned
    }

    private static func extensionForType(_ identifier: String) -> String? {
        switch identifier {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        case "com.compuserve.gif": return "gif"
        case "public.tiff": return "tiff"
        case "com.adobe.pdf": return "pdf"
        case "public.plain-text": return "txt"
        case "public.rtf": return "rtf"
        case "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document": return "docx"
        case "org.openxmlformats.spreadsheetml.sheet": return "xlsx"
        case "org.openxmlformats.presentationml.presentation": return "pptx"
        case "public.mpeg-4": return "mp4"
        case "com.apple.quicktime-movie": return "mov"
        default: return nil
        }
    }
}

// MARK: - Convenience naming

public extension ShareInbox {
    typealias StagingSession = ShareInboxStagingSession
}
