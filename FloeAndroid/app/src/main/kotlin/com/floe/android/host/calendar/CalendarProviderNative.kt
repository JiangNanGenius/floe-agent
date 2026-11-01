// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.calendar

/**
 * App-owned C ABI for the C06 calendar provider mailbox.
 *
 * Swift owns the bounded ticket table and validates every request; this App
 * lane alone executes the real CalendarContract query/write and completes the
 * ticket once. No model text, Intent, provider URI or path crosses this ABI.
 *
 * The JNI class name is load-bearing: the additive TU
 * `floe_calendar_host_jni.cpp` exports
 * `Java_com_floe_android_host_calendar_CalendarProviderNative_*`.
 */
internal object CalendarProviderNative {
    init {
        System.loadLibrary("floe_jni")
    }

    external fun bind(epoch: Long): Int
    external fun laneReady(epoch: Long): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun complete(claim: Long, status: Int, data: ByteArray?): Int
    external fun shouldStop(claim: Long): Boolean
    external fun closeAll(timeoutMillis: Int): Int
    external fun laneClosed(epoch: Long): Int
    external fun stats(): ByteArray?
}

internal interface CalendarHostBridge {
    fun bind(epoch: Long): Int
    fun laneReady(epoch: Long): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): ByteArray?
    fun complete(claim: Long, status: Int, data: ByteArray?): Int
    fun shouldStop(claim: Long): Boolean
    fun closeAll(timeoutMillis: Int): Int
    fun laneClosed(epoch: Long): Int
}

internal object PlatformCalendarHostBridge : CalendarHostBridge {
    override fun bind(epoch: Long): Int = CalendarProviderNative.bind(epoch)
    override fun laneReady(epoch: Long): Int = CalendarProviderNative.laneReady(epoch)
    override fun next(timeoutMillis: Int): Long = CalendarProviderNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = CalendarProviderNative.describe(claim)
    override fun complete(claim: Long, status: Int, data: ByteArray?): Int =
        CalendarProviderNative.complete(claim, status, data)
    override fun shouldStop(claim: Long): Boolean = CalendarProviderNative.shouldStop(claim)
    override fun closeAll(timeoutMillis: Int): Int = CalendarProviderNative.closeAll(timeoutMillis)
    override fun laneClosed(epoch: Long): Int = CalendarProviderNative.laneClosed(epoch)
}
