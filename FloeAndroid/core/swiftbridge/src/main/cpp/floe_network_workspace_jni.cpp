// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 NETWORK WORKSPACE host JNI adapters (additive TU inside the SAME
// floe_jni target). Discipline mirrors the reviewed floe_workspace_source_jni
// .cpp: no global refs, no AttachCurrentThread, no Swift -> JVM callback;
// strict UTF-16 -> UTF-8 for path/name/username/endpoint arguments (no
// CESU-8, unpaired surrogates refused); ASCII-only identity tokens; typed
// negative statuses (-6xx, G04NetworkWorkspaceHostAPI.swift) returned
// unchanged; JSON replies are copied into the caller-provided ByteArray and
// never escape as a fresh unbounded allocation. Secret bytes cross ONLY
// through credStage as a raw bounded buffer: they are consumed once inside
// the native lease and are NEVER echoed back in any reply or status.
#include <jni.h>
#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>
extern "C" {
int64_t floe_g04_net_cred_stage(uint64_t, const uint8_t *, int32_t);
int32_t floe_g04_net_cred_abort(int64_t);
int32_t floe_g04_net_mount_page(uint64_t, const char *, const char *, char *, int32_t);
int32_t floe_g04_net_mount_add(uint64_t, const char *, const char *, const char *,
                               const char *, const char *, const char *, const char *,
                               int32_t, int64_t, char *, int32_t);
int32_t floe_g04_net_mount_update(uint64_t, const char *, const char *, const char *,
                                  const char *, const char *, const char *, const char *,
                                  const char *, int32_t, int64_t, char *, int32_t);
int32_t floe_g04_net_mount_probe(uint64_t, const char *, const char *, const char *,
                                 char *, int32_t);
int32_t floe_g04_net_mount_disconnect(uint64_t, const char *, const char *, const char *,
                                      char *, int32_t);
int32_t floe_g04_net_mount_remove(uint64_t, const char *, const char *, const char *,
                                  int32_t, char *, int32_t);
int32_t floe_g04_net_browse(uint64_t, const char *, const char *, const char *,
                            const char *, char *, int32_t);
int32_t floe_g04_net_stat(uint64_t, const char *, const char *, const char *,
                          const char *, char *, int32_t);
int64_t floe_g04_net_op_import(uint64_t, const char *, const char *, const char *,
                               const char *, const char *, int32_t, const char *);
int64_t floe_g04_net_op_export(uint64_t, const char *, const char *, const char *,
                               const char *, const char *, const char *);
int64_t floe_g04_net_op_save(uint64_t, const char *, const char *, const char *);
int64_t floe_g04_net_op_reconcile(uint64_t, const char *, const char *, const char *);
int32_t floe_g04_net_op_status(int64_t, char *, int32_t);
int32_t floe_g04_net_op_cancel(int64_t);
int32_t floe_g04_net_op_close(int64_t);
int32_t floe_g04_net_source_page(uint64_t, const char *, const char *, int32_t, char *, int32_t);
int32_t floe_g04_net_stats(char *, int32_t);
}
namespace {
constexpr int32_t net_status_shape = -105;
constexpr int32_t net_status_too_small = -106;
constexpr int32_t net_reply_limit = 32768;
constexpr int32_t net_secret_limit = 65536;
constexpr int32_t net_id_limit = 64;
constexpr int32_t net_text_limit = 4096;   // endpoint/path/username-ish bounds

bool net_ascii(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Required ASCII identity token (canonical UUIDs, transport/policy words).
bool net_ascii_arg(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    if (source == nullptr || maximum <= 0) return false;
    const jsize length = env->GetStringUTFLength(source);
    if (length < 0 || length > maximum) return false;
    const char *chars = env->GetStringUTFChars(source, nullptr);
    if (chars == nullptr) return false;
    out->assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(source, chars);
    if (out->empty()) return false;
    if (env->ExceptionCheck()) { env->ExceptionClear(); return false; }
    return net_ascii(*out);
}

// Optional ASCII token: null/empty maps to "" (the Swift layer treats "" as
// absent through G04HostC.optionalString).
bool net_optional_ascii(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    out->clear();
    if (source == nullptr) return true;
    if (env->GetStringUTFLength(source) == 0) return true;
    return net_ascii_arg(env, source, maximum, out);
}

// Required possibly-Unicode argument (names, paths, endpoints, usernames).
// Unpaired surrogates are rejected instead of a partially converted prefix.
bool net_utf8_arg(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
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
        // Empty is meaningful here (""): absent optional fields; the Swift
        // grammar re-checks bounds with the SAME canon as the journal.
        if (converted.size() > static_cast<size_t>(maximum)) return false;
        out->swap(converted);
        return true;
    } catch (const std::exception &) {
        return false;
    }
}

// Optional possibly-Unicode argument: null maps to "" (absent).
bool net_optional_utf8(JNIEnv *env, jstring source, int32_t maximum, std::string *out) {
    out->clear();
    if (source == nullptr) return true;
    if (env->GetStringLength(source) == 0) return true;
    return net_utf8_arg(env, source, maximum, out);
}

template <typename Call>
jint net_reply_call(JNIEnv *env, jbyteArray reply, Call call) {
    if (reply == nullptr) return net_status_shape;
    const jsize capacity = env->GetArrayLength(reply);
    if (capacity <= 0 || capacity > net_reply_limit) return net_status_too_small;
    jbyte *elements = env->GetByteArrayElements(reply, nullptr);
    if (elements == nullptr) return net_status_shape;
    const jint size = call(reinterpret_cast<char *>(elements), capacity);
    env->ReleaseByteArrayElements(reply, elements, size >= 0 ? 0 : JNI_ABORT);
    if (env->ExceptionCheck()) return net_status_shape;
    return size;
}

bool net_identity(JNIEnv *env, jstring task, jstring workspace,
                  std::string *task_out, std::string *workspace_out) {
    return net_ascii_arg(env, task, net_id_limit, task_out) &&
           net_ascii_arg(env, workspace, net_id_limit, workspace_out);
}
}

