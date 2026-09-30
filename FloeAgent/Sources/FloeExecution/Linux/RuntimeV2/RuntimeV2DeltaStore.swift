// FloeExecution — Runtime v2 per-environment block delta (system/delta.*).
//
// The environment's system state — every modification the guest made to
// /etc, /usr, /var, APT state and the global Python/Node installs — lives
// exactly once, as a block-level delta against the verified base rootfs:
//
//   system/delta.header  JSON: environment id, base image/digest, block size,
//                        capacity, generation. The id must match the parent
//                        directory name; a mismatch is corruption.
//   system/delta.bitmap  magic + generation + one bit per base-size block:
//                        set bits name the blocks present in delta.data.
//   system/delta.data    magic + generation + the differing blocks in block
//                        index order.
//
// The base rootfs itself lives once, content-addressed and read-only, in the
// image blob store; a VM boots a working disk materialized by cloning the
// base (APFS copy-on-write) and applying the delta blocks. `capture` writes
// the delta back after a clean stop using a sparse-aware diff (only
// allocated extents are compared), staged files and an atomic three-file
// promote keyed by a shared generation: an interrupted capture can never
// replace a consistent older delta with a partial newer one. All three files
// must agree on the generation or the delta is corrupt and quarantined —
// never silently applied, never overwritten in place.
//
// The pinned TinyEMU block path is a raw RW file (no qcow2, no online
// overlay), so the overlay lives host-side in this format; the engine only
// ever sees the materialized working disk.

import Foundation
import FloeCore

