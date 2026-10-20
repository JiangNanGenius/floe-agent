// SPDX-License-Identifier: MPL-2.0
//
// Product-UID credential gateway — P3 JNI adapter.
//
// A new translation unit inside the EXISTING floe_jni target. The frozen
// floe_jni.cpp and every original Swift/Kotlin authority stay byte-identical.
//
// Discipline:
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * <=4 local object refs per frame; every allocating call is followed by an
//    ExceptionCheck before any Swift call;
//  * read-only arrays use GetByteArrayElements + JNI_ABORT;
//  * take writes directly into the NewByteArray element buffer;
//  * descriptor/stats strings are ASCII-validated before NewStringUTF.
//
// This source is UNCOMPILED in the source-authoring package; the separately
// serialized native qualification package owns the actual build/link smoke.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>

extern "C" {
int32_t floe_secret_mailbox_bind(uint64_t epoch);
int64_t floe_secret_mailbox_await(int32_t timeoutMillis);
int32_t floe_secret_mailbox_describe(int64_t claim, char *buffer, int32_t capacity);
int32_t floe_secret_mailbox_payload_length(int64_t claim);
int32_t floe_secret_mailbox_take_payload(int64_t claim, uint8_t *buffer, int32_t capacity);
int32_t floe_secret_mailbox_is_live(int64_t claim);
int32_t floe_secret_mailbox_complete(int64_t claim, int32_t status,
                                      const uint8_t *value, int32_t valueLen);
int32_t floe_secret_mailbox_stats(char *buffer, int32_t capacity);
int32_t floe_secret_gateway_install(void);
int32_t floe_secret_gateway_remove(void);
int32_t floe_secret_save_intent_submit(const char *intentJSON,
                                       const uint8_t *value, int32_t valueLen,
                                       char *outToken, int32_t outCap);
int32_t floe_secret_save_intent_discard(const char *token);
// Trusted native host route authority (G02HostSecureIngress.swift). These
// are App-process host calls: NOT a V3 command/tool and never reachable from
// model-authored envelopes. Route tokens are minted natively and scoped to
// the accepted Root epoch; the App only echoes its own handle back.
int32_t floe_host_route_open(const char *editorKind, const char *editorID,
                             int64_t uiGeneration, int64_t expectedNativeRootEpoch,
                             char *outToken, int32_t outCap);
int32_t floe_host_route_clear(const char *token);
int32_t floe_host_save_intent_submit(const char *intentCoreJSON,
                                     const char *routeToken,
                                     const uint8_t *value, int32_t valueLen,
                                     char *outToken, int32_t outCap);
}

namespace {

constexpr jsize kMaximumSecretBytes = 65536;
constexpr int32_t kDescriptorCapacity = 512;
constexpr int32_t kStatsCapacity = 4096;
constexpr size_t kMaximumIntentJsonBytes = 16384;
constexpr size_t kMaximumTokenBytes = 64;
constexpr size_t kIngressTokenLogicalBytes = 39;

bool FloeAscii(const char *data, int32_t length) {
    if (!data || length < 0) return false;
    for (int32_t index = 0; index < length; ++index) {
        if (static_cast<unsigned char>(data[index]) >= 0x80) return false;
    }
    return true;
}

// Rejects unpaired UTF-16 surrogates instead of accepting a partially
// converted prefix. The frozen Android store accepts display names, URLs and
// user text with supplementary characters (CJK/emoji), so this must be a
// complete UTF-16 -> UTF-8 conversion, not modified UTF-8.
bool FloeValidUtf16(const jchar *chars, jsize length) {
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

// Converts a Java UTF-16 string to strict UTF-8. Every allocation/conversion
// path is inside try/catch and the acquired JNI characters are released on
// every exit. GetStringUTFChars is deliberately not used (CESU-8 would break
// JSON/CJK/emoji payloads).
bool FloeUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
                         std::string &output, bool &tooLarge) {
    tooLarge = false;
    output.clear();
    if (!value) return false;
    const jsize length = env->GetStringLength(value);
    if (length < 0) return false;
    if (static_cast<size_t>(length) > maximumBytes) {
        tooLarge = true;
        return false;
    }
    const jchar *chars = env->GetStringChars(value, nullptr);
    if (!chars) return false;
    bool ok = false;
    try {
        if (FloeValidUtf16(chars, length)) {
            std::u16string utf16(reinterpret_cast<const char16_t *>(chars),
                                 static_cast<size_t>(length));
            std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
            output = converter.to_bytes(utf16);
            if (converter.converted() == utf16.size()) {
                ok = true;
            } else {
                output.clear();
            }
        }
    } catch (...) {
        ok = false;
    }
    env->ReleaseStringChars(value, chars);
    if (!ok) {
        output.clear();
        return false;
    }
    if (output.size() > maximumBytes) {
        tooLarge = true;
        output.clear();
        return false;
    }
    if (output.find('\0') != std::string::npos) {
        output.clear();
        return false;
    }
    return true;
}

void FloeRaiseFallback(JNIEnv *env) {
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "secret_gateway_failure");
        env->DeleteLocalRef(fallback);
    }
}

