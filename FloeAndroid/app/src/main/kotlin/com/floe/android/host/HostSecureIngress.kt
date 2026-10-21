// SPDX-License-Identifier: MPL-2.0
//
// G02 trusted host secure-ingress seams (App side).
//
// The native side owns route authority: the App opens ONE `rt:v1:` handle per
// live editor incarnation and never invents tokens, generations or Root
// epochs. Each editor incarnation is identified by the App-wide shared UI
// generation ([HostUiAdmission]) plus its editor identity/kind; the native
// Root epoch is the separate actual bootstrap generation captured at editor
// creation. The native admission refuses a stale/foreign Root or an older UI
// incarnation before mutating any live binding.
//
// The one-shot credential submit takes the closed intent CORE
// (subject/intent/candidate/baseRevision) plus that handle; the native seam
// injects the live route pair, so model-authored JSON or imported content can
// never bind or widen authority. Both seams are replaceable only in-module so
// JVM tests exercise the real controller wiring without the native library.
package com.floe.android.host

import com.floe.android.bridge.SecretGatewayNative
import java.util.concurrent.atomic.AtomicLong

/** Closed editor kinds accepted by the native route authority. */
internal enum class HostEditorKind(val raw: String) {
    PROVIDER("provider"),
    MCP("mcp"),
    WEB_SEARCH("webSearch"),
}

/**
 * ONE shared trusted-host UI admission sequence for provider/MCP/web-search
 * editor incarnations. It is deliberately separate from the native Root
 * epoch and from the command-client UI generation: the native admission
 * requires a STRICTLY NEWER shared generation for a new editor, so a late
 * callback from an older editor can never mint authority or evict a newer
 * editor's route binding.
 */
internal object HostUiAdmission {
    private val sequence = AtomicLong(0)

    fun nextGeneration(): Long = sequence.incrementAndGet()

    /** Test-only: reset the sequence between isolated JVM fixtures. */
    internal fun resetForTesting() {
        sequence.set(0)
    }
}

internal interface HostRouteAuthority {
    /**
     * Admit one live editor incarnation. [expectedNativeRootEpoch] is the
     * actual accepted native Root epoch captured when the editor was
     * created; [uiGeneration] is [HostUiAdmission]'s shared sequence value.
     * Null means the native admission refused (stale/foreign Root, stale
     * editor incarnation or no accepted generation): fail closed.
     */
    fun open(
        kind: HostEditorKind,
        editorID: String,
        uiGeneration: Long,
        expectedNativeRootEpoch: Long,
    ): String?

    /** Exact-ownership close of this editor's own handle. */
    fun clear(token: String)
}

internal object NativeHostRouteAuthority : HostRouteAuthority {
    override fun open(
        kind: HostEditorKind,
        editorID: String,
        uiGeneration: Long,
        expectedNativeRootEpoch: Long,
    ): String? = try {
        SecretGatewayNative.openHostRoute(
            kind.raw, editorID, uiGeneration, expectedNativeRootEpoch)
    } catch (t: Throwable) {
        // No accepted generation / native library absent / refused
        // admission: fail closed. The save path reports the typed ingress
        // failure; nothing is invented.
        null
    }

    override fun clear(token: String) {
        try {
            SecretGatewayNative.clearHostRoute(token)
        } catch (t: Throwable) {
            // A failed close is a no-op against the exact-ownership rule; the
            // binding dies with its Root epoch anyway.
        }
    }
}

/**
 * Trusted-host DRAFT probe/discovery seam (unsaved/changed provider draft).
 * Production is the JNI bridge to the native seam; JVM fixtures bind a
 * scripted double. This is NOT a V3 command: no command name, no payload
 * vocabulary, no model/tool reachability.
 */
internal interface HostDraftProbe {
    /** Returns the opaque `dp:v1:` handle, or null when refused pre-dispatch. */
    fun submit(candidateJSON: String, secret: String?, routeToken: String): String?

    /** "P" pending | "S" + settled JSON | "R" + typed refusal status. */
    fun poll(handle: String, routeToken: String): String

    /** Owner cancel; the real adapter work is cancelled natively. */
    fun cancel(handle: String, routeToken: String)
}

internal object NativeHostDraftProbe : HostDraftProbe {
    override fun submit(candidateJSON: String, secret: String?, routeToken: String): String? {
        val candidateBytes = candidateJSON.encodeToByteArray()
        val secretBytes = secret?.encodeToByteArray()
        return try {
            com.floe.android.bridge.ProviderDraftProbeNative.submitDraftProbe(
                candidateBytes, secretBytes, routeToken)
        } catch (t: Throwable) {
            null
        } finally {
            candidateBytes.fill(0)
            secretBytes?.fill(0)
        }
    }

    override fun poll(handle: String, routeToken: String): String =
        try {
            com.floe.android.bridge.ProviderDraftProbeNative.pollDraftProbe(handle, routeToken)
                ?: DRAFT_PROBE_REFUSED
        } catch (t: Throwable) {
            DRAFT_PROBE_REFUSED
        }

    override fun cancel(handle: String, routeToken: String) {
        try {
            com.floe.android.bridge.ProviderDraftProbeNative.cancelDraftProbe(handle, routeToken)
        } catch (t: Throwable) {
            // A failed cancel is a no-op against the exact-ownership rule;
            // the route/epoch fence retires the slot anyway.
        }
    }

    private const val DRAFT_PROBE_REFUSED = "R-105"
}

internal interface HostSecureIngressSubmitter {
    fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String?
}

internal object NativeHostSecureIngressSubmitter : HostSecureIngressSubmitter {
    override fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String? =
        try {
            SecretGatewayNative.submitHostSaveIntent(intentCoreJSON, routeToken, value)
        } catch (t: Throwable) {
            null
        }
}

/** Canonical `int:v1:` handle check (39 bytes, 32 lowercase hex). */
internal fun isOpaqueIngressToken(token: String): Boolean =
    token.length == 39 && token.startsWith("int:v1:") &&
        token.substring(7).all { it in '0'..'9' || it in 'a'..'f' }

/** Canonical `rt:v1:` host route handle check (38 bytes, 32 lowercase hex). */
internal fun isOpaqueHostRouteToken(token: String): Boolean =
    token.length == 38 && token.startsWith("rt:v1:") &&
        token.substring(6).all { it in '0'..'9' || it in 'a'..'f' }