public actor RuntimeV2DeltaStore {
    public static let blockSize: Int64 = 1 << 20 // 1 MiB
    private static let bitmapMagic = Array("FLDLTBMP".utf8)
    private static let dataMagic = Array("FLDLTDAT".utf8)
    private static let fileHeaderBytes = 8 + 8 + 4 + 4

    /// Test-only fault injection for the working-disk block read loop. Called
    /// (actor-isolated, synchronously) before every block read of the
    /// WORKING disk; throw to simulate an open/read fault with a typed errno
    /// at exactly that stage. nil in production. The probe never intercepts
    /// base-rootfs reads or staged writes: the stop-capture retry contract is
    /// proven against working-disk access faults.
    var workingDiskReadProbe: (@Sendable (URL) throws -> Void)?

    /// Installs or removes the test-only read probe. A method, not a bare
    /// property set, because a cross-actor mutation must enter the actor.
    func installWorkingDiskReadProbe(_ probe: (@Sendable (URL) throws -> Void)?) {
        workingDiskReadProbe = probe
    }

    public struct DeltaHeader: Codable, Sendable, Equatable {
        public var version: Int
        public var environmentID: String
        public var baseImageID: String
        public var baseRootfsSHA512: String
        public var baseBytes: Int64
        public var blockSize: Int64
        public var capacityBytes: Int64
        public var generation: UInt64
        public var updatedAt: Date
        /// Immutable template pin this delta was captured from (nil = a base
        /// image only). The binding is the whole reason an old delta can never
        /// be replayed over a different template version.
        public var templateID: String?
        public var templateVersion: Int?
        public var templateDigest: String?

        public static let currentVersion = 1

        public init(
            environmentID: String, baseImageID: String, baseRootfsSHA512: String,
            baseBytes: Int64, blockSize: Int64, capacityBytes: Int64,
            generation: UInt64, updatedAt: Date,
            templateID: String? = nil, templateVersion: Int? = nil, templateDigest: String? = nil
        ) {
            self.version = DeltaHeader.currentVersion
            self.environmentID = environmentID
            self.baseImageID = baseImageID
            self.baseRootfsSHA512 = baseRootfsSHA512
            self.baseBytes = baseBytes
            self.blockSize = blockSize
            self.capacityBytes = capacityBytes
            self.generation = generation
            self.updatedAt = updatedAt
            self.templateID = templateID
            self.templateVersion = templateVersion
            self.templateDigest = templateDigest
        }
    }

    public struct DeltaInfo: Sendable, Equatable {
        public var header: DeltaHeader
        public var presentBlocks: Int
        public var deltaBytes: Int64
    }

    private let layout: RuntimeV2Layout
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.layout = layout
    }

    // MARK: paths

    private func headerURL(_ environmentID: String) throws -> URL {
        try layout.environmentSystemDirectory(environmentID: environmentID)
            .appendingPathComponent("delta.header")
    }

    private func bitmapURL(_ environmentID: String) throws -> URL {
        try layout.environmentSystemDirectory(environmentID: environmentID)
            .appendingPathComponent("delta.bitmap")
    }

    private func dataURL(_ environmentID: String) throws -> URL {
        try layout.environmentSystemDirectory(environmentID: environmentID)
            .appendingPathComponent("delta.data")
    }

    // MARK: load + validate

    /// Loads a consistent delta, or nil when no delta exists (environment is
    /// pristine base). Generation disagreement, a foreign environment id or a
    /// truncated payload is corruption: the files are quarantined and the
    /// error explains exactly why — the delta is never partially trusted.
    public func loadDelta(environmentID: String) throws -> DeltaInfo? {
        let headerURL = try headerURL(environmentID)
        guard fileManager.fileExists(atPath: headerURL.path) else { return nil }
        do {
            return try loadConsistentDelta(environmentID: environmentID)
        } catch {
            try quarantineCorrupt(environmentID: environmentID)
            throw error
        }
    }

    private func loadConsistentDelta(environmentID: String) throws -> DeltaInfo {
        let headerData = try Data(contentsOf: try headerURL(environmentID))
        let header: DeltaHeader
        do {
            header = try Self.decoder.decode(DeltaHeader.self, from: headerData)
        } catch {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "delta.header does not decode")
        }
        guard header.version == DeltaHeader.currentVersion else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "unsupported header version \(header.version)")
        }
        guard header.environmentID == environmentID else {
            throw RuntimeV2Error.deltaCorrupt(
                environmentID: environmentID,
                reason: "header names environment \(header.environmentID), not the containing directory \(environmentID)"
            )
        }
        guard header.baseRootfsSHA512.count == 128,
              header.baseRootfsSHA512.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "base digest is not SHA-512 hex")
        }
        guard header.blockSize > 0, header.capacityBytes >= 0, header.baseBytes >= 0 else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "negative or zero geometry")
        }
        // Template binding consistency: all three fields or none, with a real
        // version and a SHA-512 digest.
        let templateFields = [header.templateID != nil, header.templateVersion != nil, header.templateDigest != nil]
        if templateFields.contains(true) {
            guard templateFields.allSatisfy({ $0 }),
                  let templateVersion = header.templateVersion,
                  templateVersion >= 1,
                  let templateDigest = header.templateDigest,
                  templateDigest.count == 128,
                  templateDigest.allSatisfy({ $0.isHexDigit }) else {
                throw RuntimeV2Error.deltaCorrupt(
                    environmentID: environmentID,
                    reason: "partial or malformed template pin in the delta header"
                )
            }
        }
        let blockCount = Int((header.capacityBytes + header.blockSize - 1) / header.blockSize)
        let (bitmapGeneration, bitmap) = try readBlockFile(
            try bitmapURL(environmentID), magic: Self.bitmapMagic, environmentID: environmentID
        )
        let (dataGeneration, payload) = try readBlockFile(
            try dataURL(environmentID), magic: Self.dataMagic, environmentID: environmentID
        )
        guard bitmapGeneration == header.generation, dataGeneration == header.generation else {
            throw RuntimeV2Error.deltaCorrupt(
                environmentID: environmentID,
                reason: "generation disagreement (header \(header.generation), bitmap \(bitmapGeneration), data \(dataGeneration)); an interrupted capture was discarded"
            )
        }
        let expectedBitmapBytes = (blockCount + 7) / 8
        guard bitmap.count == expectedBitmapBytes else {
            throw RuntimeV2Error.deltaCorrupt(
                environmentID: environmentID,
                reason: "bitmap has \(bitmap.count) bytes, expected \(expectedBitmapBytes)"
            )
        }
        var present = 0
        for index in 0..<blockCount where (bitmap[index / 8] & (1 << (index % 8))) != 0 {
            present += 1
        }
        guard Int64(payload.count) == Int64(present) * header.blockSize else {
            throw RuntimeV2Error.deltaCorrupt(
                environmentID: environmentID,
                reason: "delta.data holds \(payload.count) bytes but the bitmap names \(present) blocks"
            )
        }
        return DeltaInfo(header: header, presentBlocks: present, deltaBytes: Int64(payload.count))
    }

    /// Moves a corrupt system/ tree aside. Quarantine is separate from
    /// user-deletion trash and is bounded by the recovery scan.
    private func quarantineCorrupt(environmentID: String) throws {
        let system = try layout.environmentSystemDirectory(environmentID: environmentID)
        guard fileManager.fileExists(atPath: system.path) else { return }
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("delta-\(environmentID)-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.moveItem(at: system, to: quarantine)
    }

    // MARK: materialize (base clone + delta apply → working disk)

    /// Builds the per-VM working disk: a copy-on-write clone of the verified
    /// base rootfs (or the pinned template's disk) with every delta block
    /// applied at its offset. The result is writable; the base stays read-only
    /// and shared.
    ///
    /// `expectedBaseRootfsSHA512` and `expectedTemplate` bind the delta to the
    /// exact base the caller is about to boot. A delta captured from another
    /// base or another template version is refused, never applied.
    public func materializeWorkingDisk(
        environmentID: String,
        baseRootfs: URL,
        expectedBaseRootfsSHA512: String? = nil,
        expectedTemplate: RuntimeV2TemplatePin? = nil,
        into workingDisk: URL
    ) throws -> Int64 {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        try fileManager.createDirectory(
            at: workingDisk.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: workingDisk.path) {
            try fileManager.removeItem(at: workingDisk)
        }
        #if canImport(Darwin)
        if clonefile(baseRootfs.path, workingDisk.path, 0) != 0 {
            try fileManager.copyItem(at: baseRootfs, to: workingDisk)
        }
        #else
        try fileManager.copyItem(at: baseRootfs, to: workingDisk)
        #endif
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: workingDisk.path)
        return try applyDelta(
            environmentID: environmentID,
            expectedBaseRootfsSHA512: expectedBaseRootfsSHA512,
            expectedTemplate: expectedTemplate,
            into: workingDisk
        )
    }

    /// Applies the environment's private delta over an already-materialized
    /// working disk (the caller cloned the pinned template disk or the base
    /// rootfs). Validates the full base binding before writing one byte.
    @discardableResult
    public func applyDelta(
        environmentID: String,
        expectedBaseRootfsSHA512: String? = nil,
        expectedTemplate: RuntimeV2TemplatePin? = nil,
        into workingDisk: URL
    ) throws -> Int64 {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        guard fileManager.fileExists(atPath: workingDisk.path) else {
            throw RuntimeV2Error.deltaCorrupt(
                environmentID: environmentID,
                reason: "the working disk is missing before the delta could be applied"
            )
        }
        let diskSize = (try fileManager.attributesOfItem(atPath: workingDisk.path)[.size] as? Int64) ?? 0
        guard let info = try loadDelta(environmentID: environmentID) else {
            return diskSize
        }
        if let expectedBaseRootfsSHA512,
           info.header.baseRootfsSHA512.lowercased() != expectedBaseRootfsSHA512.lowercased() {
            throw RuntimeV2Error.deltaBaseConflict(
                environmentID: environmentID,
                recorded: info.header.baseRootfsSHA512,
                verified: expectedBaseRootfsSHA512.lowercased()
            )
        }
        try verifyTemplateBinding(
            header: info.header, expectedTemplate: expectedTemplate, environmentID: environmentID
        )
        let (bitmapGeneration, bitmap) = try readBlockFile(
            try bitmapURL(environmentID), magic: Self.bitmapMagic, environmentID: environmentID
        )
        let (dataGeneration, payload) = try readBlockFile(
            try dataURL(environmentID), magic: Self.dataMagic, environmentID: environmentID
        )
        guard bitmapGeneration == info.header.generation, dataGeneration == info.header.generation else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "delta changed while materializing")
        }
        let handle = try FileHandle(forWritingTo: workingDisk)
        defer { try? handle.close() }
        let blockCount = Int((info.header.capacityBytes + info.header.blockSize - 1) / info.header.blockSize)
        var payloadOffset = 0
        for index in 0..<blockCount where (bitmap[index / 8] & (1 << (index % 8))) != 0 {
            let block = payload.subdata(in: payloadOffset..<(payloadOffset + Int(info.header.blockSize)))
            try handle.seek(toOffset: UInt64(Int64(index) * info.header.blockSize))
            try handle.write(contentsOf: block)
            payloadOffset += Int(info.header.blockSize)
        }
        try handle.truncate(atOffset: UInt64(info.header.capacityBytes))
        try handle.synchronize()
        return max(info.header.capacityBytes, diskSize)
    }

    // MARK: base binding

    /// Human-readable identity of the base a delta was captured from.
    public nonisolated static func baseIdentity(of header: DeltaHeader) -> String {
        if let id = header.templateID, let version = header.templateVersion, let digest = header.templateDigest {
            return "template \(id)@\(version) (\(digest.prefix(16))…)"
        }
        return "base image \(header.baseImageID) (\(header.baseRootfsSHA512.prefix(16))…)"
    }

    /// Refuses a delta whose recorded template binding is not exactly the
    /// template the caller is about to boot. An unpinned base-image delta over
    /// a template disk (and vice versa) is the same conflict: the install
    /// state was captured from different bytes.
    private func verifyTemplateBinding(
        header: DeltaHeader, expectedTemplate: RuntimeV2TemplatePin?, environmentID: String
    ) throws {
        if let expected = expectedTemplate {
            guard let id = header.templateID,
                  let version = header.templateVersion,
                  let digest = header.templateDigest else {
                throw RuntimeV2Error.deltaTemplateConflict(
                    environmentID: environmentID,
                    recorded: Self.baseIdentity(of: header),
                    verified: expected.describedIdentity
                )
            }
            guard id == expected.templateID,
                  version == expected.version,
                  digest.lowercased() == expected.digest.lowercased() else {
                throw RuntimeV2Error.deltaTemplateConflict(
                    environmentID: environmentID,
                    recorded: Self.baseIdentity(of: header),
                    verified: expected.describedIdentity
                )
            }
        } else if header.templateID != nil {
            throw RuntimeV2Error.deltaTemplateConflict(
                environmentID: environmentID,
                recorded: Self.baseIdentity(of: header),
                verified: "base image \(header.baseImageID)"
            )
        }
    }

    // MARK: capture (working disk → staged, verified, atomically promoted delta)

    /// Captures every block in `workingDisk` that differs from `baseRootfs`
    /// into the environment's delta. Sparse-aware: only allocated extents of
    /// the working disk are compared, so capturing a mostly-holes 8 GiB disk
    /// never reads 8 GiB. The new generation is fully staged and fsynced
    /// before the atomic promote; a crash at any point leaves the previous
    /// consistent delta in place.
    public func capture(
        environmentID: String,
        workingDisk: URL,
        baseRootfs: URL,
        baseImageID: String,
        baseRootfsSHA512: String,
        templatePin: RuntimeV2TemplatePin? = nil
    ) throws -> DeltaInfo {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        let previous = try loadDelta(environmentID: environmentID)
        if let previous, previous.header.baseRootfsSHA512 != baseRootfsSHA512.lowercased() {
            // A base swap is an adoption decision (compatibleOrigins), never a
            // silent overwrite: refuse and keep both states.
            throw RuntimeV2Error.deltaBaseConflict(
                environmentID: environmentID,
                recorded: previous.header.baseRootfsSHA512,
                verified: baseRootfsSHA512.lowercased()
            )
        }
        if let previous {
            // The recorded template binding must still be the pin we are
            // capturing against. An environment pinned to template v2 must
            // never fold its state into (or out of) template v1's bytes.
            let recordedMatches = previous.header.templateID == templatePin?.templateID
                && previous.header.templateVersion == templatePin?.version
                && (previous.header.templateDigest ?? "").lowercased() == (templatePin?.digest ?? "").lowercased()
            guard recordedMatches else {
                throw RuntimeV2Error.deltaTemplateConflict(
                    environmentID: environmentID,
                    recorded: Self.baseIdentity(of: previous.header),
                    verified: templatePin?.describedIdentity ?? "base image \(baseImageID)"
                )
            }
        }

        let baseSize = (try fileManager.attributesOfItem(atPath: baseRootfs.path)[.size] as? Int64) ?? 0
        let workingSize = (try fileManager.attributesOfItem(atPath: workingDisk.path)[.size] as? Int64) ?? 0
        let capacity = max(workingSize, baseSize)
        let blockSize = RuntimeV2DeltaStore.blockSize
        let blockCount = Int((capacity + blockSize - 1) / blockSize)

        let generation = (previous?.header.generation ?? 0) &+ 1

        // Stage in a sibling directory, fsync, then promote: header last, so a
        // crash before the header rename keeps the previous generation's
        // three-file agreement intact. delta.data is streamed block-by-block
        // so capturing a large delta never holds it in memory.
        let system = try layout.environmentSystemDirectory(environmentID: environmentID)
        let staging = system.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedData = staging.appendingPathComponent("delta.data")
        try fileManager.createFile(atPath: stagedData.path, contents: nil)
        let dataHandle: FileHandle
        do {
            dataHandle = try FileHandle(forWritingTo: stagedData)
        } catch {
            throw FloeFileIOError(stage: .open, underlying: error, path: stagedData.path)
        }
        // The handle must close on EVERY exit after this point — including a
        // header-write or synchronize failure — so a failed capture never
        // leaks the staged file descriptor.
        var dataHandleClosed = false
        defer { if !dataHandleClosed { try? dataHandle.close() } }
        var fileHeader = Data(Self.dataMagic)
        withUnsafeBytes(of: generation.littleEndian) { fileHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockSize).littleEndian) { fileHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockCount).littleEndian) { fileHeader.append(contentsOf: $0) }
        // A staged-write failure (typically a full disk) stays raw: it is a
        // local, non-transient condition that must never trigger the
        // stop-capture retry, and the caller preserves the working disk
        // either way.
        try dataHandle.write(contentsOf: fileHeader)

        let baseHandle: FileHandle
        do {
            baseHandle = try FileHandle(forReadingFrom: baseRootfs)
        } catch {
            throw FloeFileIOError(stage: .open, underlying: error, path: baseRootfs.path)
        }
        defer { try? baseHandle.close() }
        let workingHandle: FileHandle
        do {
            workingHandle = try FileHandle(forReadingFrom: workingDisk)
        } catch {
            throw FloeFileIOError(stage: .open, underlying: error, path: workingDisk.path)
        }
        defer { try? workingHandle.close() }

        var bitmap = [UInt8](repeating: 0, count: (blockCount + 7) / 8)
        var payloadBytes: Int64 = 0
        // The block loop reads through raw POSIX pread/pwrite into TWO reused
        // block buffers: whatever the disk size, the capture never holds more
        // than two blocks plus one staged-write in flight. Per-block
        // FileHandle.read NSData accumulation is exactly the bounded-lifetime
        // gap that turned a large-image hash into an errno-12 ENOMEM, and a
        // stop capture over a multi-GiB sparse disk iterates thousands of
        // blocks.
        let blockBytes = Int(blockSize)
        let workingBuffer = UnsafeMutableRawPointer.allocate(byteCount: blockBytes, alignment: 512)
        let baseBuffer = UnsafeMutableRawPointer.allocate(byteCount: blockBytes, alignment: 512)
        defer {
            workingBuffer.deallocate()
            baseBuffer.deallocate()
        }
        let zeroBlock = Data(count: blockBytes)
        var stagedOffset = Int64(fileHeader.count)
        do {
            for extent in try dataExtents(of: workingDisk, fileSize: workingSize) {
                var offset = extent.lowerBound - (extent.lowerBound % blockSize)
                while offset < extent.upperBound {
                    try Task.checkCancellation()
                    if let probe = workingDiskReadProbe {
                        try probe(workingDisk)
                    }
                    let index = Int(offset / blockSize)
                    let wanted = Int(min(blockSize, workingSize - offset))
                    try Self.readBlock(
                        into: workingBuffer, from: workingHandle.fileDescriptor,
                        at: offset, wanted: wanted, bufferCapacity: blockBytes,
                        fileSize: workingSize
                    )
                    let differs: Bool
                    if offset < baseSize {
                        try Self.readBlock(
                            into: baseBuffer, from: baseHandle.fileDescriptor,
                            at: offset, wanted: Int(min(blockSize, baseSize - offset)),
                            bufferCapacity: blockBytes, fileSize: baseSize
                        )
                        differs = memcmp(workingBuffer, baseBuffer, blockBytes) != 0
                    } else {
                        differs = zeroBlock.withUnsafeBytes {
                            memcmp(workingBuffer, $0.baseAddress!, blockBytes) != 0
                        }
                    }
                    if differs {
                        bitmap[index / 8] |= UInt8(1 << (index % 8))
                        try Self.writeAll(
                            dataHandle.fileDescriptor, buffer: workingBuffer,
                            count: blockBytes, at: stagedOffset
                        )
                        stagedOffset += blockSize
                        payloadBytes += blockSize
                    }
                    offset += blockSize
                }
            }
        } catch {
            throw error
        }
        try dataHandle.synchronize()
        try dataHandle.close()
        dataHandleClosed = true

        let header = DeltaHeader(
            environmentID: environmentID,
            baseImageID: baseImageID,
            baseRootfsSHA512: baseRootfsSHA512.lowercased(),
            baseBytes: baseSize,
            blockSize: blockSize,
            capacityBytes: capacity,
            generation: generation,
            updatedAt: Date(),
            templateID: templatePin?.templateID,
            templateVersion: templatePin?.version,
            templateDigest: templatePin?.digest.lowercased()
        )
        try writeBlockFile(
            Data(bitmap), generation: generation, magic: Self.bitmapMagic,
            blockSize: blockSize, blockCount: blockCount,
            to: staging.appendingPathComponent("delta.bitmap")
        )
        try Self.encoder.encode(header).write(
            to: staging.appendingPathComponent("delta.header"), options: .atomic
        )

        for name in ["delta.bitmap", "delta.data", "delta.header"] {
            let from = staging.appendingPathComponent(name)
            let to = system.appendingPathComponent(name)
            guard rename(from.path, to.path) == 0 else {
                throw RuntimeV2Error.deltaCorrupt(
                    environmentID: environmentID,
                    reason: "promote of \(name) failed (errno \(errno)); the previous delta is intact"
                )
            }
        }
        var present = 0
        for index in 0..<blockCount where (bitmap[index / 8] & (1 << (index % 8))) != 0 {
            present += 1
        }
        return DeltaInfo(header: header, presentBlocks: present, deltaBytes: payloadBytes)
    }

    /// Records a clean or interrupted shutdown. This sidecar is how an app
    /// restart tells "the VM was stopped and the delta captured" from "the
    /// process died with the VM live": interrupted sessions are explicit.
    public struct ShutdownRecord: Codable, Sendable, Equatable {
        public var environmentID: String
        public var runtimeID: String
        public var stoppedAt: Date
        public var clean: Bool
        public var deltaGeneration: UInt64?
        public var detail: String?

        public init(environmentID: String, runtimeID: String, stoppedAt: Date, clean: Bool, deltaGeneration: UInt64?, detail: String? = nil) {
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.stoppedAt = stoppedAt
            self.clean = clean
            self.deltaGeneration = deltaGeneration
            self.detail = detail
        }
    }

    public func recordShutdown(_ record: ShutdownRecord, environmentID: String) throws {
        let url = try layout.environmentLastShutdownURL(environmentID: environmentID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
    }

    public func lastShutdown(environmentID: String) throws -> ShutdownRecord? {
        let url = try layout.environmentLastShutdownURL(environmentID: environmentID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(ShutdownRecord.self, from: data)
    }

    // MARK: block file + extent helpers

    private func writeBlockFile(
        _ payload: Data, generation: UInt64, magic: [UInt8],
        blockSize: Int64, blockCount: Int, to url: URL
    ) throws {
        var file = Data(magic)
        withUnsafeBytes(of: generation.littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockSize).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockCount).littleEndian) { file.append(contentsOf: $0) }
        file.append(payload)
        try file.write(to: url, options: .atomic)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func readBlockFile(
        _ url: URL, magic: [UInt8], environmentID: String
    ) throws -> (generation: UInt64, payload: Data) {
        guard let raw = try? Data(contentsOf: url), raw.count >= Self.fileHeaderBytes else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "\(url.lastPathComponent) is missing or truncated")
        }
        guard Array(raw.prefix(magic.count)) == magic else {
            throw RuntimeV2Error.deltaCorrupt(environmentID: environmentID, reason: "\(url.lastPathComponent) has a bad magic")
        }
        var generation: UInt64 = 0
        withUnsafeMutableBytes(of: &generation) { destination in
            raw.copyBytes(to: destination, from: 8..<16)
        }
        return (UInt64(littleEndian: generation), raw.subdata(in: Self.fileHeaderBytes..<raw.count))
    }

    /// Reads exactly `wanted` bytes at `offset` through pread(2) into a reused
    /// caller-owned buffer (no per-block Foundation allocation, so a large
    /// capture's memory stays bounded however many blocks the disk holds),
    /// then zeroes the buffer tail up to `bufferCapacity` so a partial tail
    /// block compares like the sparse read it replaces. EINTR retries; any
    /// other failure becomes a typed, path-free error with the real POSIX
    /// errno. EOF before `wanted` bytes — the file shrank under the capture —
    /// is NOT zero-padded: fabricated zeros would corrupt the recorded delta,
    /// so it fails and the caller preserves the disk.
    private static func readBlock(
        into buffer: UnsafeMutableRawPointer,
        from descriptor: Int32,
        at offset: Int64,
        wanted: Int,
        bufferCapacity: Int,
        fileSize: Int64
    ) throws {
        guard wanted > 0 else {
            memset(buffer, 0, bufferCapacity)
            return
        }
        var filled = 0
        while filled < wanted {
            let count = pread(
                descriptor, buffer.advanced(by: filled), wanted - filled,
                offset + Int64(filled)
            )
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw FloeFileIOError(
                    stage: .read,
                    posixErrno: code,
                    detail: Self.posixDetail(code),
                    domain: NSPOSIXErrorDomain,
                    code: Int(code)
                )
            }
            if count == 0 {
                throw FloeFileIOError(
                    stage: .read,
                    posixErrno: 0,
                    detail: "short read: EOF at byte \(offset + Int64(filled)) of a \(fileSize) byte file",
                    domain: nil,
                    code: nil
                )
            }
            filled += count
        }
        if filled < bufferCapacity {
            memset(buffer + filled, 0, bufferCapacity - filled)
        }
    }

    /// Writes exactly `count` bytes at `offset` through pwrite(2), retrying
    /// EINTR. Staged-write failures (a full disk) stay raw NSError with the
    /// real POSIX domain/code: they are local, non-transient conditions that
    /// must never trigger the stop-capture retry. A short write is impossible
    /// to represent in a sparse delta, so it fails instead of padding.
    private static func writeAll(
        _ descriptor: Int32,
        buffer: UnsafeRawPointer,
        count: Int,
        at offset: Int64
    ) throws {
        var written = 0
        while written < count {
            let n = pwrite(
                descriptor, buffer.advanced(by: written), count - written,
                offset + Int64(written)
            )
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if n == 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "short write at byte \(offset + Int64(written))"]
                )
            }
            written += n
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func posixDetail(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "errno \(code)" }
        return String(cString: message)
    }
    #endif

    /// Allocated extents of a sparse file as block-aligned byte ranges. Uses
    /// SEEK_DATA/SEEK_HOLE where the volume supports it; otherwise treats the
    /// whole file as one extent (correct, just slower).
    private func dataExtents(of url: URL, fileSize: Int64) throws -> [Range<Int64>] {
        guard fileSize > 0 else { return [] }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            return [0..<fileSize]
        }
        defer { close(descriptor) }
        var extents: [Range<Int64>] = []
        var cursor: off_t = 0
        while cursor < fileSize {
            let data = lseek(descriptor, cursor, SEEK_DATA)
            if data < 0 {
                if errno == ENXIO { break } // no further data; the tail is a hole
                return [0..<fileSize] // unsupported: fall back to a full scan
            }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            let end = hole < 0 ? fileSize : min(Int64(hole), fileSize)
            extents.append(Int64(data)..<end)
            cursor = off_t(end)
        }
        return extents.isEmpty ? [] : extents
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
