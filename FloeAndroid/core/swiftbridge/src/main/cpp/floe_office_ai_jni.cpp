// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI trusted-host JNI adapters (job-1db1a7a8d5da457a).
// Additive translation unit inside the SAME floe_jni target; every prior
// wrapper file stays byte-identical (corpus-first convention).
//
// Two families, both trusted-host-only (no V3 command, no model route):
//  * the Office AI mailbox PUMP ABI (bind/next/describe/payload/isLive/
//    shouldStop/complete/close/stats) mirroring the reviewed
//    WorkspaceSource pump discipline;
//  * (none other — all Office AI semantics live in FloeAndroidCore/OfficeAI).
//
// Discipline: no global refs, no AttachCurrentThread, no Swift -> JVM
// callback; arguments are length-checked ASCII tokens; replies are copied
// into caller-provided buffers; typed negative statuses pass through
// unchanged; a completion body over the family cap is refused here AND in
// Swift (double fail-closed), never truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
int32_t floe_office_ai_bind(uint64_t);
int64_t floe_office_ai_next(int32_t);
int32_t floe_office_ai_describe(int64_t, char *, int32_t);
int32_t floe_office_ai_payload_length(int64_t);
int32_t floe_office_ai_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_office_ai_is_live(int64_t);
int32_t floe_office_ai_should_stop(int64_t);
int32_t floe_office_ai_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_office_ai_close(uint64_t);
int32_t floe_office_ai_stats(char *, int32_t);
}

namespace {
constexpr int32_t descriptor_limit = 2048;           // OfficeAIHostLimits
constexpr int32_t payload_limit = 96 * 1024;         // maximumStagedBytes
constexpr int32_t reply_limit = 1024 * 1024;         // maximumReplyBytes
constexpr int32_t failure_limit = 256;               // maximumFailureReplyBytes
constexpr int32_t stats_limit = 4096;

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return env->ExceptionCheck() ? nullptr : result;
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_OfficeAiNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_office_ai_bind(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_OfficeAiNative_next(JNIEnv *, jobject, jint timeout) {
    return floe_office_ai_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_OfficeAiNative_describe(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_office_ai_describe(claim, reinterpret_cast<char *>(value.data()),
                                              static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_OfficeAiNative_payload(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_office_ai_payload_length(claim);
    if (size < 0 || size > payload_limit) return nullptr;
    std::vector<uint8_t> value(size > 0 ? size : 1);
    const auto actual = floe_office_ai_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, payload_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_OfficeAiNative_isLive(JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_office_ai_is_live(claim) : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_OfficeAiNative_shouldStop(JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_office_ai_should_stop(claim) : 1;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_OfficeAiNative_complete(JNIEnv *env, jobject, jlong claim, jint status,
                                                     jbyteArray body) {
    if (claim <= 0 || !body || (status != 0 && status != 1)) return -105;
    const auto size = env->GetArrayLength(body);
    if (size < 0 || size > (status == 0 ? reply_limit : failure_limit)) return -106;
    std::vector<uint8_t> value(size);
    if (size) env->GetByteArrayRegion(body, 0, size, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_office_ai_complete(claim, status, value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_OfficeAiNative_close(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_office_ai_close(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_OfficeAiNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(stats_limit + 1);
    const auto size = floe_office_ai_stats(reinterpret_cast<char *>(value.data()),
                                           static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, stats_limit);
}
