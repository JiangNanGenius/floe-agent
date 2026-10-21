// SPDX-License-Identifier: MPL-2.0
//
// S11 Skills folder staging — JNI adapter (NEW translation unit inside the
// EXISTING floe_jni target, appended by the lane's narrow CMake patch; the
// frozen floe_jni.cpp and every published/accepted wrapper file stay
// byte-identical).
//
// Discipline (mirrors the reviewed attachment-staging TU exactly):
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * <=4 local refs per frame; ExceptionCheck after every allocating call;
//  * strict UTF-16 -> UTF-8 conversion (no CESU-8) for the display hints
//    only; receipts and relative paths are strict printable ASCII;
//  * receipt/token strings are ASCII-validated before NewStringUTF;
//  * typed rejections become SkillsFolderStagingNativeException(status) —
//    never a silent null and never a path/URI/name inside the message;
//  * the byte pump uses GetByteArrayElements (JNI_ABORT on release, so the
//    Java array contents never escape or get modified) for one bounded
//    chunk (<= 64 KiB) at a time; no whole-file buffering, no base64,
//    no JSON.
//
// Lifecycle/file work is Swift-owned (RuntimeFacadeSkillsFolderHost):
// every entry point maps to a Swift `_cdecl` that validates, locks briefly
// and returns. This source is UNCOMPILED in the authoring package; the
// serialized native qualification lane owns the actual build/link smoke.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>

extern "C" {
int32_t floe_skills_folder_route_open(uint64_t incarnation, uint64_t uiGeneration,
                                      uint64_t rootEpoch,
                                      char *outReceipt, int32_t outCap);
int32_t floe_skills_folder_route_close(const char *routeReceipt);
int32_t floe_skills_folder_tree_open(const char *routeReceipt, const char *nameHint,
                                     char *outTree, int32_t outCap);
int32_t floe_skills_folder_file_begin(const char *treeReceipt, const char *relativePath,
                                      char *outFile, int32_t outCap);
int32_t floe_skills_folder_file_write(const char *fileReceipt, const uint8_t *bytes,
                                      int32_t length);
int32_t floe_skills_folder_file_end(const char *fileReceipt);
int32_t floe_skills_folder_file_abort(const char *fileReceipt);
int32_t floe_skills_folder_tree_finish(const char *treeReceipt, const char *nameHint,
                                       char *outLine, int32_t outCap);
int32_t floe_skills_folder_tree_abort(const char *treeReceipt);
int32_t floe_skills_folder_status(char *buffer, int32_t capacity);
}

namespace {

constexpr int32_t kReceiptCapacity = 48;   // <3-char prefix>:v1:+32hex+NUL
constexpr int32_t kLineCapacity = 96;      // "stg:v1:<32hex> <count> <bytes>"
constexpr int32_t kPathCapacity = 512;     // validator relative-path cap
constexpr int32_t kHintCapacity = 1024;    // display-name hint UTF-8
constexpr int32_t kStatusCapacity = 16384;
constexpr int32_t kChunkCapacity = 65536;  // hard page bound

// Typed folder-staging status mirror (SkillsFolderHostStatus in Swift).
constexpr int32_t kStatusInvalidArguments = -400;
constexpr int32_t kStatusInternal = -499;

bool FloeFolderAscii(const char *data, int32_t length) {
    if (!data || length < 0) return false;
    for (int32_t index = 0; index < length; ++index) {
        if (static_cast<unsigned char>(data[index]) >= 0x80) return false;
    }
    return true;
}

// Rejects unpaired UTF-16 surrogates instead of accepting a partially
// converted prefix (same reviewed rule as the attachment/runtime TUs).
bool FloeFolderValidUtf16(const jchar *chars, jsize length) {
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
bool FloeFolderUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
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
    if (!FloeFolderValidUtf16(chars, length)) {
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

void FloeFolderRaiseFallback(JNIEnv *env) {
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "folder_staging_failure");
        env->DeleteLocalRef(fallback);
    }
}

// Typed rejection. Lookup failures are preserved, never cleared (same
// reviewed contract as the attachment TU). The exception message is a
// fixed literal: only the numeric status crosses back.
bool FloeFolderThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return false;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/SkillsFolderStagingNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                if (env->ExceptionCheck()) return true;
                FloeFolderRaiseFallback(env);
                return false;
            }
            if (!env->ExceptionCheck()) FloeFolderRaiseFallback(env);
            return false;
        }
        env->DeleteLocalRef(exceptionClass);
        if (env->ExceptionCheck()) return false;  // preserve NoSuchMethodError
    } else if (env->ExceptionCheck()) {
        return false;  // preserve NoClassDefFoundError/OOM
    }
    FloeFolderRaiseFallback(env);
    return env->ExceptionCheck();
}

