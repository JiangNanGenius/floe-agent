// SPDX-License-Identifier: MPL-2.0
//
// C06 calendar provider mailbox JNI wrapper.
//
// Swift owns the bounded JSON ticket table; the App host lane owns every real
// CalendarContract query/write. This additive TU only copies bounded JSON
// strings/bytes between the two. It interprets no calendar content, provider
// URI, permission or model tool request.
//
// Additive TU in the existing floe_jni target; no prior wrapper changes.

#include <jni.h>
#include <cstdint>
#include <string>
#include <vector>

extern "C" int32_t floe_calendar_host_bind(uint64_t epoch);
extern "C" int32_t floe_calendar_host_lane_ready(uint64_t epoch);
extern "C" int64_t floe_calendar_host_next(int32_t timeout_millis);
extern "C" int32_t floe_calendar_host_describe(int64_t claim, char *buffer, int32_t capacity);
extern "C" int32_t floe_calendar_host_complete(int64_t claim, int32_t status,
                                               const uint8_t *data, int32_t length);
extern "C" int32_t floe_calendar_host_should_stop(int64_t claim);
extern "C" int32_t floe_calendar_host_close_all(int32_t timeout_millis);
extern "C" int32_t floe_calendar_host_lane_closed(uint64_t epoch);
extern "C" int32_t floe_calendar_host_stats(char *buffer, int32_t capacity);

namespace {
constexpr jsize kDescribeCapacity = 16384;
constexpr jsize kStatsCapacity = 4096;
constexpr jsize kMaximumReply = 49152;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_bind(
        JNIEnv *, jobject, jlong epoch) {
    return floe_calendar_host_bind(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_laneReady(
        JNIEnv *, jobject, jlong epoch) {
    return floe_calendar_host_lane_ready(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_next(
        JNIEnv *, jobject, jint timeoutMillis) {
    return floe_calendar_host_next(timeoutMillis);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_describe(
        JNIEnv *env, jobject, jlong claim) {
    std::vector<char> staging(kDescribeCapacity);
    const int32_t count = floe_calendar_host_describe(
            static_cast<int64_t>(claim), staging.data(), kDescribeCapacity);
    if (count <= 0 || count > kDescribeCapacity) return nullptr;
    jbyteArray result = env->NewByteArray(count);
    if (!result) return nullptr;
    env->SetByteArrayRegion(result, 0, count,
                            reinterpret_cast<const jbyte *>(staging.data()));
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_complete(
        JNIEnv *env, jobject, jlong claim, jint status, jbyteArray data) {
    if (!data) {
        return floe_calendar_host_complete(static_cast<int64_t>(claim), status, nullptr, 0);
    }
    const jsize size = env->GetArrayLength(data);
    if (size < 0 || size > kMaximumReply) return -2;
    std::vector<uint8_t> payload(static_cast<size_t>(size));
    if (size > 0) {
        env->GetByteArrayRegion(data, 0, size,
                                reinterpret_cast<jbyte *>(payload.data()));
    }
    return floe_calendar_host_complete(
            static_cast<int64_t>(claim), status,
            size > 0 ? payload.data() : nullptr, size);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_shouldStop(
        JNIEnv *, jobject, jlong claim) {
    return floe_calendar_host_should_stop(static_cast<int64_t>(claim)) != 0
        ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_closeAll(
        JNIEnv *, jobject, jint timeoutMillis) {
    return floe_calendar_host_close_all(timeoutMillis);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_laneClosed(
        JNIEnv *, jobject, jlong epoch) {
    return floe_calendar_host_lane_closed(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_host_calendar_CalendarProviderNative_stats(
        JNIEnv *env, jobject) {
    std::vector<char> staging(kStatsCapacity);
    const int32_t count = floe_calendar_host_stats(staging.data(), kStatsCapacity);
    if (count < 0 || count > kStatsCapacity) return nullptr;
    jbyteArray result = env->NewByteArray(count);
    if (!result) return nullptr;
    env->SetByteArrayRegion(result, 0, count,
                            reinterpret_cast<const jbyte *>(staging.data()));
    return result;
}
