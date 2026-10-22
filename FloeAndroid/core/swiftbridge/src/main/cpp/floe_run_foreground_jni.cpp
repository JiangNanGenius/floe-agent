// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
extern "C" {
int32_t floe_run_foreground_snapshot(char *, int32_t);
int64_t floe_run_foreground_wait_change(int64_t, int32_t);
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RunForegroundNative_snapshot(JNIEnv *env, jobject) {
    char output[257] = {};
    const int32_t count = floe_run_foreground_snapshot(output, sizeof(output));
    if (count <= 0 || count >= static_cast<int32_t>(sizeof(output))) return nullptr;
    for (int32_t index = 0; index < count; ++index)
        if (output[index] == 0 || static_cast<uint8_t>(output[index]) >= 128) return nullptr;
    output[count] = 0;
    return env->NewStringUTF(output);
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_RunForegroundNative_waitChange(JNIEnv *, jobject, jlong after, jint timeout) {
    return floe_run_foreground_wait_change(after, timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}