// Typed submit failures. Lookup failures are NOT cleared: a genuine pending
// JNI exception is preserved and surfaces to the Kotlin caller. If the typed
// class is genuinely unavailable without a pending exception, a generic
// IllegalStateException is raised so the caller never returns null silently.
bool FloeThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return false;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/SecretGatewayNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                if (env->ExceptionCheck()) return true;
                FloeRaiseFallback(env);
                return false;
            }
            if (!env->ExceptionCheck()) FloeRaiseFallback(env);
            return false;
        }
        env->DeleteLocalRef(exceptionClass);
        if (env->ExceptionCheck()) return false;  // preserve NoSuchMethodError
    } else if (env->ExceptionCheck()) {
        return false;  // preserve NoClassDefFoundError/OOM
    }
    FloeRaiseFallback(env);
    return env->ExceptionCheck();
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_bindSecretDispatcher(
    JNIEnv *, jobject, jlong epoch) {
    if (epoch <= 0) return -105;
    return floe_secret_mailbox_bind(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_awaitSecretRequest(
    JNIEnv *, jobject, jint timeoutMillis) {
    if (timeoutMillis < 0) return -105;
    return static_cast<jlong>(floe_secret_mailbox_await(timeoutMillis));
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_describeSecretRequest(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    char buffer[kDescriptorCapacity];
    const int32_t length = floe_secret_mailbox_describe(claim, buffer,
                                                        kDescriptorCapacity);
    if (length < 0 || length >= kDescriptorCapacity) return nullptr;
    if (!FloeAscii(buffer, length)) return nullptr;
    return env->NewStringUTF(buffer);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_takeSecretPayload(
    JNIEnv *env, jobject, jlong claim) {
    if (claim <= 0) return nullptr;
    const int32_t length = floe_secret_mailbox_payload_length(claim);
    if (length < 0) return nullptr;
    jbyteArray result = env->NewByteArray(length);
    if (!result) return nullptr;
    if (length == 0) {
        const int32_t consumed = floe_secret_mailbox_take_payload(claim, nullptr, 0);
        if (consumed != 0) {
            env->DeleteLocalRef(result);
            return nullptr;
        }
        return result;
    }
    jbyte *elements = env->GetByteArrayElements(result, nullptr);
    if (!elements) {
        env->DeleteLocalRef(result);
        return nullptr;
    }
    const int32_t consumed = floe_secret_mailbox_take_payload(
        claim, reinterpret_cast<uint8_t *>(elements), length);
    if (consumed == length) {
        env->ReleaseByteArrayElements(result, elements, 0);
        return result;
    }
    env->ReleaseByteArrayElements(result, elements, JNI_ABORT);
    env->DeleteLocalRef(result);
    return nullptr;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_isSecretRequestLive(
    JNIEnv *, jobject, jlong claim) {
    return floe_secret_mailbox_is_live(claim) == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_completeSecretRequest(
    JNIEnv *env, jobject, jlong claim, jint status, jbyteArray value) {
    if (claim <= 0) return -100;
    if (status == 1) {
        if (!value) {
            return floe_secret_mailbox_complete(claim, status, nullptr, 0);
        }
        const jsize length = env->GetArrayLength(value);
        if (length < 0 || length > kMaximumSecretBytes) return -105;
        if (length == 0) {
            return floe_secret_mailbox_complete(claim, status, nullptr, 0);
        }
        jbyte *elements = env->GetByteArrayElements(value, nullptr);
        if (!elements) return -105;
        const int32_t result = floe_secret_mailbox_complete(
            claim, status, reinterpret_cast<const uint8_t *>(elements), length);
        env->ReleaseByteArrayElements(value, elements, JNI_ABORT);
        return result;
    }
    if (value) return -105;
    return floe_secret_mailbox_complete(claim, status, nullptr, 0);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_secretMailboxStats(
    JNIEnv *env, jobject) {
    char buffer[kStatsCapacity];
    const int32_t length = floe_secret_mailbox_stats(buffer, kStatsCapacity);
    if (length < 0 || length >= kStatsCapacity) return nullptr;
    if (!FloeAscii(buffer, length)) return nullptr;
    return env->NewStringUTF(buffer);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_installSecretGateway(
    JNIEnv *, jobject) {
    return floe_secret_gateway_install();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_removeSecretGateway(
    JNIEnv *, jobject) {
    return floe_secret_gateway_remove();
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_submitSaveIntent(
    JNIEnv *env, jobject, jstring intentJSON, jbyteArray value) {
    // No C++ exception may unwind into the VM; all allocations/conversions
    // below are also exception-guarded in FloeUtf8FromJString.
    try {
        if (!intentJSON || !value) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        const jsize valueLength = env->GetArrayLength(value);
        if (valueLength <= 0) {
            FloeThrowStatus(env, -115);
            return nullptr;
        }
        if (valueLength > kMaximumSecretBytes) {
            FloeThrowStatus(env, -111);
            return nullptr;
        }
        std::string utf8;
        bool tooLarge = false;
        if (!FloeUtf8FromJString(env, intentJSON, kMaximumIntentJsonBytes, utf8,
                                 tooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeThrowStatus(env, tooLarge ? -116 : -110);
            return nullptr;
        }
        jbyte *elements = env->GetByteArrayElements(value, nullptr);
        if (!elements) {
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return nullptr;
        }
        char token[40];
        const int32_t result = floe_secret_save_intent_submit(
            utf8.c_str(), reinterpret_cast<const uint8_t *>(elements), valueLength,
            token, static_cast<int32_t>(sizeof(token)));
        env->ReleaseByteArrayElements(value, elements, JNI_ABORT);
        if (result != 0) {
            FloeThrowStatus(env, result);
            return nullptr;
        }
        if (!FloeAscii(token, static_cast<int32_t>(kIngressTokenLogicalBytes))) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        return env->NewStringUTF(token);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_discardSaveIntent(
    JNIEnv *env, jobject, jstring token) {
    try {
        if (!token) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        std::string utf8;
        bool tooLarge = false;
        if (!FloeUtf8FromJString(env, token, kMaximumTokenBytes, utf8, tooLarge)) {
            (void)tooLarge;  // token length/syntax failures share -105.
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return -105;
        }
        return floe_secret_save_intent_discard(utf8.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}

// Trusted host route authority. The App opens ONE route handle per live
// editor sheet, echoes it back at save-tap (assertion) and close (exact
// ownership). The native side injects the live route pair into the frozen
// intent; the App never supplies one.
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_openHostRoute(
    JNIEnv *env, jobject, jstring editorKind, jstring editorID,
    jlong uiGeneration, jlong expectedNativeRootEpoch) {
    try {
        if (!editorKind || !editorID || uiGeneration <= 0 || expectedNativeRootEpoch <= 0) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        std::string kind;
        std::string identity;
        bool tooLarge = false;
        if (!FloeUtf8FromJString(env, editorKind, 32, kind, tooLarge)) {
            (void)tooLarge;
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return nullptr;
        }
        if (!FloeUtf8FromJString(env, editorID, 128, identity, tooLarge)) {
            (void)tooLarge;
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return nullptr;
        }
        char token[64];
        const int32_t result = floe_host_route_open(
            kind.c_str(), identity.c_str(),
            static_cast<int64_t>(uiGeneration),
            static_cast<int64_t>(expectedNativeRootEpoch),
            token, static_cast<int32_t>(sizeof(token)));
        if (result != 0) {
            FloeThrowStatus(env, result);
            return nullptr;
        }
        return env->NewStringUTF(token);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_clearHostRoute(
    JNIEnv *env, jobject, jstring token) {
    try {
        if (!token) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        std::string utf8;
        bool tooLarge = false;
        if (!FloeUtf8FromJString(env, token, 64, utf8, tooLarge)) {
            (void)tooLarge;
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return -105;
        }
        return floe_host_route_clear(utf8.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SecretGatewayNative_submitHostSaveIntent(
    JNIEnv *env, jobject, jstring intentCoreJSON, jstring routeToken, jbyteArray value) {
    try {
        if (!intentCoreJSON || !routeToken || !value) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        const jsize valueLength = env->GetArrayLength(value);
        if (valueLength <= 0) {
            FloeThrowStatus(env, -115);
            return nullptr;
        }
        if (valueLength > kMaximumSecretBytes) {
            FloeThrowStatus(env, -111);
            return nullptr;
        }
        std::string core;
        bool tooLarge = false;
        if (!FloeUtf8FromJString(env, intentCoreJSON, kMaximumIntentJsonBytes, core,
                                 tooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeThrowStatus(env, tooLarge ? -116 : -110);
            return nullptr;
        }
        std::string route;
        if (!FloeUtf8FromJString(env, routeToken, kMaximumTokenBytes, route, tooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        jbyte *elements = env->GetByteArrayElements(value, nullptr);
        if (!elements) {
            if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
            return nullptr;
        }
        char token[40];
        const int32_t result = floe_host_save_intent_submit(
            core.c_str(), route.c_str(),
            reinterpret_cast<const uint8_t *>(elements), valueLength,
            token, static_cast<int32_t>(sizeof(token)));
        env->ReleaseByteArrayElements(value, elements, JNI_ABORT);
        if (result != 0) {
            FloeThrowStatus(env, result);
            return nullptr;
        }
        if (!FloeAscii(token, static_cast<int32_t>(kIngressTokenLogicalBytes))) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        return env->NewStringUTF(token);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return nullptr;
    }
}
