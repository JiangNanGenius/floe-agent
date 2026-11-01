// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media render ticket trusted-host JNI adapters
// (job-b72b2978320e484e). Additive translation unit inside the SAME floe_jni
// target; every prior wrapper file stays byte-identical.
//
// The bounded pump ABI maps one-to-one onto the reviewed `OfficeAIHostMailbox`
// discipline, but tickets are string-keyed and carry a required claim token:
//   bindEpoch / claim / describe / isLive / shouldStop / heartbeat / complete /
//   close / stats / rootStop / drainPending
//
// All semantics (lease/root/digest/revision verification, exactly-once
// settlement, claim-token ownership and the two-phase root drain) live in
// FloeAndroidCore `G09R2MediaRenderHostMailbox`. This file only marshals
// bounded values:
//   * ticket ids / claim tokens must be short printable ASCII tokens;
//   * claimed envelopes and descriptors are <= 64 KiB, replies <= 1 MiB;
//   * a too-small reply buffer is refused, never truncated;
//   * typed negative statuses pass through unchanged.
#include <jni.h>
#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>

extern "C" {
int32_t floe_media_render_bind(uint64_t);
int32_t floe_media_render_consumer_heartbeat(uint64_t);
int32_t floe_media_render_consumer_stop(uint64_t);
int32_t floe_media_render_claim(int32_t, char *, int32_t);
int32_t floe_media_render_describe(const char *, char *, int32_t);
int32_t floe_media_render_is_live(const char *);
int32_t floe_media_render_should_stop(const char *, const char *);
int32_t floe_media_render_heartbeat(const char *, const char *);
int32_t floe_media_render_complete(const char *, const char *, const uint8_t *, int32_t);
int32_t floe_media_render_close(const char *, const char *);
int32_t floe_media_render_stats(char *, int32_t);
int32_t floe_media_render_root_stop(uint64_t);
int32_t floe_media_render_drain_pending(uint64_t);
int32_t floe_media_snapshot_acquire(uint64_t, const char *, char *, int32_t);
int32_t floe_media_snapshot_release(uint64_t, const char *);
int32_t floe_media_task_binding_select(int64_t, const char *, const char *,
                                       char *, int32_t);
int32_t floe_media_task_binding_revoke(int64_t, const char *, const char *,
                                       char *, int32_t);
int32_t floe_media_project_tool_issue_grant(int64_t, const char *, const char *,
                                            char *, int32_t);
}

namespace {
constexpr int32_t descriptor_limit = 64 * 1024;  // G09R2CreativeLimits.renderDescriptorBytes
constexpr int32_t reply_limit = 1024 * 1024;     // G09R2CreativeLimits.renderReplyBytes
constexpr int32_t stats_limit = 4096;
constexpr jsize token_limit = 128;

jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte *>(data));
    }
    return env->ExceptionCheck() ? nullptr : result;
}

// Strict printable-ASCII token copy. A non-ASCII / embedded-NUL value is
// refused instead of being reinterpreted; ids are never generated from
// untrusted bytes.
bool copy_token(JNIEnv *env, jstring value, std::string *out) {
    if (!value || !out) return false;
    const jsize length = env->GetStringUTFLength(value);
    if (length <= 0 || length > token_limit) return false;
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return false;
    bool ok = true;
    for (jsize index = 0; index < length; index++) {
        const auto byte = static_cast<unsigned char>(chars[index]);
        if (byte < 0x21 || byte > 0x7e) { ok = false; break; }
    }
    if (ok) out->assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(value, chars);
    return ok && !env->ExceptionCheck();
}

constexpr size_t media_owner_token_limit = 64;
constexpr size_t media_authority_request_limit = 16 * 1024;
constexpr size_t media_binding_reply_limit = 8 * 1024;
constexpr size_t media_grant_reply_limit = 8 * 1024;
constexpr size_t media_revoke_reply_limit = 1024;

bool FloeValidMediaUtf16(const jchar *chars, jsize length) {
    if (!chars || length < 0) return false;
    for (jsize index = 0; index < length; ++index) {
        const uint32_t unit = static_cast<uint32_t>(chars[index]);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (index + 1 >= length) return false;
            const uint32_t low = static_cast<uint32_t>(chars[++index]);
            if (low < 0xDC00 || low > 0xDFFF) return false;
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
            return false;
        }
    }
    return true;
}

