// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed lifecycle rejection raised by the RB-1 runtime JNI adapter. Only the
 * numeric contract status is retained — storage roots, tokens and effect
 * content never enter the message.
 *
 * Status space (owned by `RuntimeFacadeStatus` in Swift):
 *   0 accepted, 1 idempotent, -105/-106 shape/buffer,
 *   -201 invalidStorageRoot, -202 invalidOwnerToken, -203 epochNotNewer,
 *   -204 ownerMismatch, -205 alreadyDraining, -206 bootstrapSaturated,
 *   -207 notInstalled, -208 alreadyStopped, -209 draining,
 *   -210 rebindWhileOwned, -299 internal.
 */
class RuntimeNativeException(val status: Int) :
    IllegalStateException("runtime_status_$status")

/**
 * External declarations only (no logic). The class initializer is the ONE
 * place this seam loads libfloe_jni (the same library object the gateway
 * loader already pins; JVM loadLibrary is idempotent per class loader). The
 * production coordinator touches this object only from its off-main
 * bootstrap job — never from a property initializer or Application main.
 *
 * The frozen SwiftCore.kt and SecretGatewayNative.kt stay unchanged.
 */
object RuntimeCoreNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Trusted host bootstrap start. Returns the opaque operation receipt
     * (`op:v1:<32hex>`) for the bootstrap effect; `0` accepted / `1`
     * idempotent both return the SAME receipt semantics. Typed rejections
     * throw [RuntimeNativeException].
     */
    external fun runtimeOwnerStart(rootPath: String, ownerToken: String, epoch: Long): String

    /**
     * Trusted host shutdown. RB1-R5: the caller must prove it owns the exact
     * accepted generation by passing the accepted epoch and owner token.
     * A stale coordinator can only receive a typed rejection; it can never
     * stop a newer owner. Returns the shutdown-control receipt.
     */
    external fun runtimeOwnerStop(ownerEpoch: Long, ownerToken: String): String

    /**
     * Lock-only lifecycle snapshot JSON (three separate typed readiness
     * facts + mailbox/pump accounting + missingBindings). Null only if the
     * Swift side cannot serialize; callers treat null as unknown, never as
     * ready.
     */
    external fun runtimeStatus(): String?

    /**
     * G02 narrow trusted-host readback: the CURRENT native root-generation
     * epoch as a decimal string, or null when no live generation exists.
     * The host MUST fail closed on null (never bind 0). Carries no path,
     * token or other status (distinct from [runtimeStatus]).
     */
    external fun g02NativeRootEpoch(): String?

    /**
     * G02 narrow trusted-host domain readiness snapshot JSON: per-domain
     * `ready|blocked|retired` state + typed missing dependencies + the real
     * handler-key sets. No root path, owner token or secret ever appears.
     */
    external fun g02DomainReadiness(): String?
}
