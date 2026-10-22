// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
#include <vector>
extern "C" {
int32_t floe_linux_shell_bind_epoch(uint64_t);
int32_t floe_linux_shell_fence_generation(uint64_t);
int32_t floe_linux_shell_suspend_admission(uint64_t);
int32_t floe_linux_shell_drain(int32_t);
int64_t floe_linux_shell_mailbox_next(int32_t);
int32_t floe_linux_shell_mailbox_describe(int64_t, char *, int32_t);
int32_t floe_linux_shell_mailbox_payload_length(int64_t);
int32_t floe_linux_shell_mailbox_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_linux_shell_mailbox_is_live(int64_t);
int32_t floe_linux_shell_mailbox_should_stop(int64_t);
int32_t floe_linux_shell_mailbox_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_linux_shell_mailbox_close();
}
namespace {
constexpr int32_t limit = 65536;
jbyteArray bytes(JNIEnv *env, const uint8_t *data, int32_t size) {
    if (size < 0 || size > limit) return nullptr;
    jbyteArray result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return result;
}
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_linux_shell_bind_epoch(static_cast<uint64_t>(epoch)) : -105;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_fenceEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_linux_shell_fence_generation(static_cast<uint64_t>(epoch)) : -105;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_suspendAdmission(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_linux_shell_suspend_admission(static_cast<uint64_t>(epoch)) : -105;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_drain(JNIEnv *, jobject, jint timeout) {
    return timeout >= 0 && timeout <= 60000 ? floe_linux_shell_drain(timeout) : -105;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_LinuxShellNative_next(JNIEnv *, jobject, jint timeout) {
    return floe_linux_shell_mailbox_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxShellNative_describe(JNIEnv *env, jobject, jlong claim) {
    std::vector<uint8_t> value(limit + 1);
    const int32_t count = floe_linux_shell_mailbox_describe(claim, reinterpret_cast<char *>(value.data()), value.size());
    return bytes(env, value.data(), count);
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxShellNative_payload(JNIEnv *env, jobject, jlong claim) {
    const int32_t count = floe_linux_shell_mailbox_payload_length(claim);
    if (count < 0 || count > limit) return nullptr;
    std::vector<uint8_t> value(count);
    const int32_t actual = floe_linux_shell_mailbox_take_payload(claim, value.data(), count);
    return actual == count ? bytes(env, value.data(), actual) : nullptr;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_isLive(JNIEnv *, jobject, jlong claim) {
    return floe_linux_shell_mailbox_is_live(claim);
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_shouldStop(JNIEnv *, jobject, jlong claim) {
    return floe_linux_shell_mailbox_should_stop(claim);
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_complete(JNIEnv *env, jobject, jlong claim, jint status, jbyteArray body) {
    if (!body || (status != 0 && status != 1)) return -105;
    const jsize count = env->GetArrayLength(body);
    if (count < 0 || count > limit) return -106;
    std::vector<uint8_t> value(count);
    if (count) env->GetByteArrayRegion(body, 0, count, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_linux_shell_mailbox_complete(claim, status, value.data(), count);
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxShellNative_close(JNIEnv *, jobject) {
    return floe_linux_shell_mailbox_close();
}
