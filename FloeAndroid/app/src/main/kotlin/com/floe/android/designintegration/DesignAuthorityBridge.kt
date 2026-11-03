// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import com.floe.android.RuntimeBootstrapCoordinator
import com.floe.android.host.creative.DesignAuthorityIssuer

/**
 * App owner implementation of the privileged design-authority ingress.
 *
 * The trusted coordinator owns the accepted epoch + one process owner token;
 * this adapter only forwards the bounded request/confirm/revoke/retire calls.
 * The token never enters this class, the UI, a log or the wire envelope
 * (native `DesignAuthorityNative` keeps it inside the JNI call).
 *
 * REQUIRED PRIVATE PATCH (mediaClosure32 owns
 * `RuntimeBootstrapCoordinator.kt`): designclosure30 `PATCHES.md` §2a adds
 * `issueDesignAuthorityPrepare`, `confirmDesignAuthority`,
 * `revokeDesignAuthority`, `retireDesignAuthority` and the atomic
 * `acceptedDesignOwnerProof` accessor (preimage SHA-256
 * `63f1dc725cee331568349f877465023f7fb19365bbf987931eed7b4c73261f1e`).
 * mediaClosure32 applies that exact patch with its media/task grant wrappers;
 * without it the restructure confirmation is honestly unavailable and no
 * grant is ever minted.
 */
internal class DesignAuthorityBridge(
    /**
     * Deferred: the Application constructs this bridge before the coordinator
     * field is assigned. No method reads it until an explicit design action.
     */
    private val coordinatorProvider: () -> RuntimeBootstrapCoordinator,
) : DesignAuthorityIssuer {
    override fun prepare(epoch: Long, requestJson: String): String? =
        coordinatorProvider().issueDesignAuthorityPrepare(epoch, requestJson)

    override fun confirm(epoch: Long, token: String): Int =
        coordinatorProvider().confirmDesignAuthority(epoch, token)

    override fun revoke(epoch: Long, token: String): Int =
        coordinatorProvider().revokeDesignAuthority(epoch, token)

    override fun retire(epoch: Long): Int =
        coordinatorProvider().retireDesignAuthority(epoch)
}
