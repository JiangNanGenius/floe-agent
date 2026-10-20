// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — JNI adapter (NEW translation unit inside the
// EXISTING floe_jni target, added by the lane's narrow build patch). The
// frozen floe_jni.cpp, published floe_secret_jni.cpp and the reviewed
// floe_runtime_jni.cpp stay byte-identical.
//
// Discipline (mirrors the reviewed runtime-owner TU):
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * <=4 local refs per frame; ExceptionCheck after every allocating call;
//  * strict UTF-16 -> UTF-8 conversion (no CESU-8) for the two UNTRUSTED
//    hint strings only; receipts are strict ASCII;
//  * receipt/status strings are ASCII-validated before NewStringUTF;
//  * typed rejections become AttachmentStagingNativeException(status) —
//    never a silent null and never a path/URI/name inside the message;
//  * byte pumps use GetByteArrayElements(JNI_ABORT on release) for writes
//    and a scratch buffer + SetByteArrayRegion for reads; the Java array
//    contents never escape the frame.
//
// Lifecycle/file work is Swift-owned: every entry point maps to a Swift
// `_cdecl` that validates, locks briefly and returns. This source is
// UNCOMPILED in the authoring package; the serialized native qualification
// lane owns the actual build/link smoke.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>

extern "C" {
int32_t floe_staging_route_open(const char *conversationHex, uint64_t incarnation,
                                uint64_t draftRevision, int32_t isTemporary,
                                char *outReceipt, int32_t outCap);
int32_t floe_staging_route_close(const char *routeReceipt);
int32_t floe_staging_begin(const char *routeReceipt, const char *reusingStagingID,
                           char *outIngress, int32_t ingressCap,
                           char *outStagingID, int32_t stagingCap);
int32_t floe_staging_write(const char *ingressReceipt, const uint8_t *bytes,
                           int32_t length);
int32_t floe_staging_end(const char *ingressReceipt, const char *displayNameHint,
                         const char *mimeTypeHint, const char *kindHint);
int32_t floe_staging_abort(const char *ingressReceipt);
int32_t floe_staging_progress(const char *ingressReceipt, int64_t *outBytes,
                              int32_t *outFinished, int32_t *outCancelled);
int32_t floe_staging_read(const char *stagingHandle, int64_t offset,
                          uint8_t *outBuffer, int32_t capacity);
int32_t floe_attachment_read(const char *attachmentHex, const char *conversationHex,
                             int64_t offset, uint8_t *outBuffer, int32_t capacity);
int32_t floe_staging_status(char *buffer, int32_t capacity);
}

namespace {

constexpr int32_t kReceiptCapacity = 48;              // <prefix>:v1:+32hex+NUL
constexpr int32_t kIdentityCapacity = 48;             // UUID canonical spelling
constexpr int32_t kHintCapacity = 1024;               // display-name hint UTF-8
constexpr int32_t kMimeCapacity = 256;                // MIME hint UTF-8
constexpr int32_t kProgressCapacity = 48;             // "bytes f c" ASCII
constexpr int32_t kStatusCapacity = 16384;
constexpr int32_t kDescriptorCapacity = 256;          // exception message bound
constexpr int32_t kChunkCapacity = 65536;             // hard page bound

bool FloeStagingAscii(const char *data, int32_t length) {
    if (!data || length < 0) return false;
    for (int32_t index = 0; index < length; ++index) {
        if (static_cast<unsigned char>(data[index]) >= 0x80) return false;
    }
    return true;
}

// Rejects unpaired UTF-16 surrogates instead of accepting a partially
// converted prefix (same reviewed rule as the runtime-owner TU).
bool FloeStagingValidUtf16(const jchar *chars, jsize length) {
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
// GetStringUTFChars is deliberately NOT used (CESU-8 would mangle names).
bool FloeStagingUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
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
    if (!FloeStagingValidUtf16(chars, length)) {
        env->ReleaseStringChars(value, chars);
        return false;
    }
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    bool ok = true;
    std::u16string wide;
    wide.reserve(static_cast<size_t>(length));
    for (jsize index = 0; index < length; ++index) {
        wide.push_back(static_cast<char16_t>(chars[index]));
    }
    env->ReleaseStringChars(value, chars);
    try {
        output = convert.to_bytes(wide);
    } catch (...) {
        ok = false;
    }
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

void FloeStagingRaiseFallback(JNIEnv *env) {
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "staging_failure");
        env->DeleteLocalRef(fallback);
    }
}

