// SPDX-License-Identifier: MPL-2.0
//
// C05 device communication trusted-host JNI adapters.
// Additive translation unit for the SAME floe_jni target; every prior wrapper
// file stays byte-identical.
//
// Trusted-host-only: no V3 command, no model route, no Swift -> JVM callback.
// Swift (FloeAndroidCore `C05DeviceHostMailbox`) owns the bounded ticket
// table, ownership decisions, approval requirement and cancellation checks.
// This file only transports bounded bytes and integers. The Kotlin App pump
// performs the REAL TCP/Telnet/BLE/USB operation through the device engine.
//
// Bounds (must stay in lockstep with C05DeviceHostLimits):
//   descriptor 2 KiB, request/arguments 64 KiB, reply 48 KiB, readback 8 KiB.
// An over-limit body is refused HERE and in Swift (double fail-closed), never
// truncated.
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
int32_t floe_device_bind(uint64_t);
int64_t floe_device_next(int32_t);
int32_t floe_device_describe(int64_t, char *, int32_t);
int32_t floe_device_payload_length(int64_t);
int32_t floe_device_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_device_is_live(int64_t);
int32_t floe_device_should_stop(int64_t);
int32_t floe_device_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_device_close(uint64_t);
int32_t floe_device_stats(char *, int32_t);
int32_t floe_device_readiness(char *, int32_t);
}

namespace {
constexpr int32_t descriptor_limit = 2048;      // C05DeviceHostLimits
constexpr int32_t payload_limit = 64 * 1024;    // request/arguments
constexpr int32_t reply_limit = 48 * 1024;      // metadata reply budget
constexpr int32_t readback_limit = 8192;
constexpr int32_t status_shape = -105;          // mailbox status family

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
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_bind(
    JNIEnv *, jobject, jlong epoch) {
    if (epoch <= 0) return status_shape;
    return floe_device_bind(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_next(
    JNIEnv *, jobject, jint timeout) {
    return floe_device_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_describe(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_device_describe(
        claim, reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_payload(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_device_payload_length(claim);
    if (size <= 0 || size > payload_limit) return nullptr;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    const auto actual = floe_device_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, payload_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_isLive(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_device_is_live(claim) : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_shouldStop(
    JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_device_should_stop(claim) : 1;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_complete(
    JNIEnv *env, jobject, jlong claim, jint status, jbyteArray value) {
    if (claim <= 0 || (status != 0 && status != 1)) return status_shape;
    if (value == nullptr) {
        return floe_device_complete(claim, status, nullptr, 0);
    }
    const auto size = env->GetArrayLength(value);
    if (size < 0 || size > reply_limit) return -107;
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    env->GetByteArrayRegion(value, 0, size, reinterpret_cast<jbyte *>(bytes.data()));
    if (env->ExceptionCheck()) return status_shape;
    return floe_device_complete(claim, status, bytes.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_close(
    JNIEnv *, jobject, jlong epoch) {
    if (epoch <= 0) return status_shape;
    return floe_device_close(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_stats(
    JNIEnv *env, jobject) {
    std::vector<char> value(readback_limit + 1);
    const auto size = floe_device_stats(value.data(), static_cast<int32_t>(value.size()));
    return to_bytes(env, reinterpret_cast<const uint8_t *>(value.data()), size, readback_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_core_devicecommunication_C05DeviceToolNative_readiness(
    JNIEnv *env, jobject) {
    std::vector<char> value(readback_limit + 1);
    const auto size = floe_device_readiness(value.data(), static_cast<int32_t>(value.size()));
    return to_bytes(env, reinterpret_cast<const uint8_t *>(value.data()), size, readback_limit);
}
