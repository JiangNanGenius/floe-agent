// SPDX-License-Identifier: MPL-2.0
//
// G08 generic platform-tool mailbox trusted-host JNI adapters.
// Additive translation unit intended for the SAME floe_jni target; every
// prior wrapper file stays byte-identical (corpus-first convention).
//
// Trusted-host-only: no V3 command, no model route, no Swift -> JVM callback.
// Swift (FloeAndroidCore `PlatformToolHostMailbox` / `PlatformToolHostBridge`)
// owns the bounded catalog, the ticket table, every ownership decision, the
// schema subset and the result contract. This file only transports bounded
// bytes and integers. The Full App pump performs the REAL typed phone/system
// operation; this shared core never carries a device name, tool name, schema
// or implementation.
//
// Bounds (must stay in lockstep with PlatformToolHostLimits):
//   catalog 96 KiB, ticket descriptor 2 KiB, arguments 64 KiB,
//   success result 64 KiB, typed failure 512 B, readbacks 8 KiB.
// An over-limit body is refused HERE and in Swift (double fail-closed), never
// truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
int32_t floe_platform_tool_bind(uint64_t, const uint8_t *, int32_t);
int64_t floe_platform_tool_next(int32_t);
int32_t floe_platform_tool_describe(int64_t, char *, int32_t);
int32_t floe_platform_tool_payload_length(int64_t);
int32_t floe_platform_tool_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_platform_tool_is_live(int64_t);
int32_t floe_platform_tool_should_stop(int64_t);
int32_t floe_platform_tool_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_platform_tool_set_availability(uint64_t, const uint8_t *, int32_t);
int32_t floe_platform_tool_close(uint64_t);
int32_t floe_platform_tool_stats(char *, int32_t);
int32_t floe_platform_tool_readiness(char *, int32_t);
int32_t floe_platform_tool_artifact_root(char *, int32_t);
}

namespace {
constexpr int32_t catalog_limit = 128 * 1024; // PlatformToolHostLimits
constexpr int32_t descriptor_limit = 2048;    // per-ticket descriptor
constexpr int32_t payload_limit = 64 * 1024;  // toolArgumentsMaxBytes
constexpr int32_t reply_limit = 64 * 1024;    // bounded tool result
constexpr int32_t failure_limit = 512;        // typed failure
constexpr int32_t availability_limit = 16 * 1024; // PlatformToolHostLimits
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
Java_com_floe_android_swiftbridge_PlatformToolsNative_bind(
    JNIEnv *env, jobject, jlong epoch, jbyteArray catalog) {
    if (epoch <= 0 || catalog == nullptr) return -105;
    const auto size = env->GetArrayLength(catalog);
    if (size <= 0 || size > catalog_limit) return -107;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    env->GetByteArrayRegion(catalog, 0, size,
                            reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_platform_tool_bind(static_cast<uint64_t>(epoch), value.data(), size);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_next(
    JNIEnv *, jobject, jint timeout) {
    return floe_platform_tool_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_describe(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_platform_tool_describe(
        claim, reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_payload(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_platform_tool_payload_length(claim);
    if (size <= 0 || size > payload_limit) return nullptr;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    const auto actual = floe_platform_tool_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, payload_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_isLive(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_platform_tool_is_live(claim) : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_shouldStop(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_platform_tool_should_stop(claim) : 1;
}

// Same-epoch usable-capability publish (`setAvailability(epoch, namesJson)`).
// The body is a bounded JSON string array; Swift validates subset/duplicates
// atomically and fences queued dispatch for names no longer available.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_setAvailability(
    JNIEnv *env, jobject, jlong epoch, jbyteArray names) {
    if (epoch <= 0 || names == nullptr) return -105;
    const auto size = env->GetArrayLength(names);
    if (size <= 0 || size > availability_limit) return -107;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    env->GetByteArrayRegion(names, 0, size,
                            reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_platform_tool_set_availability(
        static_cast<uint64_t>(epoch), value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_complete(
    JNIEnv *env, jobject, jlong claim, jint status, jbyteArray body) {
    if (claim <= 0 || body == nullptr || (status != 0 && status != 1)) return -105;
    const auto size = env->GetArrayLength(body);
    if (size <= 0 || size > (status == 0 ? reply_limit : failure_limit)) return -107;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    env->GetByteArrayRegion(body, 0, size,
                            reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_platform_tool_complete(claim, status, value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_close(
    JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_platform_tool_close(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_stats(
    JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_platform_tool_stats(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_readiness(
    JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_platform_tool_readiness(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}

// Trusted host readback of the ONE mailbox-bound actual artifact root
// (`<live owned root>/FloeAgent`). Negative status (generationFenced) is
// returned as null; the path never enters a model-facing error.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_artifactRoot(
    JNIEnv *env, jobject) {
    std::vector<uint8_t> value(readback_limit + 1);
    const auto size = floe_platform_tool_artifact_root(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, readback_limit);
}
