// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 trusted-host JNI wrapper for the typed runtime-UID workspace
// cleanup request/receipt lane (job-3d39b56695c44bd2). The Kotlin host
// (Main's RuntimeConnection owner) claims Core-issued obligations, executes
// the runtime-side removal under the DISTINCT runtime UID, and settles the
// claim with a typed receipt. This wrapper only bounds/validates transport
// shapes; ALL ownership/epoch/scope semantics live in FloeAndroidCore's
// LinuxRuntimeCleanupLane. Never a model-reachable surface (no V3 key).
#include <jni.h>
#include <cstdint>
#include <string>
#include <vector>
extern "C" {
int32_t floe_linux_runtime_cleanup_bind(uint64_t);
int64_t floe_linux_runtime_cleanup_next(int32_t);
int32_t floe_linux_runtime_cleanup_describe(int64_t, char*, int32_t);
int32_t floe_linux_runtime_cleanup_payload_length(int64_t);
int32_t floe_linux_runtime_cleanup_take_payload(int64_t, uint8_t*, int32_t);
int32_t floe_linux_runtime_cleanup_is_live(int64_t);
int32_t floe_linux_runtime_cleanup_complete(int64_t, const char*, int32_t, char*, int32_t);
int32_t floe_linux_runtime_cleanup_status(const char*, char*, int32_t);
int32_t floe_linux_runtime_cleanup_stats(char*, int32_t);
}
namespace {
constexpr int32_t limit = 65536;
constexpr int32_t maximumReceipt = 4096;

bool identifier(JNIEnv* env, jstring input, std::string& out) {
    if (!input) return false;
    const jsize n = env->GetStringLength(input);
    if (n < 1 || n > 64) return false;
    const jchar* value = env->GetStringChars(input, nullptr);
    if (!value) return false;
    bool valid = true;
    for (jsize i = 0; i < n; ++i) {
        if (value[i] < 0x21 || value[i] > 0x7e) { valid = false; break; }
        out.push_back(static_cast<char>(value[i]));
    }
    env->ReleaseStringChars(input, value);
    return valid && !env->ExceptionCheck();
}

bool receipt(JNIEnv* env, jbyteArray input, std::vector<char>& out) {
    if (!input) return false;
    const jsize n = env->GetArrayLength(input);
    if (n < 1 || n > maximumReceipt) return false;
    out.resize(n);
    env->GetByteArrayRegion(input, 0, n, reinterpret_cast<jbyte*>(out.data()));
    return !env->ExceptionCheck();
}

template <typename F>
jbyteArray response(JNIEnv* env, F call) {
    std::vector<char> out(limit + 1);
    const int32_t n = call(out.data(), static_cast<int32_t>(out.size()));
    // Never replay a side effect after a short/uncertain response.
    if (n < 0 || n > limit || env->ExceptionCheck()) return nullptr;
    jbyteArray bytes = env->NewByteArray(n);
    if (bytes && n) env->SetByteArrayRegion(bytes, 0, n, reinterpret_cast<const jbyte*>(out.data()));
    return env->ExceptionCheck() ? nullptr : bytes;
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_bind(JNIEnv* env, jobject, jlong epoch) {
    if (epoch <= 0) return -105;
    return floe_linux_runtime_cleanup_bind(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_next(JNIEnv* env, jobject, jint timeoutMillis) {
    if (timeoutMillis < 0 || timeoutMillis > 60000) return -2;
    return floe_linux_runtime_cleanup_next(timeoutMillis);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_describe(JNIEnv* env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_runtime_cleanup_describe(claim, out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_payload(JNIEnv* env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const int32_t len = floe_linux_runtime_cleanup_payload_length(claim);
    if (len < 1 || len > limit) return nullptr;
    std::vector<char> buffer(static_cast<size_t>(len));
    if (floe_linux_runtime_cleanup_take_payload(claim,
            reinterpret_cast<uint8_t*>(buffer.data()), len) != len) {
        return nullptr;
    }
    jbyteArray bytes = env->NewByteArray(len);
    if (bytes) env->SetByteArrayRegion(bytes, 0, len, reinterpret_cast<const jbyte*>(buffer.data()));
    return env->ExceptionCheck() ? nullptr : bytes;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_isLive(JNIEnv* env, jobject, jlong claim) {
    if (claim <= 0) return JNI_FALSE;
    return floe_linux_runtime_cleanup_is_live(claim) == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_complete(JNIEnv* env, jobject, jlong claim,
                                                                 jbyteArray receiptBytes) {
    std::vector<char> value;
    if (claim <= 0 || !receipt(env, receiptBytes, value)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_runtime_cleanup_complete(claim, value.data(),
                                                   static_cast<int32_t>(value.size()), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_status(JNIEnv* env, jobject, jstring requestID) {
    std::string id;
    if (!identifier(env, requestID, id)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_runtime_cleanup_status(id.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxRuntimeCleanupNative_stats(JNIEnv* env, jobject) {
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_runtime_cleanup_stats(out, cap);
    });
}