// ---------------------------------------------------------------------------
// Credential staging (raw bounded bytes; one-shot native RAM ticket)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_credStage(
    JNIEnv *env, jobject, jlong epoch, jbyteArray data, jint offset, jint length) {
    if (epoch <= 0 || data == nullptr || offset < 0 || length <= 0 ||
        length > net_secret_limit) return -105;
    if (env->GetArrayLength(data) < offset + length) return -105;
    std::vector<uint8_t> value(static_cast<size_t>(length));
    env->GetByteArrayRegion(data, offset, length, reinterpret_cast<jbyte *>(value.data()));
    if (env->ExceptionCheck()) return -105;
    const auto status = floe_g04_net_cred_stage(static_cast<uint64_t>(epoch), value.data(),
                                                length);
    // Best effort clear of the JNI-side copy regardless of outcome.
    memset(value.data(), 0, value.size());
    return status;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_credAbort(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_g04_net_cred_abort(ticket) : -105;
}

// ---------------------------------------------------------------------------
// Mount configuration
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountPage(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value)) return -105;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value](char *buffer,
                                                                           int32_t capacity) {
        return floe_g04_net_mount_page(static_cast<uint64_t>(epoch), task_value.c_str(),
                                       workspace_value.c_str(), buffer, capacity);
    });
}

