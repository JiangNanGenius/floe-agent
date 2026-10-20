// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — JNI adapter (NEW translation unit inside the
// EXISTING floe_jni target). The frozen floe_jni.cpp, the published
// floe_secret_jni.cpp and every original Swift/Kotlin authority stay
// byte-identical.
//
// Discipline (mirrors the reviewed gateway TU):
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * <=4 local refs per frame; ExceptionCheck after every allocating call;
//  * strict UTF-16 -> UTF-8 conversion (no CESU-8/modified-UTF-8) so a
//    legitimate non-ASCII app-private path survives or fails typed;
//  * receipt/status strings are ASCII-validated before NewStringUTF;
//  * typed rejections become RuntimeNativeException(status) — never a
//    silent null and never a path/secret inside the message.
//
// Lifecycle work itself is Swift-owned: every entry point here maps to a
// Swift `_cdecl` that only validates, enqueues and returns. This source is
// UNCOMPILED in the source-authoring package; the serialized native
// qualification package owns the actual build/link smoke.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>

extern "C" {
int32_t floe_runtime_owner_start(const char *rootPath, const char *ownerToken,
                                 uint64_t epoch, char *outReceipt, int32_t outCap);
int32_t floe_runtime_owner_stop(uint64_t expectedEpoch, const char *ownerToken,
                                char *outReceipt, int32_t outCap);
int32_t floe_runtime_status(char *buffer, int32_t capacity);
// G02 production-composition narrow trusted-host readbacks (job
// 7cd349b4cd6d4b55). Additive only: no existing symbol changes.
int32_t floe_g02_native_root_epoch(char *buffer, int32_t capacity);
int32_t floe_g02_domain_readiness(char *buffer, int32_t capacity);
}

