// SPDX-License-Identifier: MPL-2.0
//
// D04 App consumer (job-6f953da44de048d0) — trusted-host JNI adapters for
// the owned run-output reader/egress lane (`floe_run_output_*`). Additive
// translation unit inside the SAME floe_jni target; every prior wrapper
// file stays byte-identical. Discipline mirrors the reviewed
// attachment-staging / workspace-source-host TUs: no global refs, no
// AttachCurrentThread, no Swift -> JVM callback; strict UTF-16 -> UTF-8
// conversion (no CESU-8, unpaired surrogates rejected); ASCII-validated
// identity tokens; typed negative statuses are returned unchanged; replies
// copy into the caller-provided byte array and never escape as a fresh
// unbounded allocation. The epoch is the App's readback of the ACCEPTED
// native root — Swift re-validates it against the live generation and
// never trusts this argument as authority.
#include <jni.h>
#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>
extern "C" {
int32_t floe_run_output_list(uint64_t, const char *, const char *, char *, int32_t);
int64_t floe_run_output_open(uint64_t, const char *, const char *, const char *);
int32_t floe_run_output_info(int64_t, char *, int32_t);
int32_t floe_run_output_read(int64_t, int64_t, uint8_t *, int32_t);
int32_t floe_run_output_close(int64_t);
int32_t floe_run_output_stats(char *, int32_t);
}
namespace {
constexpr int32_t status_shape = -105;
constexpr int32_t status_too_small = -106;
constexpr int32_t reply_limit = 32768;
constexpr int32_t chunk_limit = 65536;
constexpr int32_t uuid_limit = 64;
constexpr int32_t digest_limit = 80;   // outputID: 64 hex + margin

bool ascii_only(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Required ASCII identity token (canonical UUID / 64-hex output id).
bool ascii_arg(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    if (source == nullptr || maximum <= 0) return false;
    const jsize length = env->GetStringUTFLength(source);
    if (length < 0 || length > maximum) return false;
    const char *chars = env->GetStringUTFChars(source, nullptr);
    if (chars == nullptr) return false;
    out->assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(source, chars);
    if (out->empty()) return false;
    if (env->ExceptionCheck()) { env->ExceptionClear(); return false; }
    return ascii_only(*out);
}

// Executes a reply-producing native call against the caller array.
template <typename Call>
jint reply_call(JNIEnv *env, jbyteArray reply, Call call) {
    if (reply == nullptr) return status_shape;
    const jsize capacity = env->GetArrayLength(reply);
    if (capacity <= 0 || capacity > reply_limit) return status_too_small;
    jbyte *elements = env->GetByteArrayElements(reply, nullptr);
    if (elements == nullptr) return status_shape;
    const jint size = call(reinterpret_cast<char *>(elements), capacity);
    env->ReleaseByteArrayElements(reply, elements, size >= 0 ? 0 : JNI_ABORT);
    if (env->ExceptionCheck()) return status_shape;
    return size;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_RunOutputNative_list(
    JNIEnv *env, jobject, jlong epoch, jstring conversation, jstring run, jbyteArray reply) {
    if (epoch <= 0) return -701;
    std::string conversation_value, run_value;
    if (!ascii_arg(env, conversation, uuid_limit, &conversation_value) ||
        !ascii_arg(env, run, uuid_limit, &run_value)) return status_shape;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_run_output_list(static_cast<uint64_t>(epoch),
                                    conversation_value.c_str(), run_value.c_str(),
                                    buffer, capacity);
    });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_RunOutputNative_open(
    JNIEnv *env, jobject, jlong epoch, jstring conversation, jstring run, jstring output) {
    if (epoch <= 0) return -701;
    std::string conversation_value, run_value, output_value;
    if (!ascii_arg(env, conversation, uuid_limit, &conversation_value) ||
        !ascii_arg(env, run, uuid_limit, &run_value) ||
        !ascii_arg(env, output, digest_limit, &output_value)) return status_shape;
    return floe_run_output_open(static_cast<uint64_t>(epoch),
                                conversation_value.c_str(), run_value.c_str(),
                                output_value.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_RunOutputNative_info(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return status_shape;
    return reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_run_output_info(ticket, buffer, capacity);
    });
}

// Copies up to target.size (<= 64 KiB) snapshot bytes at offset into the
// caller array. 0 is a clean EOF; negative is a typed status. Bytes never
// cross this boundary as JSON/base64 and the whole file is never material.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_RunOutputNative_read(
    JNIEnv *env, jobject, jlong ticket, jlong offset, jbyteArray target) {
    if (ticket <= 0 || offset < 0 || target == nullptr) return status_shape;
    const jsize capacity = env->GetArrayLength(target);
    if (capacity <= 0 || capacity > chunk_limit) return status_shape;
    jbyte *elements = env->GetByteArrayElements(target, nullptr);
    if (elements == nullptr) return status_shape;
    const jint copied = floe_run_output_read(ticket, offset,
                                             reinterpret_cast<uint8_t *>(elements), capacity);
    env->ReleaseByteArrayElements(target, elements, copied > 0 ? 0 : JNI_ABORT);
    return env->ExceptionCheck() ? status_shape : copied;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_RunOutputNative_close(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_run_output_close(ticket) : status_shape;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_RunOutputNative_stats(JNIEnv *env, jobject, jbyteArray reply) {
    return reply_call(env, reply, [](char *buffer, int32_t capacity) {
        return floe_run_output_stats(buffer, capacity);
    });
}
