// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics trusted-host JNI adapters.
// Additive translation unit inside the SAME floe_jni target; every prior
// wrapper file stays byte-identical (corpus-first convention).
//
// Trusted-host-only: no V3 command, no model route, no Swift -> JVM
// callback. Swift (FloeAndroidCore G07NetworkHostMailbox) owns the bounded
// ticket table and every semantic decision; this file only transports bounded
// bytes and integers. The Kotlin pump calls the App-owned
// PhoneNetworkService on its own IO dispatcher.
//
// Discipline: no global refs, no AttachCurrentThread; arguments are
// length-checked; replies are copied into caller-provided buffers; typed
// negative statuses pass through unchanged; a completion body over the family
// cap is refused HERE and in Swift (double fail-closed), never truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
int32_t floe_network_diag_bind(uint64_t);
int64_t floe_network_diag_next(int32_t);
int32_t floe_network_diag_describe(int64_t, char *, int32_t);
int32_t floe_network_diag_payload_length(int64_t);
int32_t floe_network_diag_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_network_diag_is_live(int64_t);
int32_t floe_network_diag_should_stop(int64_t);
int32_t floe_network_diag_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_network_diag_close(uint64_t);
int32_t floe_network_diag_stats(char *, int32_t);
int32_t floe_network_diag_readiness(char *, int32_t);
}

namespace {
constexpr int32_t descriptor_limit = 2048;            // G07NetworkHostLimits
constexpr int32_t payload_limit = 16 * 1024;          // request v1 cap
constexpr int32_t reply_limit = 256 * 1024;            // observation cap
constexpr int32_t failure_limit = 512;                 // typed failure cap
constexpr int32_t readback_limit = 4096;               // stats/readiness

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte *>(data));
    }
    return env->ExceptionCheck() ? nullptr : result;
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_bindEpoch(JNIEnv *, jobject,
                                                                jlong epoch) {
    return epoch > 0 ? floe_network_diag_bind(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_next(JNIEnv *, jobject,
                                                           jint timeout) {
    return floe_network_diag_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_describe(JNIEnv *env, jobject,
                                                               jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_network_diag_describe(
        claim, reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_payload(JNIEnv *env, jobject,
                                                              jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_network_diag_payload_length(claim);
    if (size <= 0 || size > payload_limit) return nullptr;
    std::vector<uint8_t> value(size);
    const auto actual = floe_network_diag_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, payload_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_isLive(JNIEnv *, jobject,
                                                             jlong claim) {
    return claim > 0 ? floe_network_diag_is_live(claim) : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_shouldStop(JNIEnv *, jobject,
                                                                 jlong claim) {
    return claim > 0 ? floe_network_diag_should_stop(claim) : 1;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_complete(JNIEnv *env, jobject,
                                                               jlong claim, jint status,
                                                               jbyteArray body) {
    if (claim <= 0 || !body || (status != 0 && status != 1)) return -105;
    const auto size = env->GetArrayLength(body);
    if (size <= 0 || size > (status == 0 ? reply_limit : failure_limit)) return -106;
    std::vector<uint8_t> value(size);
    env->GetByteArrayRegion(body, 0, size, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_network_diag_complete(claim, status, value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_close(JNIEnv *, jobject,
                                                            jlong epoch) {
    return epoch > 0 ? floe_network_diag_close(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_network_diag_stats(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_NetworkDiagnosticsNative_readiness(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_network_diag_readiness(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}
