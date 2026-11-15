/* SPDX-License-Identifier: Apache-2.0 */
/* Fixed little-endian Linux arm64 UAPI layouts. Never cast host libc's
 * timeval, pointer, errno or ioctl structures onto guest memory. Protocol:
 * chromeos/virtio-media ed3a56fd39a74bd8117a3cc9c5b8ec8803df19cd;
 * Linux videodev2.h v6.12. Byte offsets are qualified against the real guest
 * headers by the guest package's ABI tool. No arbitrary native ioctl calls. */
#ifndef FLOE_VIRTIO_MEDIA_WIRE_H
#define FLOE_VIRTIO_MEDIA_WIRE_H
#include <stdint.h>
#include <stddef.h>
enum { VMED_Q_COMMAND=0, VMED_Q_EVENT=1, VMED_Q_MAX=256,
       VMED_OPEN=1, VMED_CLOSE=2, VMED_IOCTL=3, VMED_MMAP=4, VMED_MUNMAP=5,
       VMED_EVT_ERROR=0, VMED_EVT_DQBUF=1, VMED_EVT_EVENT=2,
       VMED_CAPTURE=1, VMED_OUTPUT=2, VMED_MEMORY_MMAP=1,
       VMED_EVENT_EOS=2, VMED_EVENT_SOURCE_CHANGE=5,
       VMED_BUFFER_BYTES=88, VMED_EVENT_BYTES=608, VMED_V4L2_EVENT_BYTES=136,
       VMED_FORMAT_BYTES=208, VMED_FMTDESC_BYTES=64,
       VMED_REQBUFS_BYTES=20, VMED_EXTCTRLS_BYTES=32,
       VMED_MAX_SESSIONS=4, VMED_MAX_BUFFERS=32, VMED_MAX_EVENTS=256,
       VMED_MAX_COMMAND=8192 };
/* Protocol response statuses are positive Linux errno values. */
enum { VMED_EIO=5, VMED_EAGAIN=11, VMED_ENOMEM=12, VMED_EACCES=13, VMED_EBUSY=16,
       VMED_EINVAL=22, VMED_ENOTTY=25, VMED_ENOSPC=28, VMED_EPIPE=32,
       VMED_ENOTSUP=95 };
#define VMED_CAPS UINT32_C(0x04008000) /* STREAMING | VIDEO_M2M single planar */
#define VMED_FOURCC(a,b,c,d) ((uint32_t)(a)|((uint32_t)(b)<<8)|((uint32_t)(c)<<16)|((uint32_t)(d)<<24))
static inline uint32_t vmed_r32(const uint8_t *p) {
    return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static inline uint64_t vmed_r64(const uint8_t *p) {
    return (uint64_t)vmed_r32(p)|((uint64_t)vmed_r32(p+4)<<32);
}
static inline void vmed_w32(uint8_t *p,uint32_t x) {
    for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(x>>(8*i));
}
static inline void vmed_w64(uint8_t *p,uint64_t x) {
    vmed_w32(p,(uint32_t)x);vmed_w32(p+4,(uint32_t)(x>>32));
}
#endif
