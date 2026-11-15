// ABI offset/size probe for virtio-media protocol + V4L2 UAPI on ARM64 LP64.
// Prints JSON lines: {"name":..., "size":N, "offsets":{...}}. Host-side
// analysis only; not part of the guest module.
#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#ifndef __user
#define __user
#endif
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
#include <linux/media.h>
#include <linux/videodev2.h>
#include "protocol.h"

#define ENTRY(s, f) printf("{\"name\":\"%s.%s\",\"offset\":%zu,\"size\":%zu}\n", #s, #f, offsetof(s, f), sizeof(((s *)0)->f))
#define SZ(s) printf("{\"name\":\"sizeof(%s)\",\"size\":%zu}\n", #s, sizeof(s))
#define IOCTL(code) printf("{\"name\":\"%s\",\"value\":%lu,\"payload_size\":%zu,\"dir\":%d,\"nr\":%d}\n", #code, (unsigned long)code, _IOC_SIZE(code), _IOC_DIR(code), _IOC_NR(code))

int main(void)
{
    SZ(struct virtio_media_cmd_header);
    SZ(struct virtio_media_resp_header);
    SZ(struct virtio_media_cmd_open);
    SZ(struct virtio_media_resp_open);
    SZ(struct virtio_media_cmd_close);
    SZ(struct virtio_media_cmd_ioctl);
    SZ(struct virtio_media_resp_ioctl);
    SZ(struct virtio_media_cmd_mmap);
    SZ(struct virtio_media_resp_mmap);
    SZ(struct virtio_media_cmd_munmap);
    SZ(struct virtio_media_resp_munmap);
    SZ(struct virtio_media_sg_entry);
    SZ(struct virtio_media_event_header);
    SZ(struct virtio_media_event_error);
    SZ(struct virtio_media_event_dqbuf);
    SZ(struct virtio_media_event_event);
    ENTRY(struct virtio_media_cmd_ioctl, hdr);
    ENTRY(struct virtio_media_cmd_ioctl, session_id);
    ENTRY(struct virtio_media_cmd_ioctl, code);
    ENTRY(struct virtio_media_cmd_mmap, hdr);
    ENTRY(struct virtio_media_cmd_mmap, session_id);
    ENTRY(struct virtio_media_cmd_mmap, flags);
    ENTRY(struct virtio_media_cmd_mmap, offset);
    ENTRY(struct virtio_media_resp_mmap, hdr);
    ENTRY(struct virtio_media_resp_mmap, driver_addr);
    ENTRY(struct virtio_media_resp_mmap, len);
    ENTRY(struct virtio_media_event_dqbuf, hdr);
    ENTRY(struct virtio_media_event_dqbuf, buffer);
    ENTRY(struct virtio_media_event_dqbuf, planes);
    ENTRY(struct virtio_media_event_event, hdr);
    ENTRY(struct virtio_media_event_event, event);
    ENTRY(struct virtio_media_cmd_munmap, hdr);
    ENTRY(struct virtio_media_cmd_munmap, driver_addr);
    ENTRY(struct virtio_media_cmd_close, session_id);
    ENTRY(struct virtio_media_resp_open, session_id);
    SZ(struct v4l2_ext_controls);
    SZ(struct v4l2_capability);
    ENTRY(struct v4l2_capability, driver);
    ENTRY(struct v4l2_capability, card);
    ENTRY(struct v4l2_capability, bus_info);
    ENTRY(struct v4l2_capability, version);
    ENTRY(struct v4l2_capability, capabilities);
    ENTRY(struct v4l2_capability, device_caps);
    SZ(struct v4l2_format);
    SZ(struct v4l2_fmtdesc);
    SZ(struct v4l2_frmsizeenum);
    SZ(struct v4l2_frmivalenum);
    SZ(struct v4l2_requestbuffers);
    ENTRY(struct v4l2_requestbuffers, count);
    ENTRY(struct v4l2_requestbuffers, type);
    ENTRY(struct v4l2_requestbuffers, memory);
    SZ(struct v4l2_plane);
    ENTRY(struct v4l2_plane, bytesused);
    ENTRY(struct v4l2_plane, length);
    ENTRY(struct v4l2_plane, m);
    ENTRY(struct v4l2_plane, data_offset);
    SZ(struct v4l2_buffer);
    ENTRY(struct v4l2_buffer, index);
    ENTRY(struct v4l2_buffer, type);
    ENTRY(struct v4l2_buffer, bytesused);
    ENTRY(struct v4l2_buffer, flags);
    ENTRY(struct v4l2_buffer, field);
    ENTRY(struct v4l2_buffer, timestamp);
    ENTRY(struct v4l2_buffer, timecode);
    ENTRY(struct v4l2_buffer, sequence);
    ENTRY(struct v4l2_buffer, memory);
    ENTRY(struct v4l2_buffer, m);
    ENTRY(struct v4l2_buffer, length);
    ENTRY(struct v4l2_buffer, reserved2);
    ENTRY(struct v4l2_buffer, request_fd);
    SZ(struct v4l2_create_buffers);
    SZ(struct v4l2_event);
    SZ(struct v4l2_event_subscription);
    SZ(struct v4l2_queryctrl);
    SZ(struct v4l2_control);
    SZ(struct v4l2_streamparm);
    SZ(struct v4l2_selection);
    SZ(struct v4l2_crop);
    SZ(struct v4l2_standard);
    SZ(struct v4l2_input);
    SZ(struct v4l2_output);
    SZ(struct v4l2_decoder_cmd);
    SZ(struct v4l2_encoder_cmd);
    IOCTL(VIDIOC_QUERYCAP);
    IOCTL(VIDIOC_ENUM_FMT);
    IOCTL(VIDIOC_G_FMT);
    IOCTL(VIDIOC_S_FMT);
    IOCTL(VIDIOC_TRY_FMT);
    IOCTL(VIDIOC_REQBUFS);
    IOCTL(VIDIOC_QUERYBUF);
    IOCTL(VIDIOC_QBUF);
    IOCTL(VIDIOC_DQBUF);
    IOCTL(VIDIOC_STREAMON);
    IOCTL(VIDIOC_STREAMOFF);
    IOCTL(VIDIOC_CREATE_BUFS);
    IOCTL(VIDIOC_PREPARE_BUF);
    IOCTL(VIDIOC_SUBSCRIBE_EVENT);
    IOCTL(VIDIOC_UNSUBSCRIBE_EVENT);
    IOCTL(VIDIOC_DQEVENT);
    IOCTL(VIDIOC_G_CTRL);
    IOCTL(VIDIOC_S_CTRL);
    IOCTL(VIDIOC_QUERYCTRL);
    IOCTL(VIDIOC_G_PARM);
    IOCTL(VIDIOC_S_PARM);
    IOCTL(VIDIOC_G_SELECTION);
    IOCTL(VIDIOC_S_SELECTION);
    IOCTL(VIDIOC_DECODER_CMD);
    IOCTL(VIDIOC_TRY_DECODER_CMD);
    IOCTL(VIDIOC_ENCODER_CMD);
    IOCTL(VIDIOC_G_CROP);
    IOCTL(VIDIOC_S_CROP);
    IOCTL(VIDIOC_ENUM_FRAMESIZES);
    IOCTL(VIDIOC_ENUM_FRAMEINTERVALS);
    IOCTL(VIDIOC_ENUMINPUT);
    IOCTL(VIDIOC_ENUMOUTPUT);
    IOCTL(VIDIOC_G_STD);
    IOCTL(VIDIOC_S_STD);
    IOCTL(VIDIOC_G_INPUT);
    IOCTL(VIDIOC_S_INPUT);
    IOCTL(VIDIOC_G_OUTPUT);
    IOCTL(VIDIOC_S_OUTPUT);
    printf("{\"name\":\"VIDEO_MAX_PLANES\",\"value\":%d}\n", VIDEO_MAX_PLANES);
    /* In kernel 6.12 the _M2M buf-type aliases were removed from the UAPI;
     * stateful M2M uses plain VIDEO_OUTPUT(2)/VIDEO_CAPTURE(1). */
    printf("{\"name\":\"V4L2_BUF_TYPE_VIDEO_CAPTURE_M2M_REMOVED\",\"note\":\"use V4L2_BUF_TYPE_VIDEO_CAPTURE\",\"value\":%d}\n", V4L2_BUF_TYPE_VIDEO_CAPTURE);
    printf("{\"name\":\"V4L2_BUF_TYPE_VIDEO_OUTPUT_M2M_REMOVED\",\"note\":\"use V4L2_BUF_TYPE_VIDEO_OUTPUT\",\"value\":%d}\n", V4L2_BUF_TYPE_VIDEO_OUTPUT);
    printf("{\"name\":\"V4L2_MEMORY_MMAP\",\"value\":%d}\n", V4L2_MEMORY_MMAP);
    return 0;
}