namespace {

constexpr int32_t kReceiptCapacity = 40;            // op:v1: + 32hex + NUL
constexpr int32_t kRootCapacity = 4096;             // logical UTF-8 bytes
constexpr int32_t kTokenCapacity = 64;              // hex characters
constexpr int32_t kStatusCapacity = 16384;
constexpr int32_t kDescriptorCapacity = 256;        // exception message bound

bool FloeRuntimeAscii(const char *data, int32_t length) {
    if (!data || length < 0) return false;
    for (int32_t index = 0; index < length; ++index) {
        if (static_cast<unsigned char>(data[index]) >= 0x80) return false;
    }
    return true;
}

// Rejects unpaired UTF-16 surrogates instead of accepting a partially
// converted prefix (same reviewed rule as the gateway TU).
bool FloeRuntimeValidUtf16(const jchar *chars, jsize length) {
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

// Converts a Java UTF-16 string to strict UTF-8 with an explicit byte cap.
// GetStringUTFChars is deliberately NOT used (CESU-8 would break paths).
bool FloeRuntimeUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
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
        if (FloeRuntimeValidUtf16(chars, length)) {
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

void FloeRuntimeRaiseFallback(JNIEnv *env) {
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "runtime_bootstrap_failure");
        env->DeleteLocalRef(fallback);
    }
}

// Typed rejection. Lookup failures are preserved, never cleared (same
// reviewed contract as the gateway TU).
bool FloeRuntimeThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return false;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/RuntimeNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                if (env->ExceptionCheck()) return true;
                FloeRuntimeRaiseFallback(env);
                return false;
            }
            if (!env->ExceptionCheck()) FloeRuntimeRaiseFallback(env);
            return false;
        }
        env->DeleteLocalRef(exceptionClass);
        if (env->ExceptionCheck()) return false;  // preserve NoSuchMethodError
    } else if (env->ExceptionCheck()) {
        return false;  // preserve NoClassDefFoundError/OOM
    }
    FloeRuntimeRaiseFallback(env);
    return env->ExceptionCheck();
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RuntimeCoreNative_runtimeOwnerStart(
    JNIEnv *env, jobject, jstring rootPath, jstring ownerToken, jlong epoch) {
    try {
        if (!rootPath || !ownerToken || epoch <= 0) {
            FloeRuntimeThrowStatus(env, -105);
            return nullptr;
        }
        std::string root;
        bool rootTooLarge = false;
        if (!FloeRuntimeUtf8FromJString(env, rootPath, kRootCapacity, root,
                                        rootTooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeRuntimeThrowStatus(env, rootTooLarge ? -201 : -105);
            return nullptr;
        }
        std::string token;
        bool tokenTooLarge = false;
        if (!FloeRuntimeUtf8FromJString(env, ownerToken, kTokenCapacity, token,
                                         tokenTooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeRuntimeThrowStatus(env, tokenTooLarge ? -202 : -105);
            return nullptr;
        }
        if (!FloeRuntimeAscii(token.c_str(),
                              static_cast<int32_t>(token.size()))) {
            FloeRuntimeThrowStatus(env, -202);
            return nullptr;
        }
        char receipt[kReceiptCapacity];
        const int32_t status = floe_runtime_owner_start(
            root.c_str(), token.c_str(), static_cast<uint64_t>(epoch),
            receipt, kReceiptCapacity);
        if (status < 0) {
            FloeRuntimeThrowStatus(env, status);
            return nullptr;
        }
        const size_t receiptLength = strnlen(receipt, kReceiptCapacity);
        if (receiptLength == 0 || receiptLength >= kReceiptCapacity
                || !FloeRuntimeAscii(receipt, static_cast<int32_t>(receiptLength))) {
            FloeRuntimeThrowStatus(env, -299);
            return nullptr;
        }
        return env->NewStringUTF(receipt);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeRuntimeThrowStatus(env, -299);
        return nullptr;
    }
}

// RB1-R5: the expected accepted owner epoch + token are part of the trusted
// stop seam. A stale coordinator cannot stop a newer generation; only the
// numeric status crosses back (never a path or token).
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RuntimeCoreNative_runtimeOwnerStop(
    JNIEnv *env, jobject, jlong expectedEpoch, jstring ownerToken) {
    try {
        if (!ownerToken || expectedEpoch <= 0) {
            FloeRuntimeThrowStatus(env, -105);
            return nullptr;
        }
        std::string token;
        bool tokenTooLarge = false;
        if (!FloeRuntimeUtf8FromJString(env, ownerToken, kTokenCapacity, token,
                                         tokenTooLarge)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeRuntimeThrowStatus(env, tokenTooLarge ? -202 : -105);
            return nullptr;
        }
        if (!FloeRuntimeAscii(token.c_str(),
                              static_cast<int32_t>(token.size()))) {
            FloeRuntimeThrowStatus(env, -202);
            return nullptr;
        }
        char receipt[kReceiptCapacity];
        const int32_t status = floe_runtime_owner_stop(
            static_cast<uint64_t>(expectedEpoch), token.c_str(),
            receipt, kReceiptCapacity);
        if (status < 0) {
            FloeRuntimeThrowStatus(env, status);
            return nullptr;
        }
        const size_t receiptLength = strnlen(receipt, kReceiptCapacity);
        if (receiptLength == 0 || receiptLength >= kReceiptCapacity
                || !FloeRuntimeAscii(receipt, static_cast<int32_t>(receiptLength))) {
            FloeRuntimeThrowStatus(env, -299);
            return nullptr;
        }
        return env->NewStringUTF(receipt);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeRuntimeThrowStatus(env, -299);
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RuntimeCoreNative_runtimeStatus(
    JNIEnv *env, jobject) {
    char buffer[kStatusCapacity];
    const int32_t length = floe_runtime_status(buffer, kStatusCapacity);
    if (length < 0 || length >= kStatusCapacity) return nullptr;
    if (!FloeRuntimeAscii(buffer, length)) return nullptr;
    return env->NewStringUTF(buffer);
}

// G02: ACTUAL trusted native root-generation epoch as a decimal string.
// Null for every non-accepted status (the host fails closed; it never binds
// a fabricated 0 and never echoes the UI holder counter).
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RuntimeCoreNative_g02NativeRootEpoch(
    JNIEnv *env, jobject) {
    char buffer[32];
    const int32_t length = floe_g02_native_root_epoch(buffer, sizeof(buffer));
    if (length <= 0 || length >= static_cast<int32_t>(sizeof(buffer))) {
        return nullptr;
    }
    if (!FloeRuntimeAscii(buffer, length)) return nullptr;
    return env->NewStringUTF(buffer);
}

// G02: per-domain readiness snapshot (real registry + constructor state).
// Null when no generation is installed; the host treats that as unknown.
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_RuntimeCoreNative_g02DomainReadiness(
    JNIEnv *env, jobject) {
    char buffer[kStatusCapacity];
    const int32_t length = floe_g02_domain_readiness(buffer, kStatusCapacity);
    if (length <= 0 || length >= kStatusCapacity) return nullptr;
    if (!FloeRuntimeAscii(buffer, length)) return nullptr;
    return env->NewStringUTF(buffer);
}
