// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 browser host JNI — the thin, trust-preserving bridge between
// BrowserNative.kt (compiled into the App) and the Swift C ABI exported by
// G04BrowserHostAPI.swift. It contains ZERO browser logic: no path handling,
// no policy, no session state, no retries. Every identity (claim, leaseID,
// serverID, tabID, owner triple) is minted natively and merely transported
// here. Reply buffers are caller-allocated; a typed negative status is
// never silently converted into success or truncation.
#include <jni.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
// Browser host mailbox pump (mirrors floe_g04_source_* semantics).
int32_t floe_browser_bind(uint64_t);
int64_t floe_browser_next(int32_t);
int32_t floe_browser_describe(int64_t, char *, int32_t);
int32_t floe_browser_payload_length(int64_t);
int32_t floe_browser_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_browser_is_live(int64_t);
int32_t floe_browser_should_stop(int64_t);
int32_t floe_browser_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_browser_close(uint64_t);
int32_t floe_browser_bound_epoch(char *, int32_t);
int32_t floe_browser_stats(char *, int32_t);
// Trusted host uplinks.
int32_t floe_browser_ingest_event(const char *);
int32_t floe_browser_policy_allows(const char *);
int32_t floe_browser_popup_query(const char *);
int32_t floe_browser_download_request(const char *);
int32_t floe_browser_ui_call(const char *);
int32_t floe_browser_ui_query(const char *, char *, int32_t, int32_t);
int32_t floe_browser_preview_adjudicate(const char *, const char *, const uint8_t *, int32_t,
                                        char *, int32_t);
int32_t floe_browser_preview_read_chunk(const char *, const char *, int32_t, uint8_t *, int32_t);
int32_t floe_browser_recover_handoff(const char *, const char *, uint64_t);
int32_t floe_browser_services_live(uint64_t);
}

namespace {
constexpr int32_t descriptor_limit = 4096;
constexpr int32_t epoch_limit = 32;
constexpr int32_t stats_limit = 4096;

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return env->ExceptionCheck() ? nullptr : result;
}

