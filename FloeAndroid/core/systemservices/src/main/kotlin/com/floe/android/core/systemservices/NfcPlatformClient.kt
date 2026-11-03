// SPDX-License-Identifier: MPL-2.0
//
// Real foreground NFC/NDEF reading for C06. This lane only reads ONE tag per
// explicit call: reader mode is enabled for that call, disabled in `finally`,
// and a second tag can never satisfy the same request. There is no write,
// lock, raw APDU, payment/secure-element, background or URL-open path.

package com.floe.android.core.systemservices

import android.app.Activity
import android.content.Context
import android.nfc.FormatException
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.NfcManager
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class NfcPlatformClient(context: Context) : NfcService {
    private val appContext = context.applicationContext
    private val adapter: NfcAdapter? =
        (appContext.getSystemService(Context.NFC_SERVICE) as? NfcManager)?.defaultAdapter
    private val scanning = AtomicBoolean(false)

    override fun capability(): NfcCapability {
        val current = adapter
        return NfcCapability(
            hardwareAvailable = current != null,
            enabled = try {
                current?.isEnabled == true
            } catch (_: RuntimeException) {
                false
            },
        )
    }

    /**
     * Read one tag's NDEF message. `activity` must be the currently resumed
     * App activity; a null value is a foreground-required failure, not a
     * hidden background scan.
     */
    override suspend fun read(
        activity: Activity?,
        timeoutSeconds: Int,
    ): NfcReadRow {
        val current = adapter ?: throw SystemServiceFailure(
            SystemServiceFailureCode.NFC_HARDWARE_UNAVAILABLE,
            "this device has no NFC adapter",
        )
        if (try {
                !current.isEnabled
            } catch (_: RuntimeException) {
                true
            }
        ) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_DISABLED,
                "NFC is disabled",
            )
        }
        val target = activity ?: throw SystemServiceFailure(
            SystemServiceFailureCode.FOREGROUND_REQUIRED,
            "NFC reading requires the app in the foreground",
        )
        if (!scanning.compareAndSet(false, true)) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_BUSY,
                "another NFC scan is already active",
                retryable = true,
            )
        }
        val started = SystemClock.elapsedRealtime()
        try {
            val timeoutMs = timeoutSeconds.coerceIn(
                SystemServicesBounds.MIN_NFC_TIMEOUT_SECONDS,
                SystemServicesBounds.MAX_NFC_TIMEOUT_SECONDS,
            ) * 1_000L
            val tag = withTimeoutOrNull(timeoutMs) {
                awaitTag(current, target)
            } ?: throw SystemServiceFailure(
                SystemServiceFailureCode.TIMED_OUT,
                "no NFC tag was presented before the scan deadline",
                retryable = true,
            )
            val result = withTimeoutOrNull(5_000) {
                withContext(Dispatchers.IO) { readTag(tag) }
            } ?: throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_TAG_LOST,
                "the tag did not finish transferring before the read deadline",
                retryable = true,
            )
            return result.copy(elapsedMs = SystemClock.elapsedRealtime() - started)
        } finally {
            try {
                withContext(Dispatchers.Main.immediate) {
                    current.disableReaderMode(target)
                }
            } catch (_: RuntimeException) {
            }
            scanning.set(false)
        }
    }

    private suspend fun awaitTag(adapter: NfcAdapter, activity: Activity): Tag =
        withContext(Dispatchers.Main.immediate) {
            suspendCancellableCoroutine { continuation ->
                val delivered = AtomicBoolean(false)
                val callback = NfcAdapter.ReaderCallback { tag ->
                    if (delivered.compareAndSet(false, true)) {
                        if (continuation.isActive) continuation.resume(tag)
                    }
                }
                val extras = Bundle().apply {
                    putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
                }
                try {
                    adapter.enableReaderMode(
                        activity,
                        callback,
                        NfcAdapter.FLAG_READER_NFC_A or
                            NfcAdapter.FLAG_READER_NFC_B or
                            NfcAdapter.FLAG_READER_NFC_F or
                            NfcAdapter.FLAG_READER_NFC_V,
                        extras,
                    )
                } catch (failure: RuntimeException) {
                    if (delivered.compareAndSet(false, true) && continuation.isActive) {
                        continuation.resumeWithException(
                            SystemServiceFailure(
                                SystemServiceFailureCode.FOREGROUND_REQUIRED,
                                "the NFC reader could not start in the foreground",
                                detail = failure.javaClass.simpleName.take(64),
                            ),
                        )
                    }
                    return@suspendCancellableCoroutine
                }
                continuation.invokeOnCancellation {
                    Handler(Looper.getMainLooper()).post {
                        try {
                            adapter.disableReaderMode(activity)
                        } catch (_: RuntimeException) {
                        }
                    }
                }
            }
        }

    private fun readTag(tag: Tag): NfcReadRow {
        val techList = tag.techList
            .map { it.substringAfterLast('.') }
            .filter { it.isNotEmpty() }
            .take(8)
        val ndef = Ndef.get(tag) ?: throw SystemServiceFailure(
            SystemServiceFailureCode.NFC_UNSUPPORTED_TAG,
            "the tag does not expose an NDEF message",
            detail = "tech=" + techList.joinToString(",").take(120),
        )
        try {
            ndef.connect()
        } catch (_: IOException) {
            runCatching { ndef.close() }
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_TAG_LOST,
                "the tag left the field before it could be read",
                retryable = true,
            )
        } catch (failure: RuntimeException) {
            runCatching { ndef.close() }
            throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_UNSUPPORTED_TAG,
                "the NDEF tag could not be opened",
                detail = failure.javaClass.simpleName.take(64),
            )
        }
        try {
            val message = try {
                ndef.ndefMessage ?: ndef.cachedNdefMessage
            } catch (_: IOException) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.NFC_TAG_LOST,
                    "the tag left the field while reading",
                    retryable = true,
                )
            } catch (failure: FormatException) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.NFC_MALFORMED_TAG,
                    "the tag contains a malformed NDEF message",
                    detail = failure.javaClass.simpleName.take(64),
                )
            } ?: throw SystemServiceFailure(
                SystemServiceFailureCode.NFC_UNSUPPORTED_TAG,
                "the tag has no NDEF message",
            )
            val bytes = message.toByteArray()
            if (bytes.size > SystemServicesBounds.MAX_NFC_BYTES) {
                throw SystemServiceFailure(
                    SystemServiceFailureCode.NFC_PAYLOAD_TOO_LARGE,
                    "the NDEF message exceeds the bounded read limit",
                    detail = "bytes=${bytes.size}",
                )
            }
            val records = message.records
            val bounded = records.take(SystemServicesBounds.MAX_NFC_RECORDS)
            val rendered = bounded.mapIndexed { index, record -> renderRecord(index, record) }
            return NfcReadRow(
                records = rendered,
                rawBytes = bytes.size,
                writable = ndef.isWritable,
                techList = techList,
                truncated = records.size > bounded.size,
                elapsedMs = 0,
            )
        } finally {
            try {
                ndef.close()
            } catch (_: IOException) {
            } catch (_: RuntimeException) {
            }
        }
    }

    private fun renderRecord(index: Int, record: NdefRecord): NfcRecordRow {
        val payload = record.payload ?: ByteArray(0)
        val digest = MessageDigest.getInstance("SHA-256").digest(payload)
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            .take(16)
        val tnf = record.tnf
        val type = record.type ?: ByteArray(0)
        val id = record.id ?: ByteArray(0)
        val typeText = printable(type)
        val idText = printable(id)
        return try {
            when {
                tnf == NdefRecord.TNF_EMPTY -> NfcRecordRow(
                    index = index,
                    tnf = tnf.toInt(),
                    type = typeText,
                    id = idText,
                    kind = "empty",
                    value = null,
                    payloadBytes = payload.size,
                    payloadSHA256 = digest,
                    truncated = false,
                )
                tnf == NdefRecord.TNF_WELL_KNOWN &&
                    type.contentEquals(NdefRecord.RTD_TEXT) -> {
                    val text = decodeText(payload)
                    NfcRecordRow(
                        index = index,
                        tnf = tnf.toInt(),
                        type = typeText,
                        id = idText,
                        kind = "text",
                        value = SystemServicesPolicy.sanitizeContactValue(
                            text.first,
                            SystemServicesBounds.MAX_NFC_VALUE_CHARACTERS,
                        ),
                        payloadBytes = payload.size,
                        payloadSHA256 = digest,
                        truncated = text.second,
                    )
                }
                tnf == NdefRecord.TNF_WELL_KNOWN &&
                    type.contentEquals(NdefRecord.RTD_URI) -> {
                    val uri = record.toUri()
                    NfcRecordRow(
                        index = index,
                        tnf = tnf.toInt(),
                        type = typeText,
                        id = idText,
                        kind = "uri",
                        value = uri?.toString()?.let {
                            SystemServicesPolicy.sanitizeContactValue(
                                it,
                                SystemServicesBounds.MAX_NFC_VALUE_CHARACTERS,
                            )
                        },
                        payloadBytes = payload.size,
                        payloadSHA256 = digest,
                        truncated = false,
                    )
                }
                tnf == NdefRecord.TNF_MIME_MEDIA -> {
                    val mime = record.toMimeType()
                    NfcRecordRow(
                        index = index,
                        tnf = tnf.toInt(),
                        type = typeText,
                        id = idText,
                        kind = "mime",
                        value = mime?.take(SystemServicesBounds.MAX_NFC_VALUE_CHARACTERS),
                        payloadBytes = payload.size,
                        payloadSHA256 = digest,
                        truncated = false,
                    )
                }
                else -> NfcRecordRow(
                    index = index,
                    tnf = tnf.toInt(),
                    type = typeText,
                    id = idText,
                    kind = "unknown",
                    value = null,
                    payloadBytes = payload.size,
                    payloadSHA256 = digest,
                    truncated = payload.size > SystemServicesBounds.MAX_NFC_VALUE_CHARACTERS,
                )
            }
        } catch (_: RuntimeException) {
            NfcRecordRow(
                index = index,
                tnf = tnf.toInt(),
                type = typeText,
                id = idText,
                kind = "malformed",
                value = null,
                payloadBytes = payload.size,
                payloadSHA256 = digest,
                truncated = true,
            )
        }
    }

    private fun printable(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""
        val text = bytes.toString(Charsets.US_ASCII)
        return if (text.all { it.code in 0x20..0x7E }) {
            text.take(80)
        } else {
            bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }.take(80)
        }
    }

    /** Bounded NDEF Text record decoder (UTF-8 or UTF-16, language prefix). */
    private fun decodeText(payload: ByteArray): Pair<String, Boolean> {
        if (payload.isEmpty()) return "" to false
        val status = payload[0].toInt() and 0xFF
        val languageLength = status and 0x3F
        val utf16 = status and 0x80 != 0
        val start = 1 + languageLength
        if (start > payload.size) return "" to false
        val charset = if (utf16) Charsets.UTF_16 else Charsets.UTF_8
        val raw = String(payload, start, payload.size - start, charset)
        val cleaned = SystemServicesPolicy.sanitizeContactValue(
            raw,
            SystemServicesBounds.MAX_NFC_VALUE_CHARACTERS,
        )
        return cleaned to (cleaned.length < raw.length)
    }
}
