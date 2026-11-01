// SPDX-License-Identifier: MPL-2.0
//
// C06 mail transport mailbox JNI wrapper.
//
// Swift owns the bounded ticket table and all mail protocol decisions; Kotlin
// owns the platform TCP/SSLSocket lane. This translation unit only copies
// bounded descriptors/bytes between the two and never interprets protocol
// content, credentials or host names. It is an additive TU in the existing
// floe_jni target; no prior wrapper changes.

#include <jni.h>
#include <cstdint>
#include <vector>

extern "C" int32_t floe_mail_transport_bind(uint64_t epoch);
extern "C" int32_t floe_mail_transport_lane_ready(uint64_t epoch);
extern "C" int64_t floe_mail_transport_next(int32_t timeout_millis);
extern "C" int32_t floe_mail_transport_describe(int64_t claim, char *buffer, int32_t capacity);
extern "C" int32_t floe_mail_transport_take_write(int64_t claim, uint8_t *buffer, int32_t capacity);
extern "C" int32_t floe_mail_transport_complete(int64_t claim, int32_t status,
                                                 const uint8_t *data, int32_t length);
extern "C" int32_t floe_mail_transport_should_stop(int64_t claim);
extern "C" int32_t floe_mail_transport_cancel_session(int64_t session);
extern "C" int32_t floe_mail_transport_close_all(int32_t timeout_millis);
extern "C" int32_t floe_mail_transport_lane_closed(uint64_t epoch);
extern "C" int32_t floe_mail_transport_stats(char *buffer, int32_t capacity);

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_bind(JNIEnv *, jobject, jlong epoch) {
    return floe_mail_transport_bind(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_laneReady(JNIEnv *, jobject, jlong epoch) {
    return floe_mail_transport_lane_ready(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_floe_android_bridge_MailTransportNative_next(JNIEnv *, jobject, jint timeoutMillis) {
    return floe_mail_transport_next(timeoutMillis);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_describe(
        JNIEnv *env, jobject, jlong claim, jbyteArray buffer) {
    if (!buffer) return -1;
    const jsize size = env->GetArrayLength(buffer);
    if (size <= 0 || size > 4096) return -1;
    std::vector<char> staging(static_cast<size_t>(size));
    const int32_t count = floe_mail_transport_describe(
            static_cast<int64_t>(claim), staging.data(), size);
    if (count < 0 || count > size) return -1;
    env->SetByteArrayRegion(buffer, 0, count,
                            reinterpret_cast<const jbyte *>(staging.data()));
    return count;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_takeWrite(
        JNIEnv *env, jobject, jlong claim, jbyteArray buffer) {
    if (!buffer) return -1;
    const jsize size = env->GetArrayLength(buffer);
    if (size <= 0 || size > 65536) return -1;
    jbyte *data = env->GetByteArrayElements(buffer, nullptr);
    if (!data) return -1;
    const int32_t count = floe_mail_transport_take_write(
            static_cast<int64_t>(claim), reinterpret_cast<uint8_t *>(data), size);
    env->ReleaseByteArrayElements(buffer, data, 0);
    return count;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_complete(
        JNIEnv *env, jobject, jlong claim, jint status,
        jbyteArray data, jint length) {
    if (length < 0 || length > 65536) return -2;
    std::vector<uint8_t> payload;
    const uint8_t *pointer = nullptr;
    if (data && length > 0) {
        if (env->GetArrayLength(data) < length) return -2;
        payload.resize(static_cast<size_t>(length));
        env->GetByteArrayRegion(data, 0, length,
                                reinterpret_cast<jbyte *>(payload.data()));
        pointer = payload.data();
    }
    return floe_mail_transport_complete(
            static_cast<int64_t>(claim), status, pointer, length);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_shouldStop(
        JNIEnv *, jobject, jlong claim) {
    return floe_mail_transport_should_stop(static_cast<int64_t>(claim));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_cancelSession(
        JNIEnv *, jobject, jlong session) {
    return floe_mail_transport_cancel_session(static_cast<int64_t>(session));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_closeAll(
        JNIEnv *, jobject, jint timeoutMillis) {
    return floe_mail_transport_close_all(timeoutMillis);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_laneClosed(
        JNIEnv *, jobject, jlong epoch) {
    return floe_mail_transport_lane_closed(static_cast<uint64_t>(epoch));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_MailTransportNative_stats(
        JNIEnv *env, jobject, jbyteArray buffer) {
    if (!buffer) return -1;
    const jsize size = env->GetArrayLength(buffer);
    if (size <= 0 || size > 4096) return -1;
    std::vector<char> staging(static_cast<size_t>(size));
    const int32_t count = floe_mail_transport_stats(staging.data(), size);
    if (count < 0 || count > size) return -1;
    env->SetByteArrayRegion(buffer, 0, count,
                            reinterpret_cast<const jbyte *>(staging.data()));
    return count;
}
