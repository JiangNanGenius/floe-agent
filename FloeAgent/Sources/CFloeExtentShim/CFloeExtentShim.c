// CFloeExtentShim — bounded wrapper over the public fcntl(F_LOG2PHYS_EXT)
// primitive. See the header for the contract. Buildable on every platform:
// non-Apple targets compile the ENOTSUP fallback so FloeCore stays
// cross-platform.

#include "CFloeExtentShim.h"

#include <errno.h>
#include <string.h>

#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/fcntl.h>
#endif

int32_t floe_log2phys_ext(
    int32_t fd,
    int64_t file_offset,
    int64_t want,
    int64_t *devoffset,
    int64_t *contigbytes
) {
#if defined(__APPLE__) && defined(F_LOG2PHYS_EXT)
    struct log2phys l2p;
    memset(&l2p, 0, sizeof(l2p));
    l2p.l2p_flags = 0;
    l2p.l2p_contigbytes = (off_t)want;
    l2p.l2p_devoffset = (off_t)file_offset;
    if (fcntl(fd, F_LOG2PHYS_EXT, &l2p) != 0) {
        return -1;
    }
    if (devoffset != NULL) {
        *devoffset = (int64_t)l2p.l2p_devoffset;
    }
    if (contigbytes != NULL) {
        *contigbytes = (int64_t)l2p.l2p_contigbytes;
    }
    return 0;
#else
    (void)fd;
    (void)file_offset;
    (void)want;
    (void)devoffset;
    (void)contigbytes;
    errno = ENOTSUP;
    return -1;
#endif
}
