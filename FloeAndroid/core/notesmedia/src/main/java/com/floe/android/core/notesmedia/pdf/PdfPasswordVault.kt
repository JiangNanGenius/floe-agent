// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import android.os.Build
import com.floe.android.core.officeengine.pdf.OfficePdfPlatformCapabilities

/**
 * RAM-only password holder for a protected PDF.
 *
 * Guarantees:
 *  - the characters live only in this object's `CharArray`; there is no
 *    String copy, no `toString` rendering of the value, no logging and no
 *    persistence;
 *  - [close] zero-fills the buffer and later [use] calls throw, so a caller
 *    cannot keep using a released secret;
 *  - the holder is passed by [use] as a read-only-by-convention CharArray for
 *    the duration of one operation only.
 *
 * Where the secret goes (2026-10-30): the shared Office isolated renderer's
 * binder protocol accepts an optional RAM-only `char[]` on
 * `documentInfo`/`renderPage`/`pageText`; the isolated process turns it into
 * the platform `LoadParams` String once and the app process never creates a
 * String, path, log line or Bundle containing it. The ORIGINAL file is never
 * modified (no decryption-to-new-file, no destructive rewrite).
 */
class PdfPassword private constructor(private val secret: CharArray) : AutoCloseable {

    @Volatile
    private var closed = false

    val length: Int get() = if (closed) 0 else secret.size

    val isEmpty: Boolean get() = length == 0

    /** Runs [block] with the secret; refuses after [close]. */
    fun <R> use(block: (CharArray) -> R): R {
        check(!closed) { "Password was already cleared" }
        return block(secret)
    }

    /**
     * Borrows the live buffer for ONE transport call (no copy). Module-internal
     * so the session/gateway can hand it to the binder without creating a
     * String; the holder must stay open for the duration of the operation and
     * the receiver must never retain or stringify it.
     */
    internal fun borrowSecret(): CharArray {
        check(!closed) { "Password was already cleared" }
        return secret
    }

    override fun close() {
        if (closed) return
        secret.fill('\u0000')
        closed = true
    }

    override fun toString(): String = "PdfPassword(redacted, length=$length)"

    companion object {
        const val MAX_PASSWORD_CHARS: Int = 512

        /** Copies [raw] once into an owned buffer; empty/oversized input is refused. */
        fun of(raw: CharArray): PdfPassword? {
            if (raw.isEmpty() || raw.size > MAX_PASSWORD_CHARS) return null
            return PdfPassword(raw.copyOf())
        }

        /** Convenience for UI collectors; the intermediate String is the caller's to clear. */
        fun ofString(raw: String): PdfPassword? {
            if (raw.isEmpty() || raw.length > MAX_PASSWORD_CHARS) return null
            return PdfPassword(raw.toCharArray())
        }
    }
}

/** What the current platform/backend can honestly do with a password. */
sealed class PdfPasswordCapability {
    /** A real password path exists and is usable. */
    object NativeSupported : PdfPasswordCapability()

    /** API level is below the guarded native floor. */
    data class ApiTooLow(val requiredApi: Int) : PdfPasswordCapability()

    /**
     * This device has no public password-capable renderer (API < 31, or the
     * Mainline `framework-pdf` module is absent on 31–34). Unlock attempts
     * are refused with the ORIGINAL file preserved.
     */
    object BackendHasNoPasswordChannel : PdfPasswordCapability()
}

/** Typed refusal identity for one unlock attempt; never carries the secret. */
enum class PdfUnlockRefusal {
    /** No password channel exists in the current stack. */
    NO_PASSWORD_CHANNEL,

    /** The platform API level is below the guarded floor. */
    API_LEVEL_TOO_LOW,

    /** A password was required but none/empty was provided. */
    MISSING_PASSWORD,

    /** The document is not encrypted (nothing to unlock). */
    NOT_ENCRYPTED,

    /** The renderer refused for a non-password reason. */
    DOCUMENT_UNREADABLE,
}

