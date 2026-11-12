// Public Darwin API only; all lifecycle/identity policy stays in Swift.
#include "CFloeSparseRewriteShim.h"
#include <errno.h>
#include <sys/fcntl.h>
#include <sys/attr.h>
#include <time.h>
#include <unistd.h>
#if __has_include(<sys/acl.h>)
#include <sys/acl.h>
#define FLOE_HAS_ACL 1
#else
#define FLOE_HAS_ACL 0
#endif

int floe_sparse_punch_hole(int fd, off_t offset, off_t length) {
#if defined(F_PUNCHHOLE)
    fpunchhole_t hole = {0};
    hole.fp_offset = offset;
    hole.fp_length = length;
    return fcntl(fd, F_PUNCHHOLE, &hole);
#else
    (void)fd; (void)offset; (void)length;
    errno = ENOTSUP;
    return -1;
#endif
}

int floe_sparse_acl_snapshot(int fd, void *buffer, size_t capacity, size_t *used) {
    if (buffer == NULL || used == NULL || capacity == 0) {
        errno = EINVAL;
        return -1;
    }
    *used = 0;
#if FLOE_HAS_ACL
    errno = 0;
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        // On an admitted, open regular fd these mean no extended ACL.
        // Never convert ENOTSUP/EINVAL/permission failures into "no ACL".
        if (errno == ENOENT || errno == ENOATTR) return 0;
        if (errno == 0) errno = EIO;
        return -1;
    }
    ssize_t required = acl_size(acl);
    if (required < 0 || (size_t)required > capacity) {
        int code = required < 0 ? errno : EOVERFLOW;
        acl_free(acl);
        errno = code == 0 ? EIO : code;
        return -1;
    }
    ssize_t copied = acl_copy_ext(buffer, acl, required);
    int code = errno;
    acl_free(acl);
    if (copied < 0 || copied != required) {
        errno = copied < 0 && code != 0 ? code : EIO;
        return -1;
    }
    *used = (size_t)copied;
    return 0;
#else
    (void)fd;
    errno = ENOTSUP;
    return -1;
#endif
}

int floe_sparse_set_birthtime(int stage_fd, int64_t seconds, int64_t nanoseconds) {
    if (nanoseconds < 0 || nanoseconds >= 1000000000) {
        errno = EINVAL;
        return -1;
    }
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_CRTIME;
    struct timespec created = {(time_t)seconds, (long)nanoseconds};
    return fsetattrlist(stage_fd, &attrs, &created, sizeof(created), 0);
}
