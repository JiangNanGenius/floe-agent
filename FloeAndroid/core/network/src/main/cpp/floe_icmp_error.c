// SPDX-License-Identifier: MPL-2.0
// Linux ping sockets deliver ICMP router errors via IP_RECVERR/MSG_ERRQUEUE,
// not their ordinary echo receive queue. No socket creation or ownership here.
#include <jni.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <linux/errqueue.h>

static void put32(uint8_t *out, uint32_t value) {
    out[0] = value >> 24; out[1] = value >> 16;
    out[2] = value >> 8; out[3] = value;
}

JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_core_network_IcmpErrorQueueNative_receive(
        JNIEnv *env, jobject self, jint fd) {
    (void)self;
    uint8_t payload[2048];
    // cmsghdr requires aligned storage; no packed or guessed ABI offsets.
    union { struct cmsghdr align; uint8_t bytes[512]; } control;
    struct sockaddr_in destination;
    struct iovec iov = { .iov_base = payload, .iov_len = sizeof(payload) };
    struct msghdr msg;
    memset(&destination, 0, sizeof(destination));
    memset(&msg, 0, sizeof(msg));
    memset(&control, 0, sizeof(control));
    msg.msg_name = &destination; msg.msg_namelen = sizeof(destination);
    msg.msg_iov = &iov; msg.msg_iovlen = 1;
    msg.msg_control = control.bytes; msg.msg_controllen = sizeof(control.bytes);
    ssize_t count = recvmsg(fd, &msg, MSG_ERRQUEUE | MSG_DONTWAIT);
    uint8_t result[20] = {1, 1};
    if (count < 0) {
        int error = errno;
        if (error == EAGAIN || error == EWOULDBLOCK) {
            int pending = 0; socklen_t size = sizeof(pending);
            // Clear a residual asynchronous soft errno after the queue empties.
            // No ownership/close is transferred to this finite call.
            (void)getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &size);
            return NULL;
        }
        if (error == EINTR) return NULL;
        result[1] = 2; put32(result + 4, (uint32_t)error);
    } else {
        // The iovec begins at the original ICMP header, WITHOUT IPv4/outer
        // error headers. An eight-byte quote suffices; tokens may be absent.
        if (count < 8 || (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0 ||
                msg.msg_namelen < sizeof(destination) || destination.sin_family != AF_INET ||
                payload[0] != 8 || payload[1] != 0) return NULL;
        struct sock_extended_err *error = NULL;
        struct sockaddr_in offender;
        memset(&offender, 0, sizeof(offender));
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level != IPPROTO_IP || c->cmsg_type != IP_RECVERR ||
                    c->cmsg_len < CMSG_LEN(sizeof(struct sock_extended_err) + sizeof(offender))) continue;
            error = (struct sock_extended_err *)CMSG_DATA(c);
            memcpy(&offender, SO_EE_OFFENDER(error), sizeof(offender));
            break;
        }
        if (!error || error->ee_origin != SO_EE_ORIGIN_ICMP ||
                (error->ee_type != 11 && error->ee_type != 3) ||
                offender.sin_family != AF_INET) return NULL;
        result[2] = error->ee_type; result[3] = error->ee_code;
        memcpy(result + 8, &offender.sin_addr, 4);
        memcpy(result + 12, &destination.sin_addr, 4);
        memcpy(result + 16, payload + 4, 4); // actual kernel identifier + sequence
    }
    jbyteArray bytes = (*env)->NewByteArray(env, sizeof(result));
    if (bytes) (*env)->SetByteArrayRegion(env, bytes, 0, sizeof(result), (const jbyte *)result);
    return bytes;
}
