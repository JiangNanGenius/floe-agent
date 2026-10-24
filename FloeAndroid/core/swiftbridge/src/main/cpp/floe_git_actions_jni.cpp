// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <string>
extern "C" {
int32_t floe_g04_git_actions_scene(uint64_t, int32_t, const char *);
}

// Trusted App lifecycle ingress ONLY (mirrors floe_git_trust_jni.cpp's
// ingress discipline). No payload, no paths, no credential bytes cross this
// seam: it forwards the REAL activity scene identity + foreground flag to the
// durable engine's original scene rules. The Swift side re-validates the
// accepted epoch, the identifier charset and the live composition; this layer
// only bounds the copy and guarantees a NUL-terminated, length-limited UTF-8
// argument. A refused/oversized identity is a typed negative, never a
// partially delivered event.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GitActionsNative_scene(JNIEnv *env, jobject, jlong epoch,
                                                    jboolean active, jstring scene_id) {
    if (epoch <= 0 || !scene_id) return -105;
    const jsize length = env->GetStringUTFLength(scene_id);
    if (length <= 0 || length > 64 || env->ExceptionCheck()) return -105;
    const char *raw = env->GetStringUTFChars(scene_id, nullptr);
    if (!raw) return -105;
    std::string identity(raw, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(scene_id, raw);
    if (env->ExceptionCheck()) return -105;
    // Swift enforces the strict [A-Za-z0-9_-] rule; reject embedded NULs here
    // so no truncated identity can ever reach the native registry.
    if (identity.find('\0') != std::string::npos) return -105;
    return floe_g04_git_actions_scene(static_cast<uint64_t>(epoch), active ? 1 : 0,
                                       identity.c_str());
}
