// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media foundation trusted-host JNI adapters
// (job-aa95dd9b26044ded). Additive translation unit inside the SAME floe_jni
// target; every prior wrapper file stays byte-identical.
//
// This is NOT a V3 command and NOT a model tool. It exposes only the plain
// host-authority proof / aggregate root-drain lane the App adapter needs for
// the platform12 factory:
//   status / verify(renderBinding|probeRoot|ticket) / rootStop / drainPending
//
// All decisions (bound epoch/root, lease record+file, owner/revision/digest,
// claimed ticket identity and the real drain accounting) live in
// FloeAndroidCore/G09R2. This file only marshals bounded UTF-8/JSON values:
//   * action tokens are short printable ASCII;
//   * request bodies are <= 16 KiB, replies <= 64 KiB;
//   * a too-small reply buffer is refused, never truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
int32_t floe_media_foundation_status(uint64_t, char *, int32_t);
int32_t floe_media_authority_verify(uint64_t, const char *, const char *,
                                    char *, int32_t);
int32_t floe_media_foundation_root_stop(uint64_t);
int32_t floe_media_foundation_drain_pending(uint64_t);
int32_t floe_media_render_prepare(uint64_t, const char *, char *, int32_t);
}

namespace {
constexpr int32_t status_limit = 4096;
constexpr int32_t decision_limit = 64 * 1024;
constexpr int32_t request_limit = 16 * 1024;
constexpr jsize token_limit = 32;

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte *>(data));
    }
    return env->ExceptionCheck() ? nullptr : result;
}

bool copy_ascii(JNIEnv *env, jstring value, jsize limit, std::string *out) {
    if (!value || !out) return false;
    const jsize length = env->GetStringUTFLength(value);
    if (length <= 0 || length > limit) return false;
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return false;
    bool ok = true;
    for (jsize index = 0; index < length; index++) {
        const auto byte = static_cast<unsigned char>(chars[index]);
        if (byte < 0x21 || byte > 0x7e) { ok = false; break; }
    }
    if (ok) out->assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(value, chars);
    return ok && !env->ExceptionCheck();
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaFoundationNative_rootStop(JNIEnv *, jobject,
                                                            jlong epoch) {
    return epoch > 0 ? floe_media_foundation_root_stop(static_cast<uint64_t>(epoch))
                     : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaFoundationNative_drainPending(JNIEnv *,
                                                                jobject,
                                                                jlong epoch) {
    return epoch > 0
        ? floe_media_foundation_drain_pending(static_cast<uint64_t>(epoch))
        : 0;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaFoundationNative_status(JNIEnv *env, jobject,
                                                          jlong epoch) {
    if (epoch <= 0) return nullptr;
    std::vector<uint8_t> value(status_limit + 1);
    const auto size = floe_media_foundation_status(
        static_cast<uint64_t>(epoch), reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    if (size <= 0) return nullptr;
    return to_bytes(env, value.data(), size, status_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaFoundationNative_verify(JNIEnv *env, jobject,
                                                          jlong epoch,
                                                          jstring action,
                                                          jbyteArray request) {
    if (epoch <= 0 || !request) return nullptr;
    std::string actionValue;
    if (!copy_ascii(env, action, token_limit, &actionValue)) return nullptr;
    const auto size = env->GetArrayLength(request);
    if (size <= 0 || size > request_limit) return nullptr;
    std::vector<uint8_t> body(static_cast<size_t>(size) + 1, 0);
    env->GetByteArrayRegion(request, 0, size,
                            reinterpret_cast<jbyte *>(body.data()));
    if (env->ExceptionCheck()) return nullptr;
    std::vector<uint8_t> reply(decision_limit + 1);
    const auto written = floe_media_authority_verify(
        static_cast<uint64_t>(epoch), actionValue.c_str(),
        reinterpret_cast<const char *>(body.data()),
        reinterpret_cast<char *>(reply.data()),
        static_cast<int32_t>(reply.size()));
    if (written <= 0) return nullptr;
    return to_bytes(env, reply.data(), written, decision_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaFoundationNative_prepare(JNIEnv *env, jobject,
                                                           jlong epoch,
                                                           jbyteArray request) {
    if (epoch <= 0 || !request) return nullptr;
    const auto size = env->GetArrayLength(request);
    if (size <= 0 || size > request_limit) return nullptr;
    std::vector<uint8_t> body(static_cast<size_t>(size) + 1, 0);
    env->GetByteArrayRegion(request, 0, size,
                            reinterpret_cast<jbyte *>(body.data()));
    if (env->ExceptionCheck()) return nullptr;
    std::vector<uint8_t> reply(decision_limit + 1);
    const auto written = floe_media_render_prepare(
        static_cast<uint64_t>(epoch),
        reinterpret_cast<const char *>(body.data()),
        reinterpret_cast<char *>(reply.data()),
        static_cast<int32_t>(reply.size()));
    if (written <= 0) return nullptr;
    return to_bytes(env, reply.data(), written, decision_limit);
}