// Typed rejection. Lookup failures are preserved, never cleared (same
// reviewed contract as the runtime-owner and gateway TUs). The exception
// message is a fixed literal: only the numeric status crosses back.
bool FloeStagingThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return false;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/AttachmentStagingNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                if (env->ExceptionCheck()) return true;
                FloeStagingRaiseFallback(env);
                return false;
            }
            if (!env->ExceptionCheck()) FloeStagingRaiseFallback(env);
            return false;
        }
        env->DeleteLocalRef(exceptionClass);
        if (env->ExceptionCheck()) return false;  // preserve NoSuchMethodError
    } else if (env->ExceptionCheck()) {
        return false;  // preserve NoClassDefFoundError/OOM
    }
    FloeStagingRaiseFallback(env);
    return env->ExceptionCheck();
}

// Strict-ASCII receipt extraction (never a path, never a URI): empty/over-
// length/non-ASCII are -105.
bool FloeStagingAsciiReceipt(JNIEnv *env, jstring value, int32_t cap,
                             std::string &output) {
    output.clear();
    if (!value) return false;
    const jsize length = env->GetStringLength(value);
    if (length <= 0 || length >= cap) {
        FloeStagingThrowStatus(env, -105);
        return false;
    }
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return false;
    const jsize bytes = static_cast<jsize>(strlen(chars));
    bool ok = bytes == length && FloeStagingAscii(chars, bytes);
    if (ok) output.assign(chars, static_cast<size_t>(bytes));
    env->ReleaseStringUTFChars(value, chars);
    if (!ok) {
        FloeStagingThrowStatus(env, -105);
        return false;
    }
    return true;
}

}  // namespace

// Route open. conversationHex may be null (new-composer route); isTemporary
// is carried verbatim so the Swift double-gate refuses temporary staging.
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingRouteOpen(
    JNIEnv *env, jobject, jstring conversationId, jlong incarnation,
    jlong draftRevision, jboolean isTemporary) {
    try {
        if (incarnation <= 0 || draftRevision < 0) {
            FloeStagingThrowStatus(env, -105);
            return nullptr;
        }
        std::string hex;
        const bool hasHex = conversationId != nullptr;
        if (hasHex && !FloeStagingAsciiReceipt(env, conversationId,
                                               kIdentityCapacity, hex)) {
            if (env->ExceptionCheck()) return nullptr;
            FloeStagingThrowStatus(env, -105);
            return nullptr;
        }
        char receipt[kReceiptCapacity];
        const int32_t status = floe_staging_route_open(
            hasHex ? hex.c_str() : nullptr,
            static_cast<uint64_t>(incarnation),
            static_cast<uint64_t>(draftRevision),
            isTemporary ? 1 : 0,
            receipt, kReceiptCapacity);
        if (status < 0) {
            FloeStagingThrowStatus(env, status);
            return nullptr;
        }
        const size_t receiptLength = strnlen(receipt, kReceiptCapacity);
        if (receiptLength == 0 || receiptLength >= kReceiptCapacity
                || !FloeStagingAscii(receipt, static_cast<int32_t>(receiptLength))) {
            FloeStagingThrowStatus(env, -399);
            return nullptr;
        }
        return env->NewStringUTF(receipt);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingRouteClose(
    JNIEnv *env, jobject, jstring routeReceipt) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, routeReceipt, kReceiptCapacity, receipt)) {
            return;
        }
        const int32_t status = floe_staging_route_close(receipt.c_str());
        if (status < 0) FloeStagingThrowStatus(env, status);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
    }
}

// Begin ingress. Returns "<ingress> <stagingID>" (two ASCII tokens).
extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingBegin(
    JNIEnv *env, jobject, jstring routeReceipt, jstring reusingStagingId) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, routeReceipt, kReceiptCapacity, receipt)) {
            return nullptr;
        }
        std::string reusing;
        const bool hasReusing = reusingStagingId != nullptr;
        if (hasReusing
                && !FloeStagingAsciiReceipt(env, reusingStagingId,
                                            kIdentityCapacity, reusing)) {
            return nullptr;
        }
        char ingress[kReceiptCapacity];
        char stagingId[kIdentityCapacity];
        const int32_t status = floe_staging_begin(
            receipt.c_str(), hasReusing ? reusing.c_str() : nullptr,
            ingress, kReceiptCapacity, stagingId, kIdentityCapacity);
        if (status < 0) {
            FloeStagingThrowStatus(env, status);
            return nullptr;
        }
        const size_t ingressLength = strnlen(ingress, kReceiptCapacity);
        const size_t stagingLength = strnlen(stagingId, kIdentityCapacity);
        if (ingressLength == 0 || ingressLength >= kReceiptCapacity
                || stagingLength == 0 || stagingLength >= kIdentityCapacity
                || !FloeStagingAscii(ingress, static_cast<int32_t>(ingressLength))
                || !FloeStagingAscii(stagingId, static_cast<int32_t>(stagingLength))) {
            FloeStagingThrowStatus(env, -399);
            return nullptr;
        }
        std::string joined;
        joined.reserve(ingressLength + 1 + stagingLength);
        joined.append(ingress, ingressLength);
        joined.push_back(' ');
        joined.append(stagingId, stagingLength);
        return env->NewStringUTF(joined.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
        return nullptr;
    }
}

