// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetIdentity

/**
 * Bounded metadata for one REAL retained creative asset.
 *
 * This is a catalog row description only: [assetID] can be passed to
 * [CreativeR2DesignHost.bindCreativeRetainedFirstResult], which reads and
 * verifies the actual bytes natively. No byte body and no filesystem path ever
 * crosses the bridge. [selectable] means the row has a contained Materials path
 * with a usable format extension; the bind still verifies size/digest/content.
 */
data class CreativeDesignAsset(
    val assetID: String,
    val displayName: String,
    val kind: String,
    val format: String,
    val byteCount: Long,
    val contentSHA256: String,
    val updatedAt: String?,
    val selectable: Boolean,
)

/** One bounded page of retained creative assets (`nextCursor` is opaque). */
data class CreativeDesignAssetPage(
    val assets: List<CreativeDesignAsset>,
    val nextCursor: String?,
)

/** Closed native `DesignCreativeRequest.State` values. */
enum class CreativeDesignRequestState(val wire: String) {
    AWAITING_FIRST_RESULT("awaitingFirstResult"),
    FIRST_RESULT_BOUND("firstResultBound"),
    ;

    companion object {
        fun fromWire(raw: String?): CreativeDesignRequestState? =
            entries.firstOrNull { it.wire == raw }
    }
}

/**
 * One reachable pending creative request from the SAME owner envelope store the
 * native workflow writes. [target] is the exact frozen identity, so reopening
 * is `bindTarget` with this target + [CreativeStorageLayer.AppOwned] + a fresh
 * editor session. No id needs to be pasted and no second request store exists.
 */
data class CreativeDesignPendingRequest(
    val targetKey: String,
    val ownerRevision: Long,
    val target: DesignTargetIdentity,
    val storage: CreativeStorageLayer,
    val requestedOutputKind: DesignContentType,
    val state: CreativeDesignRequestState,
    val boundResultID: String?,
    val boundFormat: String?,
    val boundContentSHA256: String?,
    val originConversationID: String?,
    val environmentID: String?,
    val updatedAt: String?,
)

/** One bounded page of pending creative requests (`nextCursor` is opaque). */
data class CreativeDesignPendingPage(
    val requests: List<CreativeDesignPendingRequest>,
    val nextCursor: String?,
)

/**
 * Verified staged-import + first-result bind receipt.
 *
 * [imported] is true only when this call created the canonical asset row;
 * false means the content hash already existed and the canonical asset was
 * reused. [asset] is the canonical row, never a losing candidate id.
 */
data class CreativeDesignImportReceipt(
    val state: DesignStateProjection,
    val asset: CreativeDesignAsset,
    val imported: Boolean,
)
