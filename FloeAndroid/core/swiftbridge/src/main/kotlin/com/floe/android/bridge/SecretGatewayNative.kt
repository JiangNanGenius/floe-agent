// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed submit/discard failure raised by the JNI adapter. Only the numeric
 * contract status is retained; candidate JSON, provider URLs and secret bytes
 * never enter the message.
 */
class SecretGatewayNativeException(val status: Int) :
    IllegalStateException("secret_gateway_status_$status")

/**
 * External declarations only (no logic). The class initializer is the ONE
 * place that loads libfloe_jni; the production Application must touch this
 * object only from its off-main bootstrap job. The frozen SwiftCore.kt stays
 * unchanged.
 */
object SecretGatewayNative {
    init { System.loadLibrary("floe_jni") }

    external fun bindSecretDispatcher(epoch: Long): Int
    external fun awaitSecretRequest(timeoutMillis: Int): Long
    external fun describeSecretRequest(claim: Long): String?
    external fun takeSecretPayload(claim: Long): ByteArray?
    external fun isSecretRequestLive(claim: Long): Boolean
    external fun completeSecretRequest(claim: Long, status: Int, value: ByteArray?): Int
    external fun secretMailboxStats(): String
    external fun installSecretGateway(): Int
    external fun removeSecretGateway(): Int
    external fun submitSaveIntent(intent: String, value: ByteArray): String?
    external fun discardSaveIntent(token: String): Int

    /**
     * Trusted host route authority (native-minted, accepted-Root-epoch
     * scoped). [openHostRoute] binds ONE live editor sheet and returns its
     * opaque `rt:v1:` handle; [submitHostSaveIntent] freezes the closed
     * intent core plus that handle and returns the one-shot `int:v1:`
     * ingress token; [clearHostRoute] closes the caller's own handle only
     * (a stale handle can never clear a newer editor's route). These are
     * App-process host calls, NOT V3 commands or model-callable tools.
     */
    external fun openHostRoute(
        editorKind: String,
        editorID: String,
        uiGeneration: Long,
        expectedNativeRootEpoch: Long,
    ): String?
    external fun submitHostSaveIntent(
        intentCoreJSON: String,
        routeToken: String,
        value: ByteArray,
    ): String?
    external fun clearHostRoute(routeToken: String): Int
}