std::string to_string(JNIEnv *env, jstring value) {
    if (value == nullptr) return std::string();
    const char *text = env->GetStringUTFChars(value, nullptr);
    if (text == nullptr) return std::string();
    std::string result(text);
    env->ReleaseStringUTFChars(value, text);
    return result;
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_browser_bind(static_cast<uint64_t>(epoch)) : -102;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_BrowserNative_next(JNIEnv *, jobject, jint timeout) {
    return floe_browser_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_BrowserNative_describe(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_browser_describe(claim, reinterpret_cast<char *>(value.data()),
                                            static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_BrowserNative_payload(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_browser_payload_length(claim);
    if (size < 0 || size > 256 * 1024) return nullptr;
    std::vector<uint8_t> value(size > 0 ? size : 1);
    const auto copied = floe_browser_take_payload(claim, value.data(), size);
    if (copied < 0) return nullptr;
    return to_bytes(env, value.data(), copied, 256 * 1024);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_isLive(JNIEnv *, jobject, jlong claim) {
    return floe_browser_is_live(claim);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_shouldStop(JNIEnv *, jobject, jlong claim) {
    return floe_browser_should_stop(claim);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_complete(JNIEnv *env, jobject, jlong claim, jint status,
                                                    jbyteArray value) {
    if (value == nullptr) return floe_browser_complete(claim, status, nullptr, 0);
    const auto length = env->GetArrayLength(value);
    std::vector<uint8_t> bytes(length > 0 ? length : 1);
    if (length > 0) {
        env->GetByteArrayRegion(value, 0, length, reinterpret_cast<jbyte *>(bytes.data()));
        if (env->ExceptionCheck()) return -105;
    }
    return floe_browser_complete(claim, status, length > 0 ? bytes.data() : nullptr, length);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_close(JNIEnv *, jobject, jlong epoch) {
    return floe_browser_close(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_BrowserNative_boundEpoch(JNIEnv *, jobject) {
    std::vector<char> buffer(epoch_limit + 1);
    const auto size = floe_browser_bound_epoch(buffer.data(), static_cast<int32_t>(buffer.size()));
    if (size < 0) return -1;
    buffer[size] = 0;
    return static_cast<jlong>(strtoull(buffer.data(), nullptr, 10));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_BrowserNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(stats_limit + 1);
    const auto size = floe_browser_stats(reinterpret_cast<char *>(value.data()),
                                         static_cast<int32_t>(value.size()));
    return to_bytes(env, value.data(), size, stats_limit);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_ingestEvent(JNIEnv *env, jobject, jstring json) {
    const auto text = to_string(env, json);
    if (text.empty()) return -603;
    return floe_browser_ingest_event(text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_policyAllows(JNIEnv *env, jobject, jstring json) {
    const auto text = to_string(env, json);
    if (text.empty()) return 0;
    return floe_browser_policy_allows(text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_popupQuery(JNIEnv *env, jobject, jstring json) {
    const auto text = to_string(env, json);
    if (text.empty()) return -603;
    return floe_browser_popup_query(text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_downloadRequest(JNIEnv *env, jobject, jstring json) {
    const auto text = to_string(env, json);
    if (text.empty()) return -603;
    return floe_browser_download_request(text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_uiCall(JNIEnv *env, jobject, jstring json) {
    const auto text = to_string(env, json);
    if (text.empty()) return -603;
    return floe_browser_ui_call(text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_uiQuery(JNIEnv *env, jobject, jstring json,
                                                   jbyteArray reply, jint timeoutMillis) {
    if (reply == nullptr) return -105;
    const auto capacity = env->GetArrayLength(reply);
    if (capacity <= 0 || capacity > 512 * 1024) return -105;
    std::vector<jbyte> buffer(capacity);
    const auto text = to_string(env, json);
    if (text.empty()) return -603;
    const auto size = floe_browser_ui_query(text.c_str(), reinterpret_cast<char *>(buffer.data()),
                                            capacity, timeoutMillis);
    if (size >= 0) {
        env->SetByteArrayRegion(reply, 0, size, buffer.data());
    }
    return size;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_previewAdjudicate(JNIEnv *env, jobject, jstring serverId,
                                                             jstring requestId, jbyteArray header,
                                                             jbyteArray reply) {
    if (serverId == nullptr || requestId == nullptr || reply == nullptr) return -105;
    const auto capacity = env->GetArrayLength(reply);
    if (capacity <= 0 || capacity > 1024 * 1024) return -105;
    std::vector<jbyte> buffer(capacity);
    const auto server = to_string(env, serverId);
    const auto request = to_string(env, requestId);
    if (server.empty() || request.empty()) return -105;
    jsize headerLength = 0;
    std::vector<uint8_t> headerBytes;
    if (header != nullptr) {
        headerLength = env->GetArrayLength(header);
        if (headerLength < 0 || headerLength > 64 * 1024) return -107;
        headerBytes.resize(headerLength > 0 ? headerLength : 1);
        if (headerLength > 0) {
            env->GetByteArrayRegion(header, 0, headerLength,
                                    reinterpret_cast<jbyte *>(headerBytes.data()));
            if (env->ExceptionCheck()) return -105;
        }
    }
    const auto size = floe_browser_preview_adjudicate(
        server.c_str(), request.c_str(),
        headerLength > 0 ? headerBytes.data() : nullptr, headerLength,
        reinterpret_cast<char *>(buffer.data()), capacity);
    if (size >= 0) {
        env->SetByteArrayRegion(reply, 0, size, buffer.data());
    }
    return size;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_previewReadChunk(JNIEnv *env, jobject, jstring serverId,
                                                            jstring requestId, jint offset,
                                                            jbyteArray target) {
    if (serverId == nullptr || requestId == nullptr || target == nullptr) return -105;
    const auto capacity = env->GetArrayLength(target);
    if (capacity <= 0 || capacity > 64 * 1024) return -105;
    if (offset < 0) return -105;
    std::vector<uint8_t> buffer(capacity);
    const auto server = to_string(env, serverId);
    const auto request = to_string(env, requestId);
    if (server.empty() || request.empty()) return -105;
    const auto size = floe_browser_preview_read_chunk(server.c_str(), request.c_str(), offset,
                                                      buffer.data(), capacity);
    if (size >= 0) {
        env->SetByteArrayRegion(target, 0, size, reinterpret_cast<const jbyte *>(buffer.data()));
    }
    return size;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_recoverHandoff(JNIEnv *env, jobject, jstring taskId,
                                                           jstring runId, jlong epoch) {
    const auto task = to_string(env, taskId);
    const auto run = to_string(env, runId);
    if (task.empty() || run.empty() || epoch <= 0) return -603;
    return floe_browser_recover_handoff(task.c_str(), run.c_str(), static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_BrowserNative_servicesLive(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_browser_services_live(static_cast<uint64_t>(epoch)) : -602;
}
