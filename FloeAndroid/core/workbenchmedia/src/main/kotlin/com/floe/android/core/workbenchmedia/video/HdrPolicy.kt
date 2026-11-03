// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import androidx.media3.common.C
import android.media.MediaCodecInfo.CodecProfileLevel
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import com.floe.android.core.workbenchmedia.util.refusal

internal enum class HdrKind {
    SDR,
    HDR10,
    HLG,
}

/** Source video color metadata read from the actual container track format. */
internal data class SourceVideoColor(
    val colorStandard: Int?,
    val colorTransfer: Int?,
    val colorRange: Int?,
    val hdrStaticInfo: ByteArray?,
    val mimeType: String? = null,
    val codecProfile: Int? = null,
    val dynamicHdrMetadataPresent: Boolean = false,
)

/**
 * Explicit output color decision for one composition. HDR is never a boolean
 * capability claim: this carries the exact transfer/primaries/range/static
 * metadata that the encoder and final container must retain.
 */
internal data class HdrPlan(
    val kind: HdrKind,
    val colorStandard: Int?,
    val colorTransfer: Int?,
    val colorRange: Int?,
    val hdrStaticInfo: ByteArray?,
) {
    val isHdr: Boolean get() = kind != HdrKind.SDR

    val label: String
        get() = when (kind) {
            HdrKind.SDR -> "SDR"
            HdrKind.HDR10 -> "HDR10 (PQ/BT.2020)"
            HdrKind.HLG -> "HLG (BT.2020)"
        }

    fun sameStaticInfo(other: ByteArray?): Boolean =
        when {
            hdrStaticInfo == null -> other == null
            other == null -> false
            else -> hdrStaticInfo.contentEquals(other)
        }
}

/**
 * Pure source-side HDR policy, shared by preview planning and export
 * planning. There is deliberately no "tone map to SDR" option here: a
 * composition either retains the exact HDR color metadata or it is refused
 * before an encoder or output file is opened.
 *
 * Media3 1.11.1's `DefaultVideoCompositor` rejects HDR inputs outright, so an
 * HDR timeline that needs a multi-sequence cross-dissolve cannot be rendered
 * without lying about its color. That case is a typed refusal, not a silent
 * SDR conversion.
 */
internal object HdrSourcePolicy {
    private const val SUPPORTED_STATIC_INFO_BYTES = 25

    fun plan(clips: List<SourceVideoColor>, hasCrossDissolve: Boolean): HdrPlan {
        if (clips.isEmpty()) return sdr()
        if (clips.any { it.mimeType == "video/dolby-vision" || hasDynamicHdr(it) }) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "This export path preserves static HDR10/HLG metadata only. " +
                    "Dolby Vision and signalled dynamic HDR cannot be preserved",
            )
        }
        val kinds = clips.map(::classify)
        if (kinds.all { it == HdrKind.SDR }) return sdr()
        if (kinds.any { it == HdrKind.SDR }) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "Mixing HDR and SDR video clips in one export is not supported; " +
                    "the output color space would be ambiguous",
            )
        }
        val first = clips.first()
        val kind = kinds.first()
        if (first.colorTransfer != C.COLOR_TRANSFER_ST2084 && first.colorTransfer != C.COLOR_TRANSFER_HLG) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "HDR static metadata is present without a declared PQ or HLG transfer; " +
                    "the source cannot be retained faithfully",
            )
        }
        if (first.colorStandard != C.COLOR_SPACE_BT2020) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "HDR source does not declare BT.2020 color primaries; HDR retention cannot be guaranteed",
            )
        }
        if (first.colorRange != C.COLOR_RANGE_LIMITED && first.colorRange != C.COLOR_RANGE_FULL) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "HDR source does not declare a valid color range; HDR retention cannot be guaranteed",
            )
        }
        for ((index, clip) in clips.withIndex()) {
            if (clip.colorStandard != first.colorStandard ||
                clip.colorTransfer != first.colorTransfer ||
                clip.colorRange != first.colorRange
            ) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "HDR clip ${index + 1} uses different color primaries, transfer or range; " +
                        "one output cannot preserve both without an explicit color conversion",
                )
            }
            if (!sameStaticInfo(first.hdrStaticInfo, clip.hdrStaticInfo)) {
                throw refusal(
                    UNSUPPORTED_SOURCE_FORMAT,
                    "HDR clip ${index + 1} carries different static metadata; " +
                        "one output cannot preserve both without guessing",
                )
            }
        }
        if (hasCrossDissolve) {
            throw refusal(
                UNSUPPORTED_TRANSITION,
                "HDR timelines with a cross dissolve are not supported: the Media3 1.11.1 " +
                    "video compositor rejects HDR inputs, and tone-mapping to SDR would lose HDR. " +
                    "Remove the dissolve or use an explicitly converted SDR copy",
            )
        }
        val staticInfo = first.hdrStaticInfo
        if (staticInfo != null && staticInfo.size != SUPPORTED_STATIC_INFO_BYTES) {
            throw refusal(
                UNSUPPORTED_SOURCE_FORMAT,
                "HDR static metadata has ${staticInfo.size} bytes; the platform muxer preserves " +
                    "only the $SUPPORTED_STATIC_INFO_BYTES-byte CTA-861.3 form",
            )
        }
        return HdrPlan(
            kind = kind,
            colorStandard = first.colorStandard,
            colorTransfer = first.colorTransfer,
            colorRange = first.colorRange,
            hdrStaticInfo = staticInfo?.copyOf(),
        )
    }

    private fun hasDynamicHdr(source: SourceVideoColor): Boolean =
        source.dynamicHdrMetadataPresent || when (source.mimeType) {
            "video/hevc" -> source.codecProfile == CodecProfileLevel.HEVCProfileMain10HDR10Plus
            "video/av01" -> source.codecProfile == CodecProfileLevel.AV1ProfileMain10HDR10Plus
            "video/x-vnd.on2.vp9" -> source.codecProfile == CodecProfileLevel.VP9Profile2HDR10Plus ||
                source.codecProfile == CodecProfileLevel.VP9Profile3HDR10Plus
            "video/apv" -> source.codecProfile == CodecProfileLevel.APVProfile422_10HDR10Plus
            else -> false
        }

    private fun classify(source: SourceVideoColor): HdrKind = when {
        source.colorTransfer == C.COLOR_TRANSFER_ST2084 -> HdrKind.HDR10
        source.colorTransfer == C.COLOR_TRANSFER_HLG -> HdrKind.HLG
        source.hdrStaticInfo != null -> HdrKind.HDR10
        else -> HdrKind.SDR
    }

    private fun sameStaticInfo(first: ByteArray?, other: ByteArray?): Boolean =
        when {
            first == null -> other == null
            other == null -> false
            else -> first.contentEquals(other)
        }

    private fun sdr() = HdrPlan(
        kind = HdrKind.SDR,
        colorStandard = null,
        colorTransfer = null,
        colorRange = null,
        hdrStaticInfo = null,
    )
}
