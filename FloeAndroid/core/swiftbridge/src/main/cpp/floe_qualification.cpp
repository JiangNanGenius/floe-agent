// SPDX-License-Identifier: MPL-2.0
// Debug instrumentation wrapper for the qualification seam in
// libFloeAndroidCore.so (QualificationSeam.swift). Built ONLY for the debug
// variant (CMake option FLOE_BUILD_QUALIFICATION_JNI, passed by the debug
// buildType in build.gradle.kts), so release AAR native entries never carry
// it; the shared prebuilt core .so export inventory is reported honestly in
// the qualification evidence. Exposed ONLY to the androidTest class
// com.floe.android.bridge.QualificationNative; it is not a bridge operation
// surface, registers no grants or task authority and never executes a
// command. The frozen floe_jni.cpp / v1 exchange path is untouched; the same
// UTF-8/64KiB and NUL bounds are applied here.
#include <jni.h>
#include <codecvt>
#include <cstdint>
#include <cstdlib>
#include <locale>
#include <string>

extern "C" void *floe_gate_create_from_corpus(const uint8_t *corpus, long count);
extern "C" void *floe_gate_create_fail_closed(const char *reason);
extern "C" char *floe_gate_evaluate(void *handle, const char *command);
extern "C" void floe_gate_release(void *handle);
extern "C" char *floe_db_smoke(const char *cache_path);
extern "C" char *floe_json_kind_smoke(void);
extern "C" char *floe_transport_smoke(const char *spec_json);
extern "C" char *floe_tls_qualification(const char *spec_json);
extern "C" void floe_bridge_free(const char *response);

namespace {

constexpr jsize kMaxText = 65536;        // mirrors the frozen bridge bound
constexpr jsize kMaxPath = 1024;         // cache path bound
constexpr jsize kMaxReason = 4096;       // failClosed reason bound

std::string utf16ToUtf8(JNIEnv *env, jstring text, jsize limit, bool &ok) {
    ok = false;
    if (!text) return {};
    const jsize size = env->GetStringLength(text);
    if (size > limit) return {};
    const jchar *chars = env->GetStringChars(text, nullptr);
    if (!chars) return {};
    std::u16string input(reinterpret_cast<const char16_t *>(chars), size);
    env->ReleaseStringChars(text, chars);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
    std::string utf8 = codec.to_bytes(input);
    if (utf8.size() > static_cast<size_t>(limit) || utf8.find('\0') != std::string::npos) {
        return {};
    }
    ok = true;
    return utf8;
}

jstring utf8ToJava(JNIEnv *env, const char *response) {
    if (!response) {
        env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),
                      "Shared core returned no response");
        return nullptr;
    }
    const std::string output(response);
    floe_bridge_free(response);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
    const std::u16string decoded = codec.from_bytes(output);
    return env->NewString(reinterpret_cast<const jchar *>(decoded.data()),
                          static_cast<jsize>(decoded.size()));
}

void throwBad(JNIEnv *env, const char *message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), message);
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeGateCreateFromCorpus(
    JNIEnv *env, jobject, jbyteArray corpus) {
    if (!corpus) {
        throwBad(env, "Missing corpus bytes");
        return 0;
    }
    const jsize count = env->GetArrayLength(corpus);
    if (count <= 0 || count > 1048576) {
        return 0; // fail closed; never substitute an empty pattern set
    }
    jbyte *bytes = env->GetByteArrayElements(corpus, nullptr);
    if (!bytes) return 0;
    void *handle = floe_gate_create_from_corpus(
        reinterpret_cast<const uint8_t *>(bytes), static_cast<long>(count));
    env->ReleaseByteArrayElements(corpus, bytes, JNI_ABORT);
    return reinterpret_cast<jlong>(handle);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeGateCreateFailClosed(
    JNIEnv *env, jobject, jstring reason) {
    bool ok = false;
    const std::string text = utf16ToUtf8(env, reason, kMaxReason, ok);
    if (!ok) {
        throwBad(env, "Invalid failClosed reason");
        return 0;
    }
    void *handle = floe_gate_create_fail_closed(text.c_str());
    return reinterpret_cast<jlong>(handle);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeGateEvaluate(
    JNIEnv *env, jobject, jlong handle, jstring command) {
    bool ok = false;
    const std::string text = utf16ToUtf8(env, command, kMaxText, ok);
    if (!ok) {
        throwBad(env, "Invalid qualification command");
        return nullptr;
    }
    char *response = floe_gate_evaluate(reinterpret_cast<void *>(handle), text.c_str());
    return utf8ToJava(env, response);
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeGateRelease(
    JNIEnv *, jobject, jlong handle) {
    if (handle != 0) {
        floe_gate_release(reinterpret_cast<void *>(handle));
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeDbSmoke(
    JNIEnv *env, jobject, jstring cachePath) {
    bool ok = false;
    const std::string path = utf16ToUtf8(env, cachePath, kMaxPath, ok);
    if (!ok || path.empty() || path[0] != '/') {
        throwBad(env, "Invalid cache path for qualification smoke");
        return nullptr;
    }
    char *response = floe_db_smoke(path.c_str());
    return utf8ToJava(env, response);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeJsonKindSmoke(
    JNIEnv *env, jobject) {
    char *response = floe_json_kind_smoke();
    return utf8ToJava(env, response);
}

// G02-P3 incremental transport qualification: bounded JSON spec in, bounded
// JSON report out. Same debug-only wrapper policy as the other smokes: the
// underlying @_cdecl export lives in the shared prebuilt core (inventoried
// honestly), while this JNI entry exists ONLY in the debug variant.
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeTransportSmoke(
    JNIEnv *env, jobject, jstring spec) {
    bool ok = false;
    const std::string text = utf16ToUtf8(env, spec, kMaxText, ok);
    if (!ok || text.size() < 2 || text.front() != '{' || text.back() != '}') {
        throwBad(env, "Invalid transport qualification spec");
        return nullptr;
    }
    char *response = floe_transport_smoke(text.c_str());
    return utf8ToJava(env, response);
}

// G02 native TLS/default-trust qualification (job-b1709c36b200442c): bounded
// JSON spec in, bounded JSON report out. Same debug-only wrapper policy as
// the other qualification entries. The CA-bundle lever below exists ONLY so
// the isolated test process can point the upstream
// URLSessionCertificateAuthorityInfoFile escape at a synthetic fixture CA;
// it is never referenced by the app, never set in the product process and
// must never carry the INSECURE_SSL_NO_VERIFY value.
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeTLSQualification(
    JNIEnv *env, jobject, jstring spec) {
    bool ok = false;
    const std::string text = utf16ToUtf8(env, spec, kMaxText, ok);
    if (!ok || text.size() < 2 || text.front() != '{' || text.back() != '}') {
        throwBad(env, "Invalid TLS qualification spec");
        return nullptr;
    }
    char *response = floe_tls_qualification(text.c_str());
    return utf8ToJava(env, response);
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeTLSSetCABundle(
    JNIEnv *env, jobject, jstring path) {
    bool ok = false;
    const std::string text = utf16ToUtf8(env, path, kMaxPath, ok);
    if (!ok || text.empty() || text.front() != '/') {
        throwBad(env, "Invalid CA bundle path (absolute path required)");
        return;
    }
    setenv("URLSessionCertificateAuthorityInfoFile", text.c_str(), 1);
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_QualificationNative_nativeTLSClearCABundle(
    JNIEnv *, jobject) {
    unsetenv("URLSessionCertificateAuthorityInfoFile");
}