// Strict-ASCII receipt/path extraction (never a filesystem path with
// separators beyond the validated relative form, never a URI): empty/over-
// length/non-ASCII are -400.
bool FloeFolderAsciiReceipt(JNIEnv *env, jstring value, int32_t cap,
                            std::string &output) {
    output.clear();
    if (!value) return false;
    const jsize length = env->GetStringLength(value);
    if (length <= 0 || length >= cap) {
        FloeFolderThrowStatus(env, kStatusInvalidArguments);
        return false;
    }
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return false;
    const jsize bytes = static_cast<jsize>(strlen(chars));
    bool ok = bytes == length && FloeFolderAscii(chars, bytes);
    if (ok) output.assign(chars, static_cast<size_t>(bytes));
    env->ReleaseStringUTFChars(value, chars);
    if (!ok) {
        FloeFolderThrowStatus(env, kStatusInvalidArguments);
        return false;
    }
    return true;
}

// A receipt-shaped token for an OPTIONAL display hint (null allowed).
// Oversize/unpaired names are typed -400 refusals, never truncation.
bool FloeFolderOptionalHint(JNIEnv *env, jstring value, std::string &output) {
    output.clear();
    if (!value) return true;
    bool tooLarge = false;
    if (!FloeFolderUtf8FromJString(env, value, kHintCapacity, output, tooLarge)) {
        FloeFolderThrowStatus(env, kStatusInvalidArguments);
        return false;
    }
    if (tooLarge) {
        output.clear();
        FloeFolderThrowStatus(env, kStatusInvalidArguments);
        return false;
    }
    return true;
}

