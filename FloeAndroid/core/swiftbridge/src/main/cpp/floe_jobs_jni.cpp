// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
extern "C" int32_t floe_jobs_drain(int32_t);
extern "C" int32_t floe_jobs_cancel_owned(uint64_t, const char *);
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_JobsNative_drain(JNIEnv *, jobject, jint timeout) {
    return timeout >= 0 && timeout <= 60000 ? floe_jobs_drain(timeout) : -105;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_JobsNative_cancelJob(JNIEnv *env, jobject, jlong epoch, jstring id) {
    if (epoch <= 0 || !id || env->GetStringLength(id) != 36) return -105;
    const char *value = env->GetStringUTFChars(id, nullptr);
    if (!value) return -105;
    bool valid = true;
    for (int index = 0; index < 36; ++index) {
        const char c = value[index];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '-')) valid = false;
    }
    const int32_t result = valid ? floe_jobs_cancel_owned(static_cast<uint64_t>(epoch), value) : -105;
    env->ReleaseStringUTFChars(id, value);
    return result;
}