data class PdfUnlockResult(
    val opened: Boolean,
    val refusal: PdfUnlockRefusal? = null,
    /** Always true here: no destructive rewrite of the source is ever attempted. */
    val originalPreserved: Boolean = true,
    /**
     * True when the policy is satisfied and the ONLY way to know whether the
     * password is right is to open the document through the isolated renderer
     * ([PdfDocumentSessions.open] → typed PASSWORD_REJECTED on failure).
     * Added 2026-10-30; the old "unlock" entry point never claims success
     * without a real renderer attempt.
     */
    val requiresRendererAttempt: Boolean = false,
)

/**
 * Password capability policy.
 *
 * FACTS verified against the installed API-37 `android.jar` /
 * `android-stubs-src.jar` / `data/api-versions.xml` on 2026-10-30 (the
 * earlier handoff's "no public constructor/setter" claim was WRONG):
 *  - `PdfRenderer(ParcelFileDescriptor, LoadParams)` is public `since="35"`;
 *  - `LoadParams.Builder()` and `Builder.setPassword(String)` are public;
 *  - `PdfRendererPreV` exposes the same surface on API 31/33/34 when the
 *    Mainline `framework-pdf` module (version 13+) is present; the isolated
 *    service detects it by class presence and only then loads the adapter.
 * The constant stays explicit so a future SDK change must consciously flip
 * it and add a real test instead of silently believing a password path
 * exists.
 */
object PdfPasswordSupport {

    /** Full-framework `PdfRenderer(fd, LoadParams)` floor. */
    const val NATIVE_PASSWORD_MIN_API: Int = Build.VERSION_CODES.VANILLA_ICE_CREAM // 35

    /** Mainline `PdfRendererPreV` backport floor (class presence is also required). */
    const val MODULE_PASSWORD_MIN_API: Int = 31

    const val PUBLIC_SDK_PASSWORD_SETTER_PRESENT: Boolean = true

    fun capability(
        apiLevel: Int = Build.VERSION.SDK_INT,
        pdfModulePresent: Boolean = OfficePdfPlatformCapabilities.pdfModulePresent(),
    ): PdfPasswordCapability = when {
        !PUBLIC_SDK_PASSWORD_SETTER_PRESENT -> PdfPasswordCapability.BackendHasNoPasswordChannel
        apiLevel >= NATIVE_PASSWORD_MIN_API -> PdfPasswordCapability.NativeSupported
        apiLevel >= MODULE_PASSWORD_MIN_API && pdfModulePresent -> PdfPasswordCapability.NativeSupported
        apiLevel < MODULE_PASSWORD_MIN_API -> PdfPasswordCapability.ApiTooLow(MODULE_PASSWORD_MIN_API)
        else -> PdfPasswordCapability.BackendHasNoPasswordChannel
    }

    /**
     * Policy pre-check for one unlock attempt. It NEVER claims success for an
     * encrypted file: when the platform supports a password, the result is
     * [PdfUnlockResult.requiresRendererAttempt] and the caller must open the
     * document through [PdfDocumentSessions.open], where a wrong password is
     * the typed [PdfMediaFailure.PASSWORD_REJECTED]. The original file is
     * always preserved.
     */
    fun attemptUnlock(
        password: PdfPassword?,
        encrypted: Boolean,
        apiLevel: Int = Build.VERSION.SDK_INT,
        pdfModulePresent: Boolean = OfficePdfPlatformCapabilities.pdfModulePresent(),
    ): PdfUnlockResult {
        if (!encrypted) return PdfUnlockResult(opened = true)
        if (password == null || password.isEmpty) {
            return PdfUnlockResult(false, PdfUnlockRefusal.MISSING_PASSWORD)
        }
        return when (capability(apiLevel, pdfModulePresent)) {
            is PdfPasswordCapability.ApiTooLow -> PdfUnlockResult(false, PdfUnlockRefusal.API_LEVEL_TOO_LOW)
            is PdfPasswordCapability.BackendHasNoPasswordChannel ->
                PdfUnlockResult(false, PdfUnlockRefusal.NO_PASSWORD_CHANNEL)
            PdfPasswordCapability.NativeSupported ->
                PdfUnlockResult(false, refusal = null, requiresRendererAttempt = true)
        }
    }
}