jstring FloeFolderCopyResult(JNIEnv *env, const char *value, size_t cap,
                             int32_t status) {
    if (status >= 0) {
        const size_t length = strnlen(value, cap);
        if (length > 0 && length < cap && FloeFolderAscii(value,
                                                          static_cast<int32_t>(length))) {
            return env->NewStringUTF(value);
        }
    }
    if (!env->ExceptionCheck()) FloeFolderThrowStatus(env, status < 0 ? status
                                                                      : kStatusInternal);
    return nullptr;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderRouteOpen(
    JNIEnv *env, jobject, jlong incarnation, jlong uiGeneration, jlong rootEpoch) {
    try {
        if (incarnation <= 0 || uiGeneration <= 0 || rootEpoch <= 0) {
            FloeFolderThrowStatus(env, kStatusInvalidArguments);
            return nullptr;
        }
        char receipt[kReceiptCapacity];
        const int32_t status = floe_skills_folder_route_open(
            static_cast<uint64_t>(incarnation),
            static_cast<uint64_t>(uiGeneration),
            static_cast<uint64_t>(rootEpoch),
            receipt, kReceiptCapacity);
        return FloeFolderCopyResult(env, receipt, kReceiptCapacity, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderRouteClose(
    JNIEnv *env, jobject, jstring routeReceipt) {
    try {
        std::string receipt;
        if (!FloeFolderAsciiReceipt(env, routeReceipt, kReceiptCapacity, receipt)) {
            return;  // typed exception already raised (or preserved)
        }
        const int32_t status = floe_skills_folder_route_close(receipt.c_str());
        if (status < 0) FloeFolderThrowStatus(env, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderTreeOpen(
    JNIEnv *env, jobject, jstring routeReceipt, jstring displayNameHint) {
    try {
        std::string receipt;
        if (!FloeFolderAsciiReceipt(env, routeReceipt, kReceiptCapacity, receipt)) {
            return nullptr;
        }
        std::string hint;
        if (!FloeFolderOptionalHint(env, displayNameHint, hint)) return nullptr;
        char tree[kReceiptCapacity];
        const int32_t status = floe_skills_folder_tree_open(
            receipt.c_str(), hint.empty() ? nullptr : hint.c_str(),
            tree, kReceiptCapacity);
        return FloeFolderCopyResult(env, tree, kReceiptCapacity, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderFileBegin(
    JNIEnv *env, jobject, jstring treeHandle, jstring relativePath) {
    try {
        std::string tree;
        if (!FloeFolderAsciiReceipt(env, treeHandle, kReceiptCapacity, tree)) {
            return nullptr;
        }
        // The RELATIVE path is user-visible content naming (the ORIGINAL
        // validator permits Unicode segments and rejects traversal/
        // separators/backslash/control itself). It crosses as strict
        // UTF-8 (CESU-8 rejected) like the display hints; receipts stay
        // strict ASCII. An over-length or unpaired-surrogate name is a
        // typed -400 refusal, never a silent truncation.
        std::string path;
        bool tooLarge = false;
        if (!relativePath ||
            !FloeFolderUtf8FromJString(env, relativePath, kPathCapacity - 1, path, tooLarge) ||
            tooLarge || path.empty()) {
            if (!env->ExceptionCheck()) FloeFolderThrowStatus(env, kStatusInvalidArguments);
            return nullptr;
        }
        char file[kReceiptCapacity];
        const int32_t status = floe_skills_folder_file_begin(
            tree.c_str(), path.c_str(), file, kReceiptCapacity);
        return FloeFolderCopyResult(env, file, kReceiptCapacity, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderFileWrite(
    JNIEnv *env, jobject, jstring fileHandle, jbyteArray data,
    jint offset, jint length) {
    try {
        std::string receipt;
        if (!FloeFolderAsciiReceipt(env, fileHandle, kReceiptCapacity, receipt)) {
            return;
        }
        if (data == nullptr || offset < 0 || length <= 0 ||
            length > kChunkCapacity) {
            FloeFolderThrowStatus(env, kStatusInvalidArguments);
            return;
        }
        const jsize arrayLength = env->GetArrayLength(data);
        if (offset > arrayLength ||
            static_cast<jsize>(offset) + static_cast<jsize>(length) > arrayLength) {
            FloeFolderThrowStatus(env, kStatusInvalidArguments);
            return;
        }
        // JNI_ABORT release: the Java array is a pure INPUT stream and its
        // contents never escape this frame (same rule as the attachment
        // write pump).
        jbyte *elements = env->GetByteArrayElements(data, nullptr);
        if (elements == nullptr) return;  // preserve OOM
        const int32_t status = floe_skills_folder_file_write(
            receipt.c_str(),
            reinterpret_cast<const uint8_t *>(elements + offset),
            length);
        env->ReleaseByteArrayElements(data, elements, JNI_ABORT);
        if (status < 0) FloeFolderThrowStatus(env, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderFileEnd(
    JNIEnv *env, jobject, jstring fileHandle) {
    try {
        std::string receipt;
        if (!FloeFolderAsciiReceipt(env, fileHandle, kReceiptCapacity, receipt)) {
            return;
        }
        const int32_t status = floe_skills_folder_file_end(receipt.c_str());
        if (status < 0) FloeFolderThrowStatus(env, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderFileAbort(
    JNIEnv *env, jobject, jstring fileHandle) {
    try {
        std::string receipt;
        if (!FloeFolderAsciiReceipt(env, fileHandle, kReceiptCapacity, receipt)) {
            return;
        }
        const int32_t status = floe_skills_folder_file_abort(receipt.c_str());
        if (status < 0) FloeFolderThrowStatus(env, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderTreeFinish(
    JNIEnv *env, jobject, jstring treeHandle, jstring displayNameHint) {
    try {
        std::string tree;
        if (!FloeFolderAsciiReceipt(env, treeHandle, kReceiptCapacity, tree)) {
            return nullptr;
        }
        std::string hint;
        if (!FloeFolderOptionalHint(env, displayNameHint, hint)) return nullptr;
        char line[kLineCapacity];
        const int32_t status = floe_skills_folder_tree_finish(
            tree.c_str(), hint.empty() ? nullptr : hint.c_str(),
            line, kLineCapacity);
        return FloeFolderCopyResult(env, line, kLineCapacity, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderTreeAbort(
    JNIEnv *env, jobject, jstring treeHandle) {
    try {
        std::string tree;
        if (!FloeFolderAsciiReceipt(env, treeHandle, kReceiptCapacity, tree)) {
            return;
        }
        const int32_t status = floe_skills_folder_tree_abort(tree.c_str());
        if (status < 0) FloeFolderThrowStatus(env, status);
    } catch (...) {
        FloeFolderThrowStatus(env, kStatusInternal);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SkillsFolderStagingNative_folderStagingStatus(
    JNIEnv *env, jobject) {
    try {
        std::vector<char> buffer(kStatusCapacity);
        const int32_t status = floe_skills_folder_status(
            buffer.data(), static_cast<int32_t>(buffer.size()));
        if (status < 0) return nullptr;  // null = unknown, never a ready lie
        const size_t length = strnlen(buffer.data(), buffer.size());
        if (length == 0 || length >= buffer.size()) return nullptr;
        if (!FloeFolderAscii(buffer.data(), static_cast<int32_t>(length))) {
            return nullptr;
        }
        return env->NewStringUTF(buffer.data());
    } catch (...) {
        if (!env->ExceptionCheck()) {
            jclass fallback = env->FindClass("java/lang/IllegalStateException");
            if (fallback) {
                env->ThrowNew(fallback, "folder_status_failure");
                env->DeleteLocalRef(fallback);
            }
        }
        return nullptr;
    }
}
