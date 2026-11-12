import Foundation
#if canImport(Darwin)
import Darwin
#endif

public extension StorageCloneAttributesReader {
    /// Reads the existing public APFS attributes from the already-open inode.
    /// No seek, file-content read, path reopening or mutation occurs here.
    /// The caller owns the descriptor and must compare fstat before/after.
    static func read(descriptor: Int32) -> StorageCloneAttributeResult {
        #if canImport(Darwin)
        guard descriptor >= 0 else { return .unavailable }
        var requested = attrlist()
        requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        requested.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        requested.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE)
            | UInt32(ATTR_CMNEXT_CLONEID)
            | UInt32(ATTR_CMNEXT_EXT_FLAGS)
            | UInt32(ATTR_CMNEXT_CLONE_REFCNT)
        var bytes = [UInt8](repeating: 0, count: 64)
        let result = bytes.withUnsafeMutableBytes { buffer in
            fgetattrlist(descriptor, &requested, buffer.baseAddress, buffer.count,
                         UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard result == 0 else {
            switch errno {
            case ENOTSUP, EINVAL, ENOSYS, EACCES, EPERM: return .unsupported
            default: return .unavailable
            }
        }
        let required = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID
            | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT)
        guard readUInt32(bytes, at: 20) & required == required else { return .unsupported }
        return .attributes(StorageCloneAttributes(
            privateBytes: Int64(bitPattern: readUInt64(bytes, at: 24)),
            cloneID: readUInt64(bytes, at: 32), extendedFlags: readUInt64(bytes, at: 40),
            cloneRefCount: readUInt32(bytes, at: 48)))
        #else
        return .unsupported
        #endif
    }
}
