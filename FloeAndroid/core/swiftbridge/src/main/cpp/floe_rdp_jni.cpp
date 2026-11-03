// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP trusted frame JNI wrapper. This is an ADDITIVE translation unit in
// the same floe_jni target; every prior wrapper remains byte-identical.
//
// The Kotlin object is com.floe.android.host.rdp.C05RDPVideoNative. Pixel
// bytes are copied page-by-page into a caller-owned ByteArray; no raw native
// pointer is retained by Kotlin and no framebuffer crosses JSON/base64.

#include <jni.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

extern "C" int32_t floe_rdp_frame_acquire(
    uint64_t epoch,
    const char *ownerToken,
    const char *sessionID,
    char *buffer,
    int32_t capacity);

extern "C" int32_t floe_rdp_frame_read(
    uint64_t epoch,
    const char *leaseID,
    int64_t offset,
    uint8_t *target,
    int32_t capacity);

extern "C" int32_t floe_rdp_frame_release(
    uint64_t epoch,
    const char *leaseID);

namespace {
constexpr jsize kMetadataBytes = 8192;
constexpr jsize kMaximumPageBytes = 65536;

class ScopedUtf8 {
public:
    ScopedUtf8(JNIEnv *env, jstring value) : env_(env), value_(value) {
        if (value_ != nullptr) {
            chars_ = env_->GetStringUTFChars(value_, nullptr);
        }
    }
    ~ScopedUtf8() {
        if (chars_ != nullptr && value_ != nullptr) {
            env_->ReleaseStringUTFChars(value_, chars_);
        }
    }
    ScopedUtf8(const ScopedUtf8 &) = delete;
    ScopedUtf8 &operator=(const ScopedUtf8 &) = delete;

    const char *get() const { return chars_; }

private:
    JNIEnv *env_;
    jstring value_;
    const char *chars_ = nullptr;
};

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, jsize size) {
    if (size <= 0) return nullptr;
    jbyteArray result = env->NewByteArray(size);
    if (result == nullptr) return nullptr;
    env->SetByteArrayRegion(result, 0, size,
                            reinterpret_cast<const jbyte *>(data));
    if (env->ExceptionCheck()) {
        env->DeleteLocalRef(result);
        return nullptr;
    }
    return result;
}
}  // namespace

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_rdp_C05RDPVideoNative_nativeAcquire(
    JNIEnv *env, jobject, jlong epoch, jstring ownerToken, jstring sessionID) {
    if (epoch <= 0 || ownerToken == nullptr || sessionID == nullptr) {
        return nullptr;
    }
    ScopedUtf8 owner(env, ownerToken);
    ScopedUtf8 session(env, sessionID);
    if (owner.get() == nullptr || session.get() == nullptr) {
        return nullptr;
    }
    if (std::strlen(owner.get()) == 0 ||
        std::strlen(owner.get()) > 128 ||
        std::strlen(session.get()) != 36) {
        return nullptr;
    }
    std::vector<uint8_t> metadata(static_cast<size_t>(kMetadataBytes), 0);
    const auto written = floe_rdp_frame_acquire(
        static_cast<uint64_t>(epoch), owner.get(), session.get(),
        reinterpret_cast<char *>(metadata.data()),
        static_cast<int32_t>(metadata.size()));
    if (written <= 0) return nullptr;
    return to_bytes(env, metadata.data(), written);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_rdp_C05RDPVideoNative_nativeRead(
    JNIEnv *env, jobject, jlong epoch, jstring leaseID, jlong offset,
    jbyteArray target, jint targetOffset, jint length) {
    if (epoch <= 0 || leaseID == nullptr || target == nullptr ||
        targetOffset < 0 || length <= 0 || length > kMaximumPageBytes) {
        return -105;
    }
    const jsize targetLength = env->GetArrayLength(target);
    if (targetLength <= 0 ||
        static_cast<int64_t>(targetOffset) + static_cast<int64_t>(length) >
            static_cast<int64_t>(targetLength)) {
        return -106;
    }
    ScopedUtf8 lease(env, leaseID);
    if (lease.get() == nullptr || std::strlen(lease.get()) != 36) {
        return -105;
    }
    std::vector<uint8_t> page(static_cast<size_t>(length), 0);
    const auto copied = floe_rdp_frame_read(
        static_cast<uint64_t>(epoch), lease.get(),
        static_cast<int64_t>(offset), page.data(),
        static_cast<int32_t>(page.size()));
    if (copied <= 0) return copied;
    env->SetByteArrayRegion(target, targetOffset, copied,
                            reinterpret_cast<const jbyte *>(page.data()));
    if (env->ExceptionCheck()) return -108;
    return copied;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_rdp_C05RDPVideoNative_nativeRelease(
    JNIEnv *env, jobject, jlong epoch, jstring leaseID) {
    if (epoch <= 0 || leaseID == nullptr) return -105;
    ScopedUtf8 lease(env, leaseID);
    if (lease.get() == nullptr || std::strlen(lease.get()) != 36) {
        return -105;
    }
    return floe_rdp_frame_release(static_cast<uint64_t>(epoch), lease.get());
}
