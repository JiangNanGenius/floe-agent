// SPDX-License-Identifier: MPL-2.0
//
// Device-workspace sync — trusted-host JNI adapters for the App-owned
// paired-device workspace lane (`floe_device_workspace_*`). Additive
// translation unit inside the SAME floe_jni target; every prior wrapper
// file stays byte-identical. Discipline mirrors the reviewed device-history
// TU:
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * identities (task UUIDs, digests, wire-relative paths, the scope
//    string) travel as bounded UTF-8 inside small JSON documents — bounded
//    on this side BEFORE Swift is ever called;
//  * typed negative statuses pass through unchanged — never a silent null
//    and never a path/title/byte inside an error text;
//  * the command reply copies into the caller-provided byte array; source
//    pages copy OUT of the owned session and staged chunks copy OUT of the
//    caller array through one bounded 64 KiB scratch — the Java array
//    contents never escape the frame;
//  * the epoch is the App's readback of the ACCEPTED native root — Swift
//    re-validates it against the live generation on every call and never
//    trusts it.
//
// Byte direction (the ONLY two binary channels): read streams <= 64 KiB
// pages out of the prepared source session (index -1 manifest, >= 0 file);
// write pushes <= 64 KiB chunks into the bounded staged accumulator (1 GiB
// file ceiling enforced in Swift before any rename).
#include <jni.h>

#include <array>
#include <cstdint>
#include <string>

extern "C" {
int32_t floe_device_workspace_command(const char *, const uint8_t *, int32_t,
                                      char *, int32_t);
int32_t floe_device_workspace_read(int64_t, int32_t, int64_t, uint8_t *, int32_t);
int32_t floe_device_workspace_write(int64_t, const uint8_t *, int32_t);
}

namespace {

constexpr int32_t status_shape = -105;
constexpr int32_t status_too_small = -106;
constexpr int32_t reply_limit = 262144;   // whole-command reply budget
constexpr int32_t input_limit = 16384;    // bounded UTF-8 JSON command input
constexpr int32_t chunk_limit = 65536;
constexpr int32_t operation_limit = 32;

bool ascii_only(const std::string &value) {
    for (const char byte : value) {
        if (static_cast<unsigned char>(byte) >= 0x80) return false;
    }
    return true;
}

// Swift validates the operation name against the closed grammar and every
// field inside the JSON document.
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
// — Swift budgets the page the same way. Empty success crosses as length 0.
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

// One bounded JSON command document {operation, input -> reply}.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceWorkspaceNative_command(
    JNIEnv *env, jobject, jstring operation, jbyteArray input, jbyteArray reply) {
    std::string name;
    if (!ascii_arg(env, operation, operation_limit, &name)) return status_shape;
    std::array<uint8_t, input_limit> scratch{};
    const uint8_t *input_bytes = nullptr;
    int32_t input_size = 0;
    if (input != nullptr) {
        const jsize size = env->GetArrayLength(input);
        if (size <= 0 || size > input_limit) return status_shape;
        env->GetByteArrayRegion(input, 0, size, reinterpret_cast<jbyte *>(scratch.data()));
        if (env->ExceptionCheck()) { env->ExceptionClear(); return status_shape; }
        input_bytes = scratch.data();
        input_size = static_cast<int32_t>(size);
    }
    return reply_call(env, reply, [&](char *buffer, int32_t capacity) {
        return floe_device_workspace_command(
            name.c_str(), input_bytes, input_size, buffer, capacity);
    });
}

// One bounded source page: index -1 manifest, >= 0 prepared file entry.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceWorkspaceNative_read(
    JNIEnv *env, jobject, jlong ticket, jint index, jlong offset, jbyteArray target) {
    if (ticket <= 0 || offset < 0 || target == nullptr) return status_shape;
    const jsize capacity = env->GetArrayLength(target);
    if (capacity <= 0 || capacity > chunk_limit) return status_shape;
    jbyte *elements = env->GetByteArrayElements(target, nullptr);
    if (elements == nullptr) return status_shape;
    const jint copied = floe_device_workspace_read(
        ticket, index, offset, reinterpret_cast<uint8_t *>(elements), capacity);
    env->ReleaseByteArrayElements(target, elements, copied > 0 ? 0 : JNI_ABORT);
    return env->ExceptionCheck() ? status_shape : copied;
}

// One bounded staged chunk copied out of the caller array through the
// bounded scratch. The aggregate stays under the 1 GiB file ceiling
// (Swift enforces the ceiling before the append commits).
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DeviceWorkspaceNative_write(
    JNIEnv *env, jobject, jlong ticket, jbyteArray source, jint offset, jint length) {
    if (ticket <= 0 || source == nullptr || offset < 0 || length <= 0 ||
        length > chunk_limit) {
        return status_shape;
    }
    const jsize size = env->GetArrayLength(source);
    if (offset > size || length > size - offset) {
        return status_shape;
    }
    jbyte scratch[chunk_limit];
    env->GetByteArrayRegion(source, offset, length, scratch);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return status_shape; }
    return floe_device_workspace_write(
        ticket, reinterpret_cast<const uint8_t *>(scratch), length);
}
