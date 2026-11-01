// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 trusted-host JNI wrapper for cloud-generation foreground ownership.
// The Kotlin App host calls these functions after its non-exported `dataSync`
// service confirmed a REAL startForeground success (register) or failed
// (deny). Every job/epoch/project/token decision lives in FloeAndroidCore;
// this file only bounds and forwards NUL-terminated ASCII arguments.
//
// Discipline: no global refs, no AttachCurrentThread, no Swift -> JVM callback.
#include <jni.h>
#include <cstdint>
#include <string>

extern "C" {
int32_t floe_generation_foreground_register(const char *, uint64_t,
                                            const char *, const char *);
int32_t floe_generation_foreground_deny(const char *, uint64_t, const char *);
int32_t floe_generation_foreground_release(const char *, uint64_t,
                                           const char *);
int32_t floe_generation_foreground_cancel(const char *, uint64_t,
                                          const char *);
int32_t floe_generation_foreground_poll(const char *, uint64_t, const char *);
int32_t floe_generation_foreground_snapshot(const char *, uint64_t,
                                            const char *, char *, int32_t);
int32_t floe_generation_foreground_count(uint64_t);
int32_t floe_generation_foreground_release_all(uint64_t);
}

namespace {

constexpr jsize kMaximumIdentifier = 36;
constexpr jsize kMaximumToken = 64;
constexpr jsize kMaximumReason = 32;
constexpr jsize kMaximumSnapshot = 256;

bool readBounded(JNIEnv *env, jstring value, jsize maximum,
                 std::string &out) {
    if (value == nullptr) return false;
    const jsize length = env->GetStringUTFLength(value);
    if (length <= 0 || length > maximum) return false;
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return false;
    out.assign(chars, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(value, chars);
    return true;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_register(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring projectID,
    jstring token) {
    std::string job, project, hostToken;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, projectID, kMaximumIdentifier, project) ||
        !readBounded(env, token, kMaximumToken, hostToken)) {
        return -101;
    }
    if (epoch <= 0) return -101;
    return floe_generation_foreground_register(
        job.c_str(), static_cast<uint64_t>(epoch), project.c_str(),
        hostToken.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_deny(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring reason) {
    std::string job, text;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, reason, kMaximumReason, text)) {
        return -101;
    }
    if (epoch <= 0) return -101;
    return floe_generation_foreground_deny(
        job.c_str(), static_cast<uint64_t>(epoch), text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_release(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring token) {
    std::string job, hostToken;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, token, kMaximumToken, hostToken)) {
        return -101;
    }
    if (epoch <= 0) return -101;
    return floe_generation_foreground_release(
        job.c_str(), static_cast<uint64_t>(epoch), hostToken.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_cancel(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring token) {
    std::string job, hostToken;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, token, kMaximumToken, hostToken)) {
        return -101;
    }
    if (epoch <= 0) return -101;
    return floe_generation_foreground_cancel(
        job.c_str(), static_cast<uint64_t>(epoch), hostToken.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_poll(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring token) {
    std::string job, hostToken;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, token, kMaximumToken, hostToken)) {
        return -101;
    }
    if (epoch <= 0) return -101;
    return floe_generation_foreground_poll(
        job.c_str(), static_cast<uint64_t>(epoch), hostToken.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_snapshot(
    JNIEnv *env, jobject, jstring jobID, jlong epoch, jstring token) {
    std::string job, hostToken;
    if (!readBounded(env, jobID, kMaximumIdentifier, job) ||
        !readBounded(env, token, kMaximumToken, hostToken) ||
        epoch <= 0) {
        return nullptr;
    }
    char output[kMaximumSnapshot + 1] = {};
    const int32_t count = floe_generation_foreground_snapshot(
        job.c_str(), static_cast<uint64_t>(epoch), hostToken.c_str(), output,
        kMaximumSnapshot);
    if (count <= 0 || count > kMaximumSnapshot) return nullptr;
    for (int32_t index = 0; index < count; ++index) {
        if (output[index] == 0 || static_cast<uint8_t>(output[index]) >= 128) {
            return nullptr;
        }
    }
    output[count] = 0;
    return env->NewStringUTF(output);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_count(
    JNIEnv *, jobject, jlong epoch) {
    if (epoch <= 0) return 0;
    return floe_generation_foreground_count(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_GenerationForegroundNative_releaseAll(
    JNIEnv *, jobject, jlong epoch) {
    if (epoch <= 0) return 0;
    return floe_generation_foreground_release_all(
        static_cast<uint64_t>(epoch));
}
