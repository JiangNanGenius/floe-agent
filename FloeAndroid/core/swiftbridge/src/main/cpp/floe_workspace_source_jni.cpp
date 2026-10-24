// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>
extern "C" {
int32_t floe_g04_source_bind(uint64_t);
int64_t floe_g04_source_next(int32_t);
int32_t floe_g04_source_describe(int64_t, char *, int32_t);
int32_t floe_g04_source_payload_length(int64_t);
int32_t floe_g04_source_take_payload(int64_t, uint8_t *, int32_t);
int32_t floe_g04_source_is_live(int64_t);
int32_t floe_g04_source_should_stop(int64_t);
int32_t floe_g04_source_complete(int64_t, int32_t, const uint8_t *, int32_t);
int32_t floe_g04_source_close(uint64_t);
int32_t floe_g04_source_stats(char *, int32_t);
// G04-R1 provider SOURCE HOST (trusted App->native ladder; additive -5xx
// space owned by G04WorkspaceSourceHostAPI.swift).
int64_t floe_g04_source_host_stage_open(uint64_t, const char *, const char *, const char *,
                                        const char *, const char *, const char *, const char *);
int32_t floe_g04_source_host_stage_write(int64_t, const uint8_t *, int32_t);
int32_t floe_g04_source_host_stage_finish(int64_t, char *, int32_t);
int32_t floe_g04_source_host_stage_abort(int64_t);
int64_t floe_g04_source_host_egress_open(uint64_t, const char *, const char *, const char *,
                                         const char *, const char *);
int32_t floe_g04_source_host_egress_info(int64_t, char *, int32_t);
int32_t floe_g04_source_host_egress_read(int64_t, int64_t, uint8_t *, int32_t);
int32_t floe_g04_source_host_egress_verify(int64_t, int64_t, char *, int32_t);
int32_t floe_g04_source_host_egress_close(int64_t);
int32_t floe_g04_source_host_save_prepare(int64_t, int64_t, const char *, char *, int32_t);
int32_t floe_g04_source_host_save_claim(int64_t, int64_t, char *, int32_t);
int32_t floe_g04_source_host_save_permit(int64_t, const char *);
int32_t floe_g04_source_host_save_settle(int64_t, int64_t, char *, int32_t);
int32_t floe_g04_source_host_save_retain(int64_t, char *, int32_t);
int32_t floe_g04_source_host_source_page(uint64_t, const char *, const char *, int32_t,
                                         char *, int32_t);
int32_t floe_g04_source_host_source_lookup(uint64_t, const char *, const char *, char *, int32_t);
int32_t floe_g04_source_host_recovery_page(uint64_t, const char *, const char *, int32_t,
                                           char *, int32_t);
int32_t floe_g04_source_host_reconcile_run(uint64_t, const char *, char *, int32_t);
int32_t floe_g04_source_host_reconcile_staged(uint64_t, const char *, const char *, const char *,
                                              int64_t, char *, int32_t);
int32_t floe_g04_source_host_stats(char *, int32_t);
}
namespace {
constexpr int32_t document_limit = 4 * 1024 * 1024;
constexpr int32_t descriptor_limit = 2048;
constexpr int32_t stats_limit = 4096;
jbyteArray to_bytes(JNIEnv *env, const uint8_t *data, int32_t size, int32_t limit) {
    if (size < 0 || size > limit) return nullptr;
    auto result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return env->ExceptionCheck() ? nullptr : result;
}
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_bindEpoch(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_g04_source_bind(static_cast<uint64_t>(epoch)) : -105;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_next(JNIEnv *, jobject, jint timeout) {
    return floe_g04_source_next(timeout < 0 ? 0 : (timeout > 1000 ? 1000 : timeout));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_describe(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    std::vector<uint8_t> value(descriptor_limit + 1);
    const auto size = floe_g04_source_describe(claim, reinterpret_cast<char *>(value.data()), value.size());
    return to_bytes(env, value.data(), size, descriptor_limit);
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_payload(JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const auto size = floe_g04_source_payload_length(claim);
    if (size < 0 || size > document_limit) return nullptr;
    std::vector<uint8_t> value(size > 0 ? size : 1);
    const auto actual = floe_g04_source_take_payload(claim, value.data(), size);
    return actual == size ? to_bytes(env, value.data(), actual, document_limit) : nullptr;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_isLive(JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_g04_source_is_live(claim) : 0;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_shouldStop(JNIEnv *, jobject, jlong claim) {
    return claim > 0 ? floe_g04_source_should_stop(claim) : 1;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_complete(JNIEnv *env, jobject, jlong claim, jint status, jbyteArray body) {
    if (claim <= 0 || !body || (status != 0 && status != 1)) return -105;
    const auto size = env->GetArrayLength(body);
    if (size < 0 || size > (status == 0 ? document_limit : 256)) return -106;
    std::vector<uint8_t> value(size);
    if (size) env->GetByteArrayRegion(body, 0, size, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    return floe_g04_source_complete(claim, status, value.data(), size);
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_close(JNIEnv *, jobject, jlong epoch) {
    return epoch > 0 ? floe_g04_source_close(static_cast<uint64_t>(epoch)) : -105;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_stats(JNIEnv *env, jobject) {
    std::vector<uint8_t> value(stats_limit + 1);
    const auto size = floe_g04_source_stats(reinterpret_cast<char *>(value.data()), value.size());
    return to_bytes(env, value.data(), size, stats_limit);
}

// ---------------------------------------------------------------------------
// G04-R1 provider SOURCE HOST adapters (additive). Discipline mirrors the
// reviewed attachment-staging TU: no global refs, no AttachCurrentThread, no
// Swift -> JVM callback; strict UTF-16 -> UTF-8 for path/reference arguments
// (no CESU-8); ASCII-validated identity tokens; typed negative statuses are
// returned unchanged; replies are copied into the caller-provided byte array
// (mode 0 commit) and never escape as a fresh allocation of unbounded size.
// ---------------------------------------------------------------------------
namespace {
constexpr int32_t host_status_shape = -105;
constexpr int32_t host_status_too_small = -106;
constexpr int32_t host_reply_limit = 32768;
constexpr int32_t host_chunk_limit = 65536;

bool host_ascii(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Reads a required ASCII token (identity UUIDs, purpose/mode/receipt tokens).
// Returns false on null/empty/non-ASCII/oversize.
bool host_ascii_arg(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    if (source == nullptr || maximum <= 0) return false;
    const jsize length = env->GetStringUTFLength(source);
    if (length < 0 || length > maximum) return false;
    const char *chars = env->GetStringUTFChars(source, nullptr);
    if (chars == nullptr) return false;
    out->assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(source, chars);
    if (out->empty()) return false;
    if (env->ExceptionCheck()) { env->ExceptionClear(); return false; }
    return host_ascii(*out);
}

// Reads a required possibly-Unicode argument (logicalPath / content
// reference). Unpaired surrogates are rejected instead of a partially
// converted prefix.
bool host_utf8_arg(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    if (source == nullptr || maximum <= 0) return false;
    const jsize length = env->GetStringLength(source);
    // UTF-8 byte count cannot be smaller than its UTF-16 unit count. Bound
    // the Java copy before allocating conversion buffers.
    if (length < 0 || length > maximum) return false;
    const jchar *units = env->GetStringChars(source, nullptr);
    if (units == nullptr) return false;
    bool valid = true;
    for (jsize index = 0; index < length; ++index) {
        const uint32_t unit = static_cast<uint32_t>(units[index]);
        // The downstream C ABI uses NUL-terminated strings: never truncate
        // a caller identity/path at an embedded Java NUL.
        if (unit == 0) { valid = false; break; }
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (index + 1 >= length) { valid = false; break; }
            const uint32_t low = static_cast<uint32_t>(units[++index]);
            if (low < 0xDC00 || low > 0xDFFF) { valid = false; break; }
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
            valid = false;
            break;
        }
    }
    std::u16string wide;
    if (valid) wide.assign(reinterpret_cast<const char16_t *>(units), static_cast<size_t>(length));
    env->ReleaseStringChars(source, reinterpret_cast<const jchar *>(units));
    if (!valid) return false;
    try {
        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
        std::string converted = converter.to_bytes(wide);
        if (converted.empty() || converted.size() > static_cast<size_t>(maximum)) return false;
        out->swap(converted);
        return true;
    } catch (const std::exception &) {
        return false;
    }
}

// Optional argument: null jstring maps to "" (the Swift layer treats "" as
// absent through G04HostC.optionalString).
// Optional ASCII argument: null/empty means ABSENT (the Swift layer treats
// "" as absent). A present-but-invalid value is a hard -105 refusal — it is
// never silently replaced by a marker or dropped, so a foreign documentID or
// sourceID can never land in a staged session's identity.
bool host_optional_ascii(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    out->clear();
    if (source == nullptr) return true;
    if (env->GetStringUTFLength(source) == 0) return true;
    return host_ascii_arg(env, source, maximum, out);
}

// Executes a reply-producing native call against the caller array.
template <typename Call>
jint host_reply_call(JNIEnv *env, jbyteArray reply, Call call) {
    if (reply == nullptr) return host_status_shape;
    const jsize capacity = env->GetArrayLength(reply);
    if (capacity <= 0 || capacity > host_reply_limit) return host_status_too_small;
    jbyte *elements = env->GetByteArrayElements(reply, nullptr);
    if (elements == nullptr) return host_status_shape;
    const jint size = call(reinterpret_cast<char *>(elements), capacity);
    env->ReleaseByteArrayElements(reply, elements, size >= 0 ? 0 : JNI_ABORT);
    if (env->ExceptionCheck()) return host_status_shape;
    return size;
}

}
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_stageOpen(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring purpose,
    jstring logical_path, jstring reference, jstring document_id, jstring source_id) {
    if (epoch <= 0) return -501;
    std::string task_value, workspace_value, purpose_value;
    if (!host_ascii_arg(env, task, 64, &task_value) ||
        !host_ascii_arg(env, workspace, 64, &workspace_value) ||
        !host_ascii_arg(env, purpose, 32, &purpose_value)) return -105;
    std::string path_value, reference_value;
    if (logical_path != nullptr && env->GetStringLength(logical_path) > 0) {
        if (!host_utf8_arg(env, logical_path, 4096, &path_value)) return -105;
    }
    if (reference != nullptr && env->GetStringUTFLength(reference) > 0) {
        if (!host_utf8_arg(env, reference, 8192, &reference_value)) return -105;
    }
    std::string document_value, source_value;
    if (!host_optional_ascii(env, document_id, 8192, &document_value) ||
        !host_optional_ascii(env, source_id, 64, &source_value)) return -105;
    return floe_g04_source_host_stage_open(
        static_cast<uint64_t>(epoch), task_value.c_str(), workspace_value.c_str(),
        purpose_value.c_str(), path_value.c_str(), reference_value.c_str(),
        document_value.c_str(), source_value.c_str());
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_stageWrite(
    JNIEnv *env, jobject, jlong ticket, jbyteArray data, jint offset, jint length) {
    if (ticket <= 0 || data == nullptr || offset < 0 || length <= 0 ||
        length > host_chunk_limit) return -105;
    if (env->GetArrayLength(data) < offset + length) return -105;
    jbyte *elements = env->GetByteArrayElements(data, nullptr);
    if (elements == nullptr) return -105;
    const jint status = floe_g04_source_host_stage_write(
        ticket, reinterpret_cast<const uint8_t *>(elements) + offset, length);
    env->ReleaseByteArrayElements(data, elements, JNI_ABORT);
    return env->ExceptionCheck() ? -105 : status;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_stageFinish(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return -105;
    return host_reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_stage_finish(ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_stageAbort(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_g04_source_host_stage_abort(ticket) : -105;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_egressOpen(
    JNIEnv *env, jobject, jlong epoch, jstring mode, jstring task, jstring workspace,
    jstring logical_path, jstring source_id) {
    if (epoch <= 0) return -501;
    std::string mode_value, task_value, workspace_value;
    if (!host_ascii_arg(env, mode, 16, &mode_value) ||
        !host_ascii_arg(env, task, 64, &task_value) ||
        !host_ascii_arg(env, workspace, 64, &workspace_value)) return -105;
    std::string path_value;
    if (!host_utf8_arg(env, logical_path, 4096, &path_value)) return -105;
    std::string source_value;
    if (!host_optional_ascii(env, source_id, 64, &source_value)) return -105;
    return floe_g04_source_host_egress_open(static_cast<uint64_t>(epoch), mode_value.c_str(),
                                            task_value.c_str(), workspace_value.c_str(),
                                            path_value.c_str(), source_value.c_str());
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_egressInfo(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return -105;
    return host_reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_egress_info(ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_egressRead(
    JNIEnv *env, jobject, jlong ticket, jlong offset, jbyteArray target) {
    if (ticket <= 0 || offset < 0 || target == nullptr) return -105;
    const jsize capacity = env->GetArrayLength(target);
    if (capacity <= 0 || capacity > host_chunk_limit) return -105;
    jbyte *elements = env->GetByteArrayElements(target, nullptr);
    if (elements == nullptr) return -105;
    const jint copied = floe_g04_source_host_egress_read(ticket, offset,
                                                         reinterpret_cast<uint8_t *>(elements), capacity);
    env->ReleaseByteArrayElements(target, elements, copied > 0 ? 0 : JNI_ABORT);
    return env->ExceptionCheck() ? -105 : copied;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_egressVerify(
    JNIEnv *env, jobject, jlong egress_ticket, jlong stage_ticket, jbyteArray reply) {
    if (egress_ticket <= 0 || stage_ticket <= 0) return -105;
    return host_reply_call(env, reply, [egress_ticket, stage_ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_egress_verify(egress_ticket, stage_ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_egressClose(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_g04_source_host_egress_close(ticket) : -105;
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_savePrepare(
    JNIEnv *env, jobject, jlong save_ticket, jlong backup_ticket, jstring receipt_token,
    jbyteArray reply) {
    if (save_ticket <= 0 || backup_ticket <= 0) return -105;
    std::string token_value;
    if (!host_ascii_arg(env, receipt_token, 80, &token_value)) return -105;
    return host_reply_call(env, reply, [save_ticket, backup_ticket, token_value](char *buffer, int32_t capacity) {
        return floe_g04_source_host_save_prepare(save_ticket, backup_ticket, token_value.c_str(),
                                                 buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_saveClaim(
    JNIEnv *env, jobject, jlong save_ticket, jlong fresh_ticket, jbyteArray reply) {
    if (save_ticket <= 0 || fresh_ticket <= 0) return -105;
    return host_reply_call(env, reply, [save_ticket, fresh_ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_save_claim(save_ticket, fresh_ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_savePermit(
    JNIEnv *env, jobject, jlong save_ticket, jstring receipt_token) {
    if (save_ticket <= 0) return -105;
    std::string token_value;
    if (!host_ascii_arg(env, receipt_token, 80, &token_value)) return -105;
    return floe_g04_source_host_save_permit(save_ticket, token_value.c_str());
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_saveSettle(
    JNIEnv *env, jobject, jlong save_ticket, jlong readback_ticket, jbyteArray reply) {
    if (save_ticket <= 0 || readback_ticket <= 0) return -105;
    return host_reply_call(env, reply, [save_ticket, readback_ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_save_settle(save_ticket, readback_ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_saveRetain(
    JNIEnv *env, jobject, jlong save_ticket, jbyteArray reply) {
    if (save_ticket <= 0) return -105;
    return host_reply_call(env, reply, [save_ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_save_retain(save_ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_sourcePage(
    JNIEnv *env, jobject, jlong epoch, jstring workspace, jstring after_id, jint limit,
    jbyteArray reply) {
    if (epoch <= 0) return -501;
    std::string workspace_value;
    if (!host_ascii_arg(env, workspace, 64, &workspace_value)) return -105;
    std::string after_value;
    if (after_id != nullptr && env->GetStringLength(after_id) > 0) {
        if (!host_ascii_arg(env, after_id, 64, &after_value)) return -105;
    }
    const jint bounded = limit < 1 ? 1 : (limit > 64 ? 64 : limit);
    return host_reply_call(env, reply, [epoch, workspace_value, after_value, bounded](char *buffer, int32_t capacity) {
        return floe_g04_source_host_source_page(static_cast<uint64_t>(epoch), workspace_value.c_str(),
                                                after_value.c_str(), bounded, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_sourceLookup(
    JNIEnv *env, jobject, jlong epoch, jstring workspace, jstring logical_path, jbyteArray reply) {
    if (epoch <= 0) return -501;
    std::string workspace_value, path_value;
    if (!host_ascii_arg(env, workspace, 64, &workspace_value)) return -105;
    if (!host_utf8_arg(env, logical_path, 4096, &path_value)) return -105;
    return host_reply_call(env, reply, [epoch, workspace_value, path_value](char *buffer, int32_t capacity) {
        return floe_g04_source_host_source_lookup(static_cast<uint64_t>(epoch), workspace_value.c_str(),
                                                  path_value.c_str(), buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_recoveryPage(
    JNIEnv *env, jobject, jlong epoch, jstring workspace, jstring after_id, jint limit,
    jbyteArray reply) {
    if (epoch <= 0) return -501;
    std::string workspace_value;
    if (workspace != nullptr && env->GetStringLength(workspace) > 0) {
        if (!host_ascii_arg(env, workspace, 64, &workspace_value)) return -105;
    }
    std::string after_value;
    if (after_id != nullptr && env->GetStringLength(after_id) > 0) {
        if (!host_ascii_arg(env, after_id, 64, &after_value)) return -105;
    }
    const jint bounded = limit < 1 ? 1 : (limit > 64 ? 64 : limit);
    return host_reply_call(env, reply, [epoch, workspace_value, after_value, bounded](char *buffer, int32_t capacity) {
        return floe_g04_source_host_recovery_page(static_cast<uint64_t>(epoch), workspace_value.c_str(),
                                                  after_value.c_str(), bounded, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_reconcileRun(
    JNIEnv *env, jobject, jlong epoch, jstring workspace, jbyteArray reply) {
    if (epoch <= 0) return -501;
    std::string workspace_value;
    if (workspace != nullptr && env->GetStringLength(workspace) > 0) {
        if (!host_ascii_arg(env, workspace, 64, &workspace_value)) return -105;
    }
    return host_reply_call(env, reply, [epoch, workspace_value](char *buffer, int32_t capacity) {
        return floe_g04_source_host_reconcile_run(static_cast<uint64_t>(epoch), workspace_value.c_str(),
                                                  buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_reconcileStaged(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring recovery,
    jlong stage_ticket, jbyteArray reply) {
    if (epoch <= 0 || stage_ticket <= 0) return -501;
    std::string task_value, workspace_value, recovery_value;
    if (!host_ascii_arg(env, task, 64, &task_value) ||
        !host_ascii_arg(env, workspace, 64, &workspace_value) ||
        !host_ascii_arg(env, recovery, 64, &recovery_value)) return -105;
    return host_reply_call(env, reply, [epoch, task_value, workspace_value, recovery_value,
                                        stage_ticket](char *buffer, int32_t capacity) {
        return floe_g04_source_host_reconcile_staged(static_cast<uint64_t>(epoch), task_value.c_str(),
                                                     workspace_value.c_str(), recovery_value.c_str(),
                                                     stage_ticket, buffer, capacity);
    });
}
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_WorkspaceSourceNative_hostStats(JNIEnv *env, jobject, jbyteArray reply) {
    return host_reply_call(env, reply, [](char *buffer, int32_t capacity) {
        return floe_g04_source_host_stats(buffer, capacity);
    });
}