bool FloeMediaUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
                              std::string &output) {
    output.clear();
    if (!value) return false;
    const jsize length = env->GetStringLength(value);
    if (length < 0 || static_cast<size_t>(length) > maximumBytes) return false;
    const jchar *chars = env->GetStringChars(value, nullptr);
    if (!chars) return false;
    bool ok = false;
    try {
        if (FloeValidMediaUtf16(chars, length)) {
            std::u16string utf16(reinterpret_cast<const char16_t *>(chars),
                                 static_cast<size_t>(length));
            std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
            output = converter.to_bytes(utf16);
            ok = converter.converted() == utf16.size();
        }
    } catch (...) {
        ok = false;
    }
    env->ReleaseStringChars(value, chars);
    if (!ok || output.size() > maximumBytes ||
        output.find('\0') != std::string::npos) {
        output.clear();
        return false;
    }
    return true;
}

jstring FloeMediaJStringFromUtf8(JNIEnv *env, const std::string &value) {
    try {
        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
        const std::u16string utf16 = converter.from_bytes(value);
        if (converter.converted() != value.size()) return nullptr;
        return env->NewString(
            reinterpret_cast<const jchar *>(utf16.data()),
            static_cast<jsize>(utf16.size()));
    } catch (...) {
        return nullptr;
    }
}

void FloeThrowMediaToolStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/MediaToolAuthorityNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                return;
            }
        } else {
            env->DeleteLocalRef(exceptionClass);
        }
    }
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "media_tool_authority_failure");
        env->DeleteLocalRef(fallback);
    }
}

bool FloeReadMediaOwnerToken(JNIEnv *env, jstring value, std::string &output) {
    if (!FloeMediaUtf8FromJString(env, value, media_owner_token_limit, output)) {
        return false;
    }
    if (output.size() < 8 || output.size() > media_owner_token_limit) return false;
    for (char c : output) {
        const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex) return false;
    }
    return true;
}

