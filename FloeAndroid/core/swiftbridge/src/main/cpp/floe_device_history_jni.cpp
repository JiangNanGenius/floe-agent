// SPDX-License-Identifier: MPL-2.0
//
// Device-history sync — trusted-host JNI adapters for the App-owned
// offers/export/import lane (`floe_device_history_*`). Additive translation
// unit inside the SAME floe_jni target; every prior wrapper file stays
// byte-identical. Discipline mirrors the reviewed run-output TU:
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * identity arguments are strict-ASCII validated canonical UUIDs (the
//    only strings that ever cross; archive bytes cross as bounded chunks);
//  * typed negative statuses pass through unchanged — never a silent null
//    and never a title/path/byte inside an error text;
//  * replies copy into the caller-provided byte array; import chunks copy
//    OUT of the caller array through one bounded 64 KiB scratch — the Java
//    array contents never escape the frame;
//  * the epoch is the App's readback of the ACCEPTED native root — Swift
//    re-validates it against the live generation and never trusts it.
//
// Byte direction (the ONLY two binary channels): exportRead streams <= 64 KiB
// pages out of the owned session; importWrite pushes <= 64 KiB chunks into
// the bounded accumulator. Archive payloads reach 32 MiB WITHOUT ever
// crossing the 64 KiB generic bridge page.
#include <jni.h>

#include <cstdint>
#include <string>

extern "C" {
int32_t floe_device_history_offers(uint64_t, char *, int32_t);
int64_t floe_device_history_export_open(uint64_t, const char *);
int32_t floe_device_history_export_read(int64_t, int64_t, uint8_t *, int32_t);
int32_t floe_device_history_export_close(int64_t);
int64_t floe_device_history_import_begin(uint64_t, const char *);
int32_t floe_device_history_import_write(int64_t, const uint8_t *, int32_t);
int32_t floe_device_history_import_commit(int64_t, char *, int32_t);
int32_t floe_device_history_import_abort(int64_t);
int32_t floe_device_history_stats(char *, int32_t);
}

namespace {

constexpr int32_t status_shape = -105;
constexpr int32_t status_too_small = -106;
constexpr int32_t status_not_installed = -801;
constexpr int32_t reply_limit = 262144;  // 256 KiB whole-page offer/receipt budget
constexpr int32_t chunk_limit = 65536;
constexpr int32_t uuid_limit = 64;

bool ascii_only(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Required ASCII identity token (canonical UUID spelling only).
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

// Executes a reply-producing native call against the caller array. The whole
// JSON reply only ever crosses when it fits the caller capacity (minus NUL)
// — Swift budgets the page the same way.
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
Java_com_floe_android_bridge_DeviceHistoryNative_offers(
    JNIEnv *env, jobject, jlong epoch, jbyteArray reply) {
    if (epoch <= 0) return status_not_installed;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_history_offers(static_cast<uint64_t>(epoch), buffer, capacity);
    });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportOpen(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID) {
    if (epoch <= 0) return status_not_installed;
    std::string conversation_value;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation_value)) return status_shape;
    return floe_device_history_export_open(static_cast<uint64_t>(epoch),
                                           conversation_value.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportRead(
    JNIEnv *env, jobject, jlong ticket, jlong offset, jbyteArray target) {
    if (ticket <= 0 || offset < 0 || target == nullptr) return status_shape;
    const jsize capacity = env->GetArrayLength(target);
    if (capacity <= 0 || capacity > chunk_limit) return status_shape;
    jbyte *elements = env->GetByteArrayElements(target, nullptr);
    if (elements == nullptr) return status_shape;
    const jint copied = floe_device_history_export_read(
        ticket, offset, reinterpret_cast<uint8_t *>(elements), capacity);
    env->ReleaseByteArrayElements(target, elements, copied > 0 ? 0 : JNI_ABORT);
    return env->ExceptionCheck() ? status_shape : copied;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportClose(
    JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_device_history_export_close(ticket) : status_shape;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_importBegin(
    JNIEnv *env, jobject, jlong epoch, jstring expectedConversationID) {
    if (epoch <= 0) return status_not_installed;
    std::string conversation_value;
    if (!ascii_arg(env, expectedConversationID, uuid_limit, &conversation_value)) {
        return status_shape;
    }
    return floe_device_history_import_begin(static_cast<uint64_t>(epoch),
                                            conversation_value.c_str());
}

// One bounded chunk of the REAL source stream, copied out of the caller
// array through a bounded scratch. The Java array contents never escape the
// frame and the aggregate stays under the 32 MiB portable ceiling (Swift
// enforces the ceiling before the append commits).
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_importWrite(
    JNIEnv *env, jobject, jlong ticket, jbyteArray data, jint offset, jint length) {
    if (ticket <= 0 || data == nullptr || offset < 0 || length <= 0 ||
        length > chunk_limit) {
        return status_shape;
    }
    if (static_cast<jint>(env->GetArrayLength(data)) < offset + length) {
        return status_shape;
    }
    jbyte scratch[chunk_limit];
    env->GetByteArrayRegion(data, offset, length, scratch);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return status_shape; }
    return floe_device_history_import_write(
        ticket, reinterpret_cast<const uint8_t *>(scratch), length);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_importCommit(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return status_shape;
    return reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_device_history_import_commit(ticket, buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_importAbort(
    JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_device_history_import_abort(ticket) : status_shape;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_stats(
    JNIEnv *env, jobject, jbyteArray reply) {
    return reply_call(env, reply, [](char *buffer, int32_t capacity) {
        return floe_device_history_stats(buffer, capacity);
    });
}
