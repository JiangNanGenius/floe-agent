// SPDX-License-Identifier: MPL-2.0
//
// Device-history sync — trusted-host JNI adapters for the App-owned
// offers/export/import lane (`floe_device_history_*`). Additive translation
// unit inside the SAME floe_jni target; every prior wrapper file stays
// byte-identical. Discipline mirrors the reviewed run-output TU:
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * identities use bounded ASCII, cursor tokens use length-delimited
//    UTF-8, and archive bytes cross as bounded chunks;
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

#include <array>
#include <cstdint>
#include <string>

extern "C" {
int32_t floe_device_history_offers(uint64_t, char *, int32_t);
int64_t floe_device_history_export_open(uint64_t, const char *);
int64_t floe_device_history_export_version_open(uint64_t, const char *, int32_t);
int32_t floe_device_history_export_read(int64_t, int64_t, uint8_t *, int32_t);
int32_t floe_device_history_export_close(int64_t);
int32_t floe_device_history_receive_cursor(uint64_t, const char *, const char *, char *, int32_t);
int64_t floe_device_history_export_page_open(uint64_t, const char *, const uint8_t *, int32_t, int64_t);
int64_t floe_device_history_export_page_version_open(
    uint64_t, const char *, const uint8_t *, int32_t, int64_t, int32_t);
int32_t floe_device_history_export_page_info(int64_t, char *, int32_t);
int64_t floe_device_history_import_begin(uint64_t, const char *);
int64_t floe_device_history_import_page_begin(
    uint64_t, const char *, const char *, const uint8_t *, int32_t);
int32_t floe_device_history_import_write(int64_t, const uint8_t *, int32_t);
int32_t floe_device_history_import_commit(int64_t, char *, int32_t);
int32_t floe_device_history_import_version_commit(int64_t, int32_t, char *, int32_t);
int32_t floe_device_history_import_abort(int64_t);
int32_t floe_device_history_stats(char *, int32_t);
int64_t floe_device_history_attachment_open(uint64_t, const char *, const char *);
int32_t floe_device_history_attachments_pending(uint64_t, const char *, char *, int32_t);
int32_t floe_device_history_attachment_restore_commit(
    int64_t, const char *, const char *, const char *, char *, int32_t);
}

namespace {

constexpr int32_t status_shape = -105;
constexpr int32_t status_too_small = -106;
constexpr int32_t status_not_installed = -801;
constexpr int32_t reply_limit = 262144;  // 256 KiB whole-page offer/receipt budget
constexpr int32_t chunk_limit = 65536;
constexpr int32_t uuid_limit = 64;
constexpr int32_t peer_id_limit = 128;
constexpr int32_t cursor_limit = 160;

struct CursorBytes {
    std::array<uint8_t, cursor_limit> bytes{};
    int32_t size = 0;

