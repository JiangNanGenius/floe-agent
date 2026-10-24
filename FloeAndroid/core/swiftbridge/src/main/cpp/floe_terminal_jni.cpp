// SPDX-License-Identifier: MPL-2.0
//
// Trusted-host JNI translation unit for the G04 embedded terminal + LSP
// mailbox (job-dda32d23d55e4460). Additive TU inside the SAME floe_jni
// target (Main appends the one CMakeLists line). Semantics live entirely
// in FloeAndroidCore (G04TerminalHostAPI.swift); this file only bounds
// copies and marshals arrays. It is NOT a model-facing surface: no V3
// command, no reflection, no path or grant parameters.
#include <jni.h>
#include <cstdint>
#include <vector>
extern "C" {
int32_t floe_g04_terminal_bind(uint64_t);
int64_t floe_g04_terminal_submit_action(const uint8_t *, int32_t, const uint8_t *, int32_t);
int64_t floe_g04_terminal_next_event(int32_t);
int32_t floe_g04_terminal_describe(int64_t, char *, int32_t);
int32_t floe_g04_terminal_payload_length(int64_t);
int32_t floe_g04_terminal_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_g04_terminal_ack(int64_t);
int32_t floe_g04_terminal_close(uint64_t);
int32_t floe_g04_terminal_stats(char *, int32_t);
}
namespace {
constexpr int32_t control_limit = 65536;        // frozen 64 KiB envelope
constexpr int32_t payload_limit = 4 * 1024 * 1024;  // raw document-text channel
constexpr int32_t stats_limit = 4096;

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    jbyteArray result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return env->ExceptionCheck() ? nullptr : result;
}

std::vector<uint8_t> read_bytes(JNIEnv *env, jbyteArray array, int32_t limit, bool *ok) {
    *ok = true;
    if (array == nullptr) return {};
    const jsize size = env->GetArrayLength(array);
    if (size < 0 || size > limit) { *ok = false; return {}; }
    std::vector<uint8_t> value(size);
    if (size) env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) { *ok = false; return {}; }
    return value;
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_TerminalNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_g04_terminal_bind(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_TerminalNative_submitAction(JNIEnv *env, jobject, jbyteArray descriptor,
                                                         jbyteArray payload) {
    bool ok = false;
    const auto desc = read_bytes(env, descriptor, control_limit, &ok);
    if (!ok || desc.empty() || static_cast<int32_t>(desc.size()) > control_limit) return -105;
    const auto body = read_bytes(env, payload, payload_limit, &ok);
    if (!ok) return -106;
    const int32_t body_len = payload == nullptr ? 0 : static_cast<int32_t>(body.size());
    return floe_g04_terminal_submit_action(desc.data(), static_cast<int32_t>(desc.size()),
                                           body_len > 0 ? body.data() : nullptr, body_len);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_TerminalNative_next(JNIEnv *, jobject, jint timeout) {
    return floe_g04_terminal_next_event(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_TerminalNative_describe(JNIEnv *env, jobject, jlong event) {
    if (event <= 0) return nullptr;
    std::vector<uint8_t> value(control_limit + 1);
    const auto size = floe_g04_terminal_describe(event, reinterpret_cast<char *>(value.data()),
                                                 static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, control_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_TerminalNative_payload(JNIEnv *env, jobject, jlong event) {
    if (event <= 0) return nullptr;
    const auto size = floe_g04_terminal_payload_length(event);
    if (size < 0 || size > control_limit) return nullptr;
    if (size == 0) return to_bytes(env, nullptr, 0, control_limit);
    std::vector<uint8_t> value(size);
    const auto actual = floe_g04_terminal_take_payload(event, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, control_limit) : nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_TerminalNative_ack(JNIEnv *, jobject, jlong event) {
    return event > 0 ? floe_g04_terminal_ack(event) : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_TerminalNative_close(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_g04_terminal_close(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_TerminalNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(stats_limit + 1);
    const auto size = floe_g04_terminal_stats(reinterpret_cast<char *>(value.data()),
                                              static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, stats_limit);
}