namespace {
// Shared adapter for mount_add / mount_update argument marshalling.
struct NetMountArgs {
    std::string task, workspace, name, transport, endpoint, root_path, username;
    int32_t read_only = 0;
    int64_t credential_ticket = 0;
};

bool net_read_mount_args(JNIEnv *env, jstring task, jstring workspace, jstring name,
                         jstring transport, jstring endpoint, jstring root_path,
                         jstring username, jboolean read_only, jlong credential_ticket,
                         NetMountArgs *out) {
    return net_ascii_arg(env, task, net_id_limit, &out->task) &&
           net_ascii_arg(env, workspace, net_id_limit, &out->workspace) &&
           net_optional_utf8(env, name, 128, &out->name) &&
           net_ascii_arg(env, transport, 16, &out->transport) &&
           net_utf8_arg(env, endpoint, net_text_limit, &out->endpoint) &&
           net_optional_utf8(env, root_path, net_text_limit, &out->root_path) &&
           net_optional_utf8(env, username, 256, &out->username) &&
           (out->read_only = read_only ? 1 : 0, true) &&
           (out->credential_ticket = credential_ticket, true);
}
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountAdd(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring name,
    jstring transport, jstring endpoint, jstring root_path, jstring username,
    jboolean read_only, jlong credential_ticket, jbyteArray reply) {
    if (epoch <= 0) return -601;
    NetMountArgs args;
    if (!net_read_mount_args(env, task, workspace, name, transport, endpoint, root_path,
                             username, read_only, credential_ticket, &args)) return -105;
    return net_reply_call(env, reply, [&args, epoch](char *buffer, int32_t capacity) {
        return floe_g04_net_mount_add(static_cast<uint64_t>(epoch), args.task.c_str(),
                                      args.workspace.c_str(), args.name.c_str(),
                                      args.transport.c_str(), args.endpoint.c_str(),
                                      args.root_path.c_str(), args.username.c_str(),
                                      args.read_only, args.credential_ticket,
                                      buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountUpdate(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jstring name, jstring transport, jstring endpoint, jstring root_path, jstring username,
    jboolean read_only, jlong credential_ticket, jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string mount_value;
    if (!net_ascii_arg(env, mount, net_id_limit, &mount_value)) return -105;
    NetMountArgs args;
    if (!net_read_mount_args(env, task, workspace, name, transport, endpoint, root_path,
                             username, read_only, credential_ticket, &args)) return -105;
    return net_reply_call(env, reply, [&args, mount_value, epoch](char *buffer,
                                                                  int32_t capacity) {
        return floe_g04_net_mount_update(static_cast<uint64_t>(epoch), args.task.c_str(),
                                         args.workspace.c_str(), mount_value.c_str(),
                                         args.name.c_str(), args.transport.c_str(),
                                         args.endpoint.c_str(), args.root_path.c_str(),
                                         args.username.c_str(), args.read_only,
                                         args.credential_ticket, buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountProbe(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value)) return -105;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value,
                                       mount_value](char *buffer, int32_t capacity) {
        return floe_g04_net_mount_probe(static_cast<uint64_t>(epoch), task_value.c_str(),
                                        workspace_value.c_str(), mount_value.c_str(),
                                        buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountDisconnect(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value)) return -105;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value,
                                       mount_value](char *buffer, int32_t capacity) {
        return floe_g04_net_mount_disconnect(static_cast<uint64_t>(epoch), task_value.c_str(),
                                             workspace_value.c_str(), mount_value.c_str(),
                                             buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_mountRemove(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jboolean forget_credential, jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value)) return -105;
    const int32_t forget = forget_credential ? 1 : 0;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value, mount_value,
                                       forget](char *buffer, int32_t capacity) {
        return floe_g04_net_mount_remove(static_cast<uint64_t>(epoch), task_value.c_str(),
                                         workspace_value.c_str(), mount_value.c_str(),
                                         forget, buffer, capacity);
    });
}

// ---------------------------------------------------------------------------
// Browse / stat
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_browse(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jstring path, jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value, path_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value) ||
        !net_optional_utf8(env, path, net_text_limit, &path_value)) return -105;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value, mount_value,
                                       path_value](char *buffer, int32_t capacity) {
        return floe_g04_net_browse(static_cast<uint64_t>(epoch), task_value.c_str(),
                                   workspace_value.c_str(), mount_value.c_str(),
                                   path_value.c_str(), buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_stat(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jstring path, jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value, path_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value) ||
        !net_utf8_arg(env, path, net_text_limit, &path_value)) return -105;
    return net_reply_call(env, reply, [epoch, task_value, workspace_value, mount_value,
                                       path_value](char *buffer, int32_t capacity) {
        return floe_g04_net_stat(static_cast<uint64_t>(epoch), task_value.c_str(),
                                 workspace_value.c_str(), mount_value.c_str(),
                                 path_value.c_str(), buffer, capacity);
    });
}

// ---------------------------------------------------------------------------
// Operations (positive opaque tickets; negative typed statuses)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opImport(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jstring remote_path, jstring logical_path, jboolean recursive, jstring conflict) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value, remote_value, logical_value, conflict_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value) ||
        !net_utf8_arg(env, remote_path, net_text_limit, &remote_value) ||
        !net_utf8_arg(env, logical_path, net_text_limit, &logical_value) ||
        !net_ascii_arg(env, conflict, 16, &conflict_value)) return -105;
    return floe_g04_net_op_import(static_cast<uint64_t>(epoch), task_value.c_str(),
                                  workspace_value.c_str(), mount_value.c_str(),
                                  remote_value.c_str(), logical_value.c_str(),
                                  recursive ? 1 : 0, conflict_value.c_str());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opExport(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring mount,
    jstring logical_path, jstring remote_path, jstring policy) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, mount_value, logical_value, remote_value, policy_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, mount, net_id_limit, &mount_value) ||
        !net_utf8_arg(env, logical_path, net_text_limit, &logical_value) ||
        !net_utf8_arg(env, remote_path, net_text_limit, &remote_value) ||
        !net_ascii_arg(env, policy, 16, &policy_value)) return -105;
    return floe_g04_net_op_export(static_cast<uint64_t>(epoch), task_value.c_str(),
                                  workspace_value.c_str(), mount_value.c_str(),
                                  logical_value.c_str(), remote_value.c_str(),
                                  policy_value.c_str());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opSave(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring source) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, source_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, source, net_id_limit, &source_value)) return -105;
    return floe_g04_net_op_save(static_cast<uint64_t>(epoch), task_value.c_str(),
                                workspace_value.c_str(), source_value.c_str());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opReconcile(
    JNIEnv *env, jobject, jlong epoch, jstring task, jstring workspace, jstring recovery) {
    if (epoch <= 0) return -601;
    std::string task_value, workspace_value, recovery_value;
    if (!net_identity(env, task, workspace, &task_value, &workspace_value) ||
        !net_ascii_arg(env, recovery, net_id_limit, &recovery_value)) return -105;
    return floe_g04_net_op_reconcile(static_cast<uint64_t>(epoch), task_value.c_str(),
                                     workspace_value.c_str(), recovery_value.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opStatus(
    JNIEnv *env, jobject, jlong ticket, jbyteArray reply) {
    if (ticket <= 0) return -105;
    return net_reply_call(env, reply, [ticket](char *buffer, int32_t capacity) {
        return floe_g04_net_op_status(ticket, buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opCancel(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_g04_net_op_cancel(ticket) : -105;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_opClose(JNIEnv *, jobject, jlong ticket) {
    return ticket > 0 ? floe_g04_net_op_close(ticket) : -105;
}

// ---------------------------------------------------------------------------
// Metadata-only network source rows + counters
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_sourcePage(
    JNIEnv *env, jobject, jlong epoch, jstring workspace, jstring after_id, jint limit,
    jbyteArray reply) {
    if (epoch <= 0) return -601;
    std::string workspace_value;
    if (!net_ascii_arg(env, workspace, net_id_limit, &workspace_value)) return -105;
    std::string after_value;
    if (!net_optional_ascii(env, after_id, net_id_limit, &after_value)) return -105;
    const jint bounded = limit < 1 ? 1 : (limit > 32 ? 32 : limit);
    return net_reply_call(env, reply, [epoch, workspace_value, after_value,
                                       bounded](char *buffer, int32_t capacity) {
        return floe_g04_net_source_page(static_cast<uint64_t>(epoch), workspace_value.c_str(),
                                       after_value.c_str(), bounded, buffer, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_NetworkWorkspaceNative_hostStats(JNIEnv *env, jobject,
                                                              jbyteArray reply) {
    return net_reply_call(env, reply, [](char *buffer, int32_t capacity) {
        return floe_g04_net_stats(buffer, capacity);
    });
}
