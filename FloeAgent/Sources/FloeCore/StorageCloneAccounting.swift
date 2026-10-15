// FloeCore — APFS clone/private-size attribution via public SDK getattrlist.
//
// `getattrlist(2)` with `FSOPT_ATTR_CMN_EXTENDED` exposes, for files on APFS:
//
//   * ATTR_CMNEXT_PRIVATESIZE  — bytes NOT trapped inside a clone or snapshot
//     that would be freed immediately if this file were deleted. This is a
//     measured *exclusive* quantity: summing it over identity-deduplicated
//     files is a lower bound of their physical footprint (blocks shared with
//     clones or snapshots are excluded), and it is never used as the total.
//   * ATTR_CMNEXT_CLONEID      — identifies the data stream; files sharing a
//     clone-id are pure clones of each other.
//   * ATTR_CMNEXT_EXT_FLAGS    — EF_MAY_SHARE_BLOCKS / EF_SHARES_ALL_BLOCKS
//     (sys/stat.h): actual sharing state, usable outside any known-root list.
//   * ATTR_CMNEXT_CLONE_REFCNT — number of full clones sharing all blocks.
//
// All declarations come from the public SDK (sys/attr.h, sys/stat.h). No
// private API and no entitlement is used; the query is a plain read of file
// metadata we own.
//
// Semantics that matter for accounting (verified with K/experiments):
//   * A pure clone family (same clone-id, EF_SHARES_ALL_BLOCKS on every
//     member) is one physical stream: counting it once is exact, not a
//     heuristic. First-writer wins attribution; later members contribute zero
//     allocated bytes and are reported as deduplicated clones.
//   * After a copy-on-write split the member gets a new clone-id and
//     EF_SHARES_ALL_BLOCKS clears; its allocated size still describes the full
//     stream including blocks shared with the untouched sibling, so it remains
//     an upper bound and its private size is the measured exclusive delta.
//     The union of a partial-COW family is NOT derived from clone-ids.
//   * Hard links are already deduplicated by inode; their private size is
//     counted once with the inode.
//   * Snapshot-trapped blocks are excluded from private size, which keeps the
//     lower bound valid in the presence of snapshots.
//
// The reader reports `.unsupported` when the volume/kernel rejects the query
// (for example ENOTSUP/EINVAL), so callers can fall back to root-based clone
// flags without inventing numbers.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Measured per-file APFS sharing attributes.
public struct StorageCloneAttributes: Sendable, Equatable {
    /// Bytes freed immediately if this file were deleted; never trapped inside
    /// a clone or snapshot. Measured, may be smaller than the allocated size.
    public let privateBytes: Int64
    /// Data-stream identifier; pure clones share it.
    public let cloneID: UInt64
    /// Raw EF_* flags from sys/stat.h.
    public let extendedFlags: UInt64
    /// Number of full clones that share all blocks with this file.
    public let cloneRefCount: UInt32

    public init(privateBytes: Int64, cloneID: UInt64, extendedFlags: UInt64, cloneRefCount: UInt32) {
        self.privateBytes = max(0, privateBytes)
        self.cloneID = cloneID
        self.extendedFlags = extendedFlags
        self.cloneRefCount = cloneRefCount
    }

    public var mayShareBlocks: Bool {
        extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
    }

    public var sharesAllBlocks: Bool {
        extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
    }

    public var isSparse: Bool {
        extendedFlags & UInt64(EF_IS_SPARSE) != 0
    }

    /// True when this file belongs to a clonable data stream we can group.
    public var participatesInCloneFamily: Bool {
        cloneID != 0 && mayShareBlocks
    }
}

/// Result of one clone-attribute query.
public enum StorageCloneAttributeResult: Sendable, Equatable {
    case attributes(StorageCloneAttributes)
    /// The volume or kernel does not support the extended query; callers must
    /// fall back (never guess values).
    case unsupported
    /// A transient per-file failure (raced deletion, permissions). Does not
    /// disable the query, but makes an aggregate lower bound incomplete.
    case unavailable
}

/// Whether measured clone/private attributes could be collected in a scan.
public enum StorageCloneAttributeSupport: String, Sendable, Codable {
    /// The caller did not request clone attributes (legacy callers/tests).
    case notRequested
    /// The query succeeded for every measured file.
    case supported
    /// The volume/kernel rejected the query; root-based flags were used.
    case unavailable
}

/// Public-SDK reader for the extended attributes above.
public enum StorageCloneAttributesReader {
    /// Attribute buffer layout on APFS (public headers, measured):
    /// `u_int32 totalLength`, `attribute_set_t` (20 bytes), then attribute
    /// values in canonical bit order at their natural 4-byte alignment:
    /// privateSize (off_t), cloneID (u64), extFlags (u64), refCount (u32).
    /// All four fork bits must be returned; otherwise the packing cannot be
    /// interpreted and the query is reported unsupported.
    public static func read(path: String) -> StorageCloneAttributeResult {
        #if canImport(Darwin)
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attrList.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE)
            | UInt32(ATTR_CMNEXT_CLONEID)
            | UInt32(ATTR_CMNEXT_EXT_FLAGS)
            | UInt32(ATTR_CMNEXT_CLONE_REFCNT)

        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(
                path, &attrList, raw.baseAddress, raw.count,
                UInt32(FSOPT_ATTR_CMN_EXTENDED)
            )
        }
        guard status == 0 else {
            switch errno {
            case ENOTSUP, EINVAL, ENOSYS:
                // The volume/kernel does not implement the extended query.
                return .unsupported
            case EACCES, EPERM:
                // Sandbox/policy denial: the feature is unusable here, so the
                // scan falls back once instead of paying a syscall per file.
                return .unsupported
            default:
                // Transient per-file failure (e.g. raced deletion).
                return .unavailable
            }
        }

        let returnedFork = readUInt32(buffer, at: 20)
        let required = UInt32(
            ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID
                | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT
        )
        guard returnedFork & required == required else { return .unsupported }

        let attributes = StorageCloneAttributes(
            privateBytes: Int64(bitPattern: readUInt64(buffer, at: 24)),
            cloneID: readUInt64(buffer, at: 32),
            extendedFlags: readUInt64(buffer, at: 40),
            cloneRefCount: readUInt32(buffer, at: 48)
        )
        return .attributes(attributes)
        #else
        return .unsupported
        #endif
    }

    static func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= buffer.count else { return 0 }
        return UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    static func readUInt64(_ buffer: [UInt8], at offset: Int) -> UInt64 {
        guard offset + 8 <= buffer.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(buffer[offset + index])
        }
        return value
    }
}