// One bounded chunk of the actual stream. GetByteArrayElements is used in
// COPY mode and always released with JNI_ABORT (the array is never mutated).
extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingWrite(
    JNIEnv *env, jobject, jstring ingressReceipt, jbyteArray data,
    jint offset, jint length) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, ingressReceipt, kReceiptCapacity, receipt)) {
            return;
        }
        if (!data || offset < 0 || length <= 0
                || length > kChunkCapacity
                || static_cast<size_t>(offset) + static_cast<size_t>(length)
                       > static_cast<size_t>(env->GetArrayLength(data))) {
            if (env->ExceptionCheck()) return;
            FloeStagingThrowStatus(env, -105);
            return;
        }
        jbyte *bytes = env->GetByteArrayElements(data, nullptr);
        if (!bytes) return;  // pending OOM exception preserved
        const int32_t status = floe_staging_write(
            receipt.c_str(),
            reinterpret_cast<const uint8_t *>(bytes) + offset,
            static_cast<int32_t>(length));
        env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
        if (status < 0) FloeStagingThrowStatus(env, status);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
    }
}

// EOF. The two hints are UNTRUSTED display strings: strict UTF-16 ->
// UTF-8, capped, NUL-free; Swift sanitizes/clamps them again. kindHint is
// not passed from Java at all (the native derives it — no fourth channel).
extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingEnd(
    JNIEnv *env, jobject, jstring ingressReceipt, jstring displayNameHint,
    jstring mimeTypeHint) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, ingressReceipt, kReceiptCapacity, receipt)) {
            return;
        }
        std::string name;
        if (displayNameHint) {
            bool tooLarge = false;
            if (!FloeStagingUtf8FromJString(env, displayNameHint,
                                            static_cast<size_t>(kHintCapacity) - 1,
                                            name, tooLarge)) {
                if (env->ExceptionCheck()) return;
                // An over-cap hint is a typed shape refusal; an invalidly
                // encoded hint degrades to "no hint" (the native fallback
                // name applies). Neither path ever leaks the bytes.
                if (tooLarge) {
                    FloeStagingThrowStatus(env, -105);
                    return;
                }
                name.clear();
            }
        }
        std::string mime;
        if (mimeTypeHint) {
            bool tooLarge = false;
            if (!FloeStagingUtf8FromJString(env, mimeTypeHint,
                                            static_cast<size_t>(kMimeCapacity) - 1,
                                            mime, tooLarge)) {
                if (env->ExceptionCheck()) return;
                if (tooLarge) {
                    FloeStagingThrowStatus(env, -105);
                    return;
                }
                mime.clear();
            }
        }
        const int32_t status = floe_staging_end(
            receipt.c_str(),
            name.empty() ? nullptr : name.c_str(),
            mime.empty() ? nullptr : mime.c_str(),
            nullptr);
        if (status < 0) FloeStagingThrowStatus(env, status);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingAbort(
    JNIEnv *env, jobject, jstring ingressReceipt) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, ingressReceipt, kReceiptCapacity, receipt)) {
            return;
        }
        const int32_t status = floe_staging_abort(receipt.c_str());
        if (status < 0) FloeStagingThrowStatus(env, status);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingProgress(
    JNIEnv *env, jobject, jstring ingressReceipt) {
    try {
        std::string receipt;
        if (!FloeStagingAsciiReceipt(env, ingressReceipt, kReceiptCapacity, receipt)) {
            return nullptr;
        }
        int64_t bytes = 0;
        int32_t finished = 0;
        int32_t cancelled = 0;
        const int32_t status = floe_staging_progress(receipt.c_str(), &bytes,
                                                      &finished, &cancelled);
        if (status < 0) {
            FloeStagingThrowStatus(env, status);
            return nullptr;
        }
        char buffer[kProgressCapacity];
        const int written = snprintf(buffer, sizeof(buffer), "%lld %d %d",
                                     static_cast<long long>(bytes),
                                     static_cast<int>(finished),
                                     static_cast<int>(cancelled));
        if (written <= 0 || written >= static_cast<int>(sizeof(buffer))
                || !FloeStagingAscii(buffer, written)) {
            FloeStagingThrowStatus(env, -399);
            return nullptr;
        }
        return env->NewStringUTF(buffer);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
        return nullptr;
    }
}