    const uint8_t *data() const { return size == 0 ? nullptr : bytes.data(); }
};

bool optional_cursor_arg(JNIEnv *env, jbyteArray input, CursorBytes &out) {
    if (input == nullptr) return true;
    const jsize size = env->GetArrayLength(input);
    if (size <= 0 || size > cursor_limit) return false;
    env->GetByteArrayRegion(input, 0, size, reinterpret_cast<jbyte *>(out.bytes.data()));
    if (env->ExceptionCheck()) return false;
    out.size = size;
    return true;
}

bool ascii_only(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Swift validates the admitted task UUID and the peer identity.
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

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportVersionOpen(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jint version) {
    if (epoch <= 0) return status_not_installed;
    if (version != 1 && version != 2) return status_shape;
    std::string conversation;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation)) return status_shape;
    return floe_device_history_export_version_open(
        static_cast<uint64_t>(epoch), conversation.c_str(), version);
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

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_receiveCursor(
    JNIEnv *env, jobject, jlong epoch, jstring peerID, jstring conversationID, jbyteArray reply) {
    if (epoch <= 0) return status_not_installed;
    std::string peer, conversation;
    if (!ascii_arg(env, peerID, peer_id_limit, &peer) ||
        !ascii_arg(env, conversationID, uuid_limit, &conversation)) return status_shape;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_history_receive_cursor(
            static_cast<uint64_t>(epoch), peer.c_str(), conversation.c_str(), buffer, capacity);
    });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportPageOpen(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jbyteArray after, jlong through) {
    if (epoch <= 0) return status_not_installed;
    if (through < -1) return status_shape;
    std::string conversation;
    CursorBytes after_bytes;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation) ||
        !optional_cursor_arg(env, after, after_bytes)) return status_shape;
    return floe_device_history_export_page_open(
        static_cast<uint64_t>(epoch), conversation.c_str(),
        after_bytes.data(), after_bytes.size, through);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportPageVersionOpen(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jbyteArray after,
    jlong through, jint version) {
    if (epoch <= 0) return status_not_installed;
    if (through < -1 || (version != 1 && version != 2)) return status_shape;
    std::string conversation;
    CursorBytes cursor;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation) ||
        !optional_cursor_arg(env, after, cursor)) return status_shape;
    return floe_device_history_export_page_version_open(
        static_cast<uint64_t>(epoch), conversation.c_str(), cursor.data(), cursor.size, through, version);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_attachmentOpen(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jstring attachmentID) {
    if (epoch <= 0) return status_not_installed;
    std::string conversation, attachment;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation) ||
        !ascii_arg(env, attachmentID, uuid_limit, &attachment)) return status_shape;
    return floe_device_history_attachment_open(
        static_cast<uint64_t>(epoch), conversation.c_str(), attachment.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_attachmentsPending(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jbyteArray reply) {
    if (epoch <= 0) return status_not_installed;
    std::string conversation;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation)) return status_shape;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_history_attachments_pending(
            static_cast<uint64_t>(epoch), conversation.c_str(), buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_attachmentRestoreCommit(
    JNIEnv *env, jobject, jlong ticket, jstring attachmentID, jstring messageID,
    jstring sha256, jbyteArray reply) {
    if (ticket <= 0) return status_shape;
    std::string attachment, message, digest;
    if (!ascii_arg(env, attachmentID, uuid_limit, &attachment) ||
        !ascii_arg(env, messageID, uuid_limit, &message) ||
        !ascii_arg(env, sha256, 64, &digest) || digest.size() != 64) return status_shape;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_history_attachment_restore_commit(
            ticket, attachment.c_str(), message.c_str(), digest.c_str(), buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_exportPageInfo(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return status_shape;
    return reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_device_history_export_page_info(ticket, buffer, capacity);
    });
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

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_DeviceHistoryNative_importPageBegin(
    JNIEnv *env, jobject, jlong epoch, jstring conversationID, jstring peerID, jbyteArray nextCursor) {
    if (epoch <= 0) return status_not_installed;
    std::string conversation, peer;
    CursorBytes cursor;
    if (!ascii_arg(env, conversationID, uuid_limit, &conversation) ||
        !ascii_arg(env, peerID, peer_id_limit, &peer) ||
        !optional_cursor_arg(env, nextCursor, cursor)) return status_shape;
    return floe_device_history_import_page_begin(
        static_cast<uint64_t>(epoch), conversation.c_str(), peer.c_str(), cursor.data(), cursor.size);
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
    const jsize size = env->GetArrayLength(data);
    if (offset > size || length > size - offset) {
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
Java_com_floe_android_bridge_DeviceHistoryNative_importVersionCommit(
    JNIEnv *env, jobject, jlong ticket, jint expectedVersion, jbyteArray reply) {
    if (ticket <= 0 || (expectedVersion != 1 && expectedVersion != 2)) return status_shape;
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_history_import_version_commit(ticket, expectedVersion, buffer, capacity);
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