jstring FloeRunMediaAuthorityJson(
    JNIEnv *env, jlong ownerEpoch, jstring ownerToken, jstring requestJSON,
    size_t replyLimit,
    int32_t (*function)(int64_t, const char *, const char *, char *, int32_t)) {
    if (ownerEpoch <= 0) {
        FloeThrowMediaToolStatus(env, -121);
        return nullptr;
    }
    std::string owner;
    std::string request;
    if (!FloeReadMediaOwnerToken(env, ownerToken, owner) ||
        !FloeMediaUtf8FromJString(env, requestJSON, media_authority_request_limit,
                                  request) ||
        request.empty()) {
        FloeThrowMediaToolStatus(env, -123);
        return nullptr;
    }
    std::vector<char> output(replyLimit, 0);
    const int32_t result = function(
        static_cast<int64_t>(ownerEpoch), owner.c_str(), request.c_str(),
        output.data(), static_cast<int32_t>(output.size()));
    if (result != 0) {
        FloeThrowMediaToolStatus(env, result);
        return nullptr;
    }
    output.back() = 0;
    jstring value = FloeMediaJStringFromUtf8(env, std::string(output.data()));
    if (!value) {
        FloeThrowMediaToolStatus(env, -123);
    }
    return value;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_media_render_bind(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_consumerHeartbeat(JNIEnv *, jobject,
                                                                 jlong epoch) {
    return epoch > 0
        ? floe_media_render_consumer_heartbeat(static_cast<uint64_t>(epoch))
        : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_consumerStop(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0
        ? floe_media_render_consumer_stop(static_cast<uint64_t>(epoch))
        : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaRenderNative_claim(JNIEnv *env, jobject, jint timeout) {
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto clamped = timeout < 0 ? 0 : (timeout > 5000 ? 5000 : timeout);
    const auto size = floe_media_render_claim(
        clamped, reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    if (size == 0) return nullptr;
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaRenderNative_describe(JNIEnv *env, jobject,
                                                        jstring ticketID) {
    std::string ticket;
    if (!copy_token(env, ticketID, &ticket)) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_media_render_describe(
        ticket.c_str(), reinterpret_cast<char *>(value.data()),
        static_cast<int32_t>(value.size()));
    if (size <= 0) return nullptr;
    return to_bytes(env, value.data(), size, descriptor_limit);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_isLive(JNIEnv *env, jobject,
                                                      jstring ticketID) {
    std::string ticket;
    if (!copy_token(env, ticketID, &ticket)) return 0;
    return floe_media_render_is_live(ticket.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_shouldStop(JNIEnv *env, jobject,
                                                          jstring ticketID,
                                                          jstring claimToken) {
    std::string ticket;
    std::string token;
    if (!copy_token(env, ticketID, &ticket) || !copy_token(env, claimToken, &token)) {
        return 1;
    }
    return floe_media_render_should_stop(ticket.c_str(), token.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_heartbeat(JNIEnv *env, jobject,
                                                         jstring ticketID,
                                                         jstring claimToken) {
    std::string ticket;
    std::string token;
    if (!copy_token(env, ticketID, &ticket) || !copy_token(env, claimToken, &token)) {
        return -105;
    }
    return floe_media_render_heartbeat(ticket.c_str(), token.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_complete(JNIEnv *env, jobject,
                                                        jstring ticketID,
                                                        jstring claimToken,
                                                        jbyteArray body) {
    std::string ticket;
    std::string token;
    if (!copy_token(env, ticketID, &ticket) || !copy_token(env, claimToken, &token)) {
        return -105;
    }
    if (!body) return -107;
    const auto size = env->GetArrayLength(body);
    if (size < 0 || size > reply_limit) return -107;
    std::vector<uint8_t> value(size > 0 ? size : 1);
    if (size) env->GetByteArrayRegion(body, 0, size,
                                      reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_media_render_complete(ticket.c_str(), token.c_str(),
                                      value.data(), size);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_close(JNIEnv *env, jobject,
                                                     jstring ticketID,
                                                     jstring claimToken) {
    std::string ticket;
    std::string token;
    if (!copy_token(env, ticketID, &ticket) || !copy_token(env, claimToken, &token)) {
        return -105;
    }
    return floe_media_render_close(ticket.c_str(), token.c_str());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaRenderNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(stats_limit + 1);
    const auto size = floe_media_render_stats(
        reinterpret_cast<char *>(value.data()), static_cast<int32_t>(value.size()));
    if (size <= 0) return nullptr;
    return to_bytes(env, value.data(), size, stats_limit);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_rootStop(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_media_render_root_stop(static_cast<uint64_t>(epoch)) : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaRenderNative_drainPending(JNIEnv *, jobject,
                                                            jlong epoch) {
    return epoch > 0 ? floe_media_render_drain_pending(static_cast<uint64_t>(epoch)) : 0;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_MediaSnapshotNative_acquire(JNIEnv *env, jobject,
                                                         jlong epoch,
                                                         jbyteArray request) {
    if (epoch <= 0 || !request) return nullptr;
    const auto size = env->GetArrayLength(request);
    if (size <= 0 || size > 16 * 1024) return nullptr;
    std::vector<uint8_t> value(static_cast<size_t>(size) + 1, 0);
    env->GetByteArrayRegion(request, 0, size,
                            reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return nullptr;
    std::vector<uint8_t> reply(8192);
    const auto written = floe_media_snapshot_acquire(
        static_cast<uint64_t>(epoch), reinterpret_cast<const char *>(value.data()),
        reinterpret_cast<char *>(reply.data()),
        static_cast<int32_t>(reply.size()));
    if (written <= 0) return nullptr;
    return to_bytes(env, reply.data(), written, 8192);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MediaSnapshotNative_release(JNIEnv *env, jobject,
                                                         jlong epoch,
                                                         jbyteArray lease) {
    if (epoch <= 0 || !lease) return -105;
    const auto size = env->GetArrayLength(lease);
    if (size <= 0 || size > 16 * 1024) return -105;
    std::vector<uint8_t> value(static_cast<size_t>(size) + 1, 0);
    env->GetByteArrayRegion(lease, 0, size,
                            reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_media_snapshot_release(static_cast<uint64_t>(epoch),
                                       reinterpret_cast<const char *>(value.data()));
}


extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_MediaRenderNative_selectMediaTaskBinding(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken,
    jstring requestJSON) {
    try {
        return FloeRunMediaAuthorityJson(
            env, ownerEpoch, ownerToken, requestJSON, media_binding_reply_limit,
            floe_media_task_binding_select);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowMediaToolStatus(env, -123);
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_MediaRenderNative_revokeMediaTaskBinding(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken,
    jstring requestJSON) {
    try {
        return FloeRunMediaAuthorityJson(
            env, ownerEpoch, ownerToken, requestJSON, media_revoke_reply_limit,
            floe_media_task_binding_revoke);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowMediaToolStatus(env, -123);
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_MediaRenderNative_issueMediaProjectGrant(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken,
    jstring requestJSON) {
    try {
        return FloeRunMediaAuthorityJson(
            env, ownerEpoch, ownerToken, requestJSON, media_grant_reply_limit,
            floe_media_project_tool_issue_grant);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowMediaToolStatus(env, -123);
        return nullptr;
    }
}
