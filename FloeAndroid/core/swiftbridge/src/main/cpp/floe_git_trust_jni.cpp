// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
#include <vector>
extern "C" {
int32_t floe_g04_git_trust_install(uint64_t, const uint8_t *, int32_t);
int32_t floe_g04_git_trust_retire(uint64_t);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GitTrustNative_install(JNIEnv *env, jobject, jlong epoch, jbyteArray record) {
    if (epoch <= 0 || !record) return -702;
    const auto length = env->GetArrayLength(record);
    if (length <= 0 || length > 16384 || env->ExceptionCheck()) return -702;
    try {
        std::vector<uint8_t> bytes(static_cast<size_t>(length));
        env->GetByteArrayRegion(record, 0, length, reinterpret_cast<jbyte *>(bytes.data()));
        if (env->ExceptionCheck()) return -702;
        return floe_g04_git_trust_install(static_cast<uint64_t>(epoch), bytes.data(), length);
    } catch (...) { return -704; }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GitTrustNative_retire(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_g04_git_trust_retire(static_cast<uint64_t>(epoch)) : -702;
}
