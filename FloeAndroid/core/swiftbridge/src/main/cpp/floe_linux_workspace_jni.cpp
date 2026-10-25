// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <cstdint>
#include <string>
#include <vector>
extern "C" {
int32_t floe_linux_workspace_binding(uint64_t, const char*, const char*, char*, int32_t);
int32_t floe_linux_workspace_binding_for_call(uint64_t, const char*, const char*, const char*, char*, int32_t);
int32_t floe_linux_workspace_binding_for_operation(uint64_t, const char*, const char*, const char*, char*, int32_t);
int32_t floe_linux_workspace_session_open(const char*, int32_t, char*, int32_t);
int32_t floe_linux_workspace_baseline_begin(const char*, char*, int32_t);
int32_t floe_linux_workspace_baseline_header(const char*, int64_t, char*, int32_t);
int32_t floe_linux_workspace_baseline_open_data(const char*, int64_t);
int32_t floe_linux_workspace_baseline_finish(const char*, int64_t, int64_t, char*, int32_t);
int32_t floe_linux_workspace_export_begin(const char*, char*, int32_t);
int32_t floe_linux_workspace_export_stage(const char*, const char*, int32_t, int32_t, char*, int32_t);
int32_t floe_linux_workspace_export_finish(const char*, char*, int32_t);
int32_t floe_linux_workspace_abort(const char*, const char*, char*, int32_t);
int32_t floe_linux_workspace_session_close(const char*);
int32_t floe_linux_workspace_stats(char*, int32_t);
int32_t floe_linux_workspace_sweep(int64_t, int64_t, char*, int32_t);
}
namespace {
constexpr int32_t limit = 65536;
// Identifiers/reasons are bounded ASCII; JSON uses raw standard UTF-8 bytes.
bool identifier(JNIEnv* env, jstring input, std::string& out) {
    if (!input) return false;
    const jsize n = env->GetStringLength(input);
    if (n < 1 || n > 64) return false;
    const jchar* value = env->GetStringChars(input, nullptr);
    if (!value) return false;
    bool valid = true;
    for (jsize i = 0; i < n; ++i) {
        if (value[i] < 0x21 || value[i] > 0x7e) { valid = false; break; }
        out.push_back(static_cast<char>(value[i]));
    }
    env->ReleaseStringChars(input, value);
    return valid && !env->ExceptionCheck();
}
bool payload(JNIEnv* env, jbyteArray input, std::vector<char>& out) {
    if (!input) return false;
    const jsize n = env->GetArrayLength(input);
    if (n < 1 || n > limit) return false;
    out.resize(n);
    env->GetByteArrayRegion(input, 0, n, reinterpret_cast<jbyte*>(out.data()));
    return !env->ExceptionCheck();
}
template <typename F> jbyteArray response(JNIEnv* env, F call) {
    std::vector<char> out(limit + 1);
    const int32_t n = call(out.data(), static_cast<int32_t>(out.size()));
    // Never replay a side effect after a short/uncertain response.
    if (n < 0 || n > limit || env->ExceptionCheck()) return nullptr;
    jbyteArray bytes = env->NewByteArray(n);
    if (bytes && n) env->SetByteArrayRegion(bytes, 0, n, reinterpret_cast<const jbyte*>(out.data()));
    return env->ExceptionCheck() ? nullptr : bytes;
}
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_binding(JNIEnv* env, jobject, jlong epoch, jstring runID, jstring grantID) {
    std::string run, grant;
    if (epoch <= 0 || !identifier(env, runID, run) || !identifier(env, grantID, grant)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_binding(static_cast<uint64_t>(epoch), run.c_str(), grant.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_bindingForCall(JNIEnv* env, jobject, jlong epoch, jstring runID, jstring toolCallID, jstring grantID) {
    std::string run, call, grant;
    if (epoch <= 0 || !identifier(env, runID, run) || !identifier(env, toolCallID, call) || !identifier(env, grantID, grant)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_binding_for_call(static_cast<uint64_t>(epoch), run.c_str(), call.c_str(), grant.c_str(), out, cap);
    });
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_bindingForOperation(JNIEnv* env, jobject, jlong epoch, jstring operationID, jstring runID, jstring grantID) {
    std::string operation, run, grant;
    if (epoch <= 0 || !identifier(env, operationID, operation) || !identifier(env, runID, run) || !identifier(env, grantID, grant)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_binding_for_operation(static_cast<uint64_t>(epoch), operation.c_str(), run.c_str(), grant.c_str(), out, cap);
    });
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_openSession(JNIEnv* env, jobject, jbyteArray binding) {
    std::vector<char> value;
    if (!payload(env, binding, value) || value.size() > 8192) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_session_open(value.data(), static_cast<int32_t>(value.size()), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_baselineBegin(JNIEnv* env, jobject, jstring sessionKey) {
    std::string key;
    if (!identifier(env, sessionKey, key)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_baseline_begin(key.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_exportBegin(JNIEnv* env, jobject, jstring sessionKey) {
    std::string key;
    if (!identifier(env, sessionKey, key)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_export_begin(key.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_exportFinish(JNIEnv* env, jobject, jstring sessionKey) {
    std::string key;
    if (!identifier(env, sessionKey, key)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_export_finish(key.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_baselineHeader(JNIEnv* env, jobject, jstring sessionKey, jlong index) {
    std::string key;
    if (index < 0 || !identifier(env, sessionKey, key)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_baseline_header(key.c_str(), index, out, cap);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_baselineOpenData(JNIEnv* env, jobject, jstring sessionKey, jlong index) {
    std::string key;
    if (index < 0 || !identifier(env, sessionKey, key)) return -1;
    return floe_linux_workspace_baseline_open_data(key.c_str(), index);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_baselineFinish(JNIEnv* env, jobject, jstring sessionKey, jlong count, jlong bytes) {
    std::string key;
    if (count < 0 || bytes < 0 || !identifier(env, sessionKey, key)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_baseline_finish(key.c_str(), count, bytes, out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_exportStage(JNIEnv* env, jobject, jstring sessionKey, jbyteArray header, jint dataFd) {
    std::string key;
    std::vector<char> value;
    if (dataFd < -1 || !identifier(env, sessionKey, key) || !payload(env, header, value)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_export_stage(key.c_str(), value.data(), static_cast<int32_t>(value.size()), dataFd, out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_abort(JNIEnv* env, jobject, jstring sessionKey, jstring reason) {
    std::string key, text;
    if (!identifier(env, sessionKey, key) || !identifier(env, reason, text)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_abort(key.c_str(), text.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_closeSession(JNIEnv* env, jobject, jstring sessionKey) {
    std::string key;
    return identifier(env, sessionKey, key) ? floe_linux_workspace_session_close(key.c_str()) : -105;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_stats(JNIEnv* env, jobject) {
    return response(env, [&](char* out, int32_t cap) { return floe_linux_workspace_stats(out, cap); });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxWorkspaceNative_sweep(JNIEnv* env, jobject, jlong nowSeconds, jlong graceSeconds) {
    if (nowSeconds <= 0 || graceSeconds < 60) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_workspace_sweep(nowSeconds, graceSeconds, out, cap);
    });
}
