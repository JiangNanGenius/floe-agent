#ifndef CFLOE_EXTENT_SHIM_H
#define CFLOE_EXTENT_SHIM_H

#include <stdint.h>

/// One bounded call to the public `fcntl(fd, F_LOG2PHYS_EXT)` primitive.
///
/// Swift cannot call the variadic C `fcntl`, so this shim is the only place
/// the packed `struct log2phys` input/output is assembled; everything else
/// stays in Swift. Public SDK only (`sys/fcntl.h`): no private API, no
/// entitlement, no root.
///
/// - Parameters:
///   - fd: an open regular-file descriptor.
///   - file_offset: byte offset into the file (>= 0).
///   - want: requested length; the kernel returns at most the run at the
///     offset, clipped to this bound. Never clipped to EOF by the caller so
///     the block-rounded tail of an unaligned file is included.
///   - devoffset: OUT device byte offset, or -1 for an unbacked range.
///   - contigbytes: OUT length of the contiguous range at the offset.
/// - Returns: 0 on success; -1 with `errno` set on failure (ENOTSUP/EINVAL/
///   ENOSYS when the volume/kernel does not implement the primitive).
int32_t floe_log2phys_ext(
    int32_t fd,
    int64_t file_offset,
    int64_t want,
    int64_t *devoffset,
    int64_t *contigbytes
);

#endif /* CFLOE_EXTENT_SHIM_H */
