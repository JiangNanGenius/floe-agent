// SPDX-License-Identifier: MPL-2.0
// Trusted host transports only. Swift owns approval and workspace authority.
#include <jni.h>
#include <cstdint>
#include <vector>

extern "C" {
int32_t floe_platform_tool_set_auto_admission(uint64_t, const uint8_t *, int32_t);
int32_t floe_platform_tool_stage_workspace_apk(
    int64_t, const uint8_t *, int32_t, char *, int32_t);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_setAutoAdmission(
    JNIEnv *env, jobject, jlong epoch, jbyteArray json) {
    if (epoch <= 0 || json == nullptr) return -105;
    const auto size = env->GetArrayLength(json);
    if (size <= 0 || size > 16 * 1024) return -107;
    std::vector<uint8_t> value(static_cast<size_t>(size));
    env->GetByteArrayRegion(json, 0, size,
        reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_platform_tool_set_auto_admission(
        static_cast<uint64_t>(epoch), value.data(), size);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_swiftbridge_PlatformToolsNative_stageWorkspaceApk(
    JNIEnv *env, jobject, jlong claim, jbyteArray path) {
    if (claim <= 0 || path == nullptr) return nullptr;
    const auto size = env->GetArrayLength(path);
    if (size <= 0 || size > 2048) return nullptr;
    std::vector<uint8_t> input(static_cast<size_t>(size));
    env->GetByteArrayRegion(path, 0, size,
        reinterpret_cast<jbyte *>(input.data()));
    if (env->ExceptionCheck()) return nullptr;
    // Only metadata crosses JNI; the APK travels through the owned file lane.
    std::vector<char> reply(8193);
    const auto count = floe_platform_tool_stage_workspace_apk(
        claim, input.data(), size, reply.data(),
        static_cast<int32_t>(reply.size()));
    if (count <= 0 || count > 8192) return nullptr;
    auto bytes = env->NewByteArray(count);
    if (bytes != nullptr) {
        env->SetByteArrayRegion(bytes, 0, count,
            reinterpret_cast<const jbyte *>(reply.data()));
    }
    return env->ExceptionCheck() ? nullptr : bytes;
}
