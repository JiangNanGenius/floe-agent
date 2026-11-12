// Public Darwin primitives for the clone-only sparse rewrite.
// No paths, source-data writes, ACL writes, retries, or ownership decisions.
#ifndef CFLOE_SPARSE_REWRITE_SHIM_H
#define CFLOE_SPARSE_REWRITE_SHIM_H
#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

int floe_sparse_punch_hole(int fd, off_t offset, off_t length);

// Capture the complete external ACL representation into a bounded caller buffer.
// An absent ACL is a known empty snapshot. Unsupported/unreadable is an error.
// Returns 0 on success with *used set; -1 with errno on failure. Never sets ACLs.
int floe_sparse_acl_snapshot(int fd, void *buffer, size_t capacity, size_t *used);

// Set the birthtime of the already-proven, job-owned stage using public
// fsetattrlist(ATTR_CMN_CRTIME). Swift must read back and verify the result.
int floe_sparse_set_birthtime(int stage_fd, int64_t seconds, int64_t nanoseconds);

#ifdef __cplusplus
}
#endif
#endif