// Bounded staged preview page. Copies into the caller's array via a scratch
// buffer (never GetByteArrayElements write-back). Returns the copied count
// (>=0, 0=EOF) or throws for a negative typed status.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingRead(
    JNIEnv *env, jobject, jstring stagingHandle, jlong offset, jbyteArray out) {
    try {
        std::string handle;
        if (!FloeStagingAsciiReceipt(env, stagingHandle, kReceiptCapacity, handle)) {
            return -105;
        }
        if (!out || offset < 0) {
            FloeStagingThrowStatus(env, -105);
            return -105;
        }
        const jsize capacity = env->GetArrayLength(out);
        if (capacity <= 0 || capacity > kChunkCapacity) {
            FloeStagingThrowStatus(env, -105);
            return -105;
        }
        std::vector<uint8_t> scratch(static_cast<size_t>(capacity));
        const int32_t copied = floe_staging_read(handle.c_str(),
                                                 static_cast<int64_t>(offset),
                                                 scratch.data(),
                                                 static_cast<int32_t>(capacity));
        if (copied < 0) {
            FloeStagingThrowStatus(env, copied);
            return copied;
        }
        if (copied > 0) {
            env->SetByteArrayRegion(out, 0, static_cast<jsize>(copied),
                                    reinterpret_cast<const jbyte *>(scratch.data()));
            if (env->ExceptionCheck()) return -399;
        }
        return static_cast<jint>(copied);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
        return -399;
    }
}

// Bounded committed-attachment page (requires the live read grant).
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_attachmentRead(
    JNIEnv *env, jobject, jstring attachmentId, jstring conversationId,
    jlong offset, jbyteArray out) {
    try {
        std::string attachmentHex;
        if (!FloeStagingAsciiReceipt(env, attachmentId, kIdentityCapacity,
                                     attachmentHex)) {
            return -105;
        }
        std::string conversationHex;
        if (!FloeStagingAsciiReceipt(env, conversationId, kIdentityCapacity,
                                     conversationHex)) {
            return -105;
        }
        if (!out || offset < 0) {
            FloeStagingThrowStatus(env, -105);
            return -105;
        }
        const jsize capacity = env->GetArrayLength(out);
        if (capacity <= 0 || capacity > kChunkCapacity) {
            FloeStagingThrowStatus(env, -105);
            return -105;
        }
        std::vector<uint8_t> scratch(static_cast<size_t>(capacity));
        const int32_t copied = floe_attachment_read(
            attachmentHex.c_str(), conversationHex.c_str(),
            static_cast<int64_t>(offset), scratch.data(),
            static_cast<int32_t>(capacity));
        if (copied < 0) {
            FloeStagingThrowStatus(env, copied);
            return copied;
        }
        if (copied > 0) {
            env->SetByteArrayRegion(out, 0, static_cast<jsize>(copied),
                                    reinterpret_cast<const jbyte *>(scratch.data()));
            if (env->ExceptionCheck()) return -399;
        }
        return static_cast<jint>(copied);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeStagingThrowStatus(env, -399);
        return -399;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_AttachmentStagingNative_stagingStatus(
    JNIEnv *env, jobject) {
    try {
        std::vector<char> buffer(kStatusCapacity);
        const int32_t status = floe_staging_status(buffer.data(), kStatusCapacity);
        if (status == -106) {
            // The snapshot exceeded the fixed buffer: return null (unknown),
            // never a truncated frame and never a fabricated summary.
            return nullptr;
        }
        const size_t length = strnlen(buffer.data(), kStatusCapacity);
        if (length == 0 || length >= static_cast<size_t>(kStatusCapacity)
                || !FloeStagingAscii(buffer.data(), static_cast<int32_t>(length))) {
            return nullptr;
        }
        return env->NewStringUTF(buffer.data());
    } catch (...) {
        if (!env->ExceptionCheck()) {
            // Status is read-only diagnostics; an internal error here
            // surfaces as null, not as a thrown exception.
        }
        return nullptr;
    }
}
