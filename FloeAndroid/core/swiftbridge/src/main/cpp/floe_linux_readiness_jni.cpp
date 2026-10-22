// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 trusted-host JNI wrapper for the LIVE Linux readiness ingress /
// invalidation authority (job-3d39b56695c44bd2). The App/host proves REAL
// per-generation facts (distinct runtime UID, package certificate/version,
// binder identity, the live mailbox epoch, rootfs installation, an engine
// terminal-index receipt, lease authority, single-workload contract);
// FloeAndroidCore's LinuxReadinessIngress validates them against the live
// authorities and derives the ONE qualification predicate that dispatch AND
// ordinary route discovery read. There is no bulk setter, no model-reachable
// route (no V3 key), and no path that can flip a field true directly.
#include <jni.h>
#include <cstdint>
#include <string>
#include <vector>
extern "C" {
int32_t floe_linux_readiness_ingest(const char*, uint64_t, const char*, int32_t, char*, int32_t);
int32_t floe_linux_readiness_invalidate(const char*, const char*, char*, int32_t);
int32_t floe_linux_readiness_status(char*, int32_t);
int32_t floe_linux_readiness_activate_registration(uint64_t, char*, int32_t);
int32_t floe_linux_shell_resume_admission(uint64_t);
}
namespace {
constexpr int32_t limit = 65536;
constexpr int32_t maximumProof = 4096;

bool identifier(JNIEnv* env, jstring input, std::string& out) {
    if (!input) return false;
    const jsize n = env->GetStringLength(input);
    if (n < 1 || n > 48) return false;
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
    if (n < 1 || n > maximumProof) return false;
    out.resize(n);
    env->GetByteArrayRegion(input, 0, n, reinterpret_cast<jbyte*>(out.data()));
    return !env->ExceptionCheck();
}

template <typename F>
jbyteArray response(JNIEnv* env, F call) {
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
Java_com_floe_android_bridge_LinuxReadinessNative_ingest(JNIEnv* env, jobject, jstring field,
                                                         jlong epoch, jbyteArray proofBytes) {
    std::string name;
    std::vector<char> proof;
    if (epoch <= 0 || !identifier(env, field, name) || !payload(env, proofBytes, proof)) {
        return nullptr;
    }
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_readiness_ingest(name.c_str(), static_cast<uint64_t>(epoch),
                                          proof.data(), static_cast<int32_t>(proof.size()), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxReadinessNative_invalidate(JNIEnv* env, jobject, jstring field,
                                                             jstring reason) {
    std::string name, text;
    // field NULL/"*" invalidates the whole set; reason is a bounded token.
    if (field && !identifier(env, field, name)) return nullptr;
    if (!identifier(env, reason, text)) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_readiness_invalidate(name.empty() ? nullptr : name.c_str(),
                                               text.c_str(), out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxReadinessNative_status(JNIEnv* env, jobject) {
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_readiness_status(out, cap);
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_LinuxReadinessNative_activateRegistration(JNIEnv* env, jobject, jlong epoch) {
    if (epoch <= 0) return nullptr;
    return response(env, [&](char* out, int32_t cap) {
        return floe_linux_readiness_activate_registration(static_cast<uint64_t>(epoch), out, cap);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_LinuxReadinessNative_resumeAdmissions(JNIEnv* env, jobject, jlong epoch) {
    if (epoch <= 0) return -105;
    return floe_linux_shell_resume_admission(static_cast<uint64_t>(epoch));
}
