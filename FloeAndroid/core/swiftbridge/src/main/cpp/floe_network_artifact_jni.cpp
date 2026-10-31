// SPDX-License-Identifier: MPL-2.0
//
// G07.3B saved-artifact mailbox trusted-host JNI adapters.
// Additive translation unit inside the SAME floe_jni target; every prior
// wrapper file stays byte-identical (corpus-first convention).
//
// Trusted-host-only: no V3 command, no model route, no Swift -> JVM callback.
// Swift (FloeAndroidCore G073NetworkArtifactHostMailbox) owns the bounded
// ticket table and every semantic decision; this file only transports bounded
// bytes and integers. The Kotlin pump reads App-private summaries through
// PcapAnalysisStore/CoverageSessionStore on its own IO dispatcher.
//
// Bounds: descriptor 2 KiB, request 8 KiB, reply 32 KiB, failure 512 B,
// readbacks 8 KiB. A reply over the family cap is refused HERE and in Swift
// (double fail-closed), never truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
int32_t floe_network_artifact_bind(uint64_t);
int64_t floe_network_artifact_next(int32_t);
int32_t floe_network_artifact_describe(int64_t, char *, int32_t);
int32_t floe_network_artifact_payload_length(int64_t);
int32_t floe_network_artifact_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_network_artifact_is_live(int64_t);
int32_t floe_network_artifact_should_stop(int64_t);
int32_t floe_network_artifact_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_network_artifact_close(uint64_t);
int32_t floe_network_artifact_stats(char *, int32_t);
int32_t floe_network_artifact_readiness(char *, int32_t);
}

namespace {
constexpr int32_t descriptor_limit = 2048;   // G073NetworkArtifactHostLimits
constexpr int32_t payload_limit = 8 * 1024;  // request v1 cap
constexpr int32_t reply_limit = 32 * 1024;   // tool reply cap
constexpr int32_t failure_limit = 512;       // typed failure cap
constexpr int32_t readback_limit = 8192;

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
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_bindEpoch(
    JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_network_artifact_bind(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_next(
    JNIEnv *, jobject, jint timeout) {
    return floe_network_artifact_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_describe(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_network_artifact_describe(
        claim, reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_payload(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_network_artifact_payload_length(claim);
    if (size <= 0 || size > payload_limit) return nullptr;
    std::vector<uint8_t> value(size);
    const auto actual = floe_network_artifact_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, payload_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_isLive(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_network_artifact_is_live(claim) : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_shouldStop(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_network_artifact_should_stop(claim) : 1;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_complete(
    JNIEnv *env, jobject, jlong claim, jint status, jbyteArray body) {
    if (claim <= 0 || !body || (status != 0 && status != 1)) return -105;
    const auto size = env->GetArrayLength(body);
    if (size <= 0 || size > (status == 0 ? reply_limit : failure_limit)) return -106;
    std::vector<uint8_t> value(size);
    env->GetByteArrayRegion(body, 0, size, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_network_artifact_complete(claim, status, value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_close(
    JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_network_artifact_close(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_stats(
    JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_network_artifact_stats(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_networkartifact_NetworkArtifactNative_readiness(
    JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_network_artifact_readiness(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}
