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
        let dataHandle = try FileHandle(forWritingTo: stagedData)
        var fileHeader = Data(Self.dataMagic)
        withUnsafeBytes(of: generation.littleEndian) { fileHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockSize).littleEndian) { fileHeader.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(blockCount).littleEndian) { fileHeader.append(contentsOf: $0) }
        try dataHandle.write(contentsOf: fileHeader)

        let baseHandle = try FileHandle(forReadingFrom: baseRootfs)
        defer { try? baseHandle.close() }
        let workingHandle = try FileHandle(forReadingFrom: workingDisk)
        defer { try? workingHandle.close() }

        var bitmap = [UInt8](repeating: 0, count: (blockCount + 7) / 8)
        var payloadBytes: Int64 = 0
        let zeroBlock = Data(count: Int(blockSize))
        do {
            for extent in try dataExtents(of: workingDisk, fileSize: workingSize) {
                var offset = extent.lowerBound - (extent.lowerBound % blockSize)
                while offset < extent.upperBound {
                    try Task.checkCancellation()
                    let index = Int(offset / blockSize)
                    let workingBlock = try readBlock(
                        from: workingHandle, at: offset, size: blockSize, fileSize: workingSize
                    )
                    let baseBlock: Data
                    if offset < baseSize {
                        baseBlock = try readBlock(from: baseHandle, at: offset, size: blockSize, fileSize: baseSize)
                    } else {
                        baseBlock = zeroBlock
                    }
                    if workingBlock != baseBlock {
                        bitmap[index / 8] |= UInt8(1 << (index % 8))
                        try dataHandle.write(contentsOf: workingBlock)
                        payloadBytes += blockSize
                    }
                    offset += blockSize
                }
            }
        } catch {
            try? dataHandle.close()
            throw error
        }
        try dataHandle.synchronize()
        try dataHandle.close()

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

    private func readBlock(
        from handle: FileHandle, at offset: Int64, size: Int64, fileSize: Int64
    ) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let wanted = Int(min(size, fileSize - offset))
        var block = try handle.read(upToCount: wanted) ?? Data()
        if block.count < Int(size) {
            block.append(Data(count: Int(size) - block.count))
        }
        return block
    }

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
