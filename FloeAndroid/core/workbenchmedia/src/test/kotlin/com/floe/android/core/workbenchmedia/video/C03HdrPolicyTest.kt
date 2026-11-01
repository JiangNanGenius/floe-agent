// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import androidx.media3.common.C
import android.media.MediaCodecInfo.CodecProfileLevel
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_TRANSITION
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class C03HdrPolicyTest {
    @Test
    fun signalledDynamicHdrIsRefusedEvenWhenStaticColorFieldsAreMissing() {
        val sources = listOf(
            SourceVideoColor(null, null, null, null, mimeType = "video/dolby-vision"),
            SourceVideoColor(null, null, null, null, dynamicHdrMetadataPresent = true),
            SourceVideoColor(null, null, null, null, mimeType = "video/hevc",
                codecProfile = CodecProfileLevel.HEVCProfileMain10HDR10Plus),
            SourceVideoColor(null, null, null, null, mimeType = "video/av01",
                codecProfile = CodecProfileLevel.AV1ProfileMain10HDR10Plus),
            SourceVideoColor(null, null, null, null, mimeType = "video/x-vnd.on2.vp9",
                codecProfile = CodecProfileLevel.VP9Profile3HDR10Plus),
        )
        for (source in sources) {
            expectRefusal(UNSUPPORTED_SOURCE_FORMAT) {
                HdrSourcePolicy.plan(listOf(source), hasCrossDissolve = false)
            }
        }
    }

    private fun staticInfo(seed: Int = 0): ByteArray = ByteArray(25) { (it + seed).toByte() }

    private fun hdr10(
        hdrStaticInfo: ByteArray? = staticInfo(),
        standard: Int = C.COLOR_SPACE_BT2020,
        range: Int = C.COLOR_RANGE_LIMITED,
    ) = SourceVideoColor(
        colorStandard = standard,
        colorTransfer = C.COLOR_TRANSFER_ST2084,
        colorRange = range,
        hdrStaticInfo = hdrStaticInfo,
    )

    @Test
    fun pqBt2020IsKeptAsHdr10WithItsStaticInfo() {
        val plan = HdrSourcePolicy.plan(listOf(hdr10()), hasCrossDissolve = false)
        assertEquals(HdrKind.HDR10, plan.kind)
        assertTrue(plan.isHdr)
        assertEquals(C.COLOR_SPACE_BT2020, plan.colorStandard)
        assertEquals(C.COLOR_TRANSFER_ST2084, plan.colorTransfer)
        assertEquals(C.COLOR_RANGE_LIMITED, plan.colorRange)
        assertTrue(plan.sameStaticInfo(staticInfo()))
    }

    @Test
    fun hlgIsClassifiedExplicitly() {
        val plan = HdrSourcePolicy.plan(
            listOf(
                SourceVideoColor(
                    colorStandard = C.COLOR_SPACE_BT2020,
                    colorTransfer = C.COLOR_TRANSFER_HLG,
                    colorRange = C.COLOR_RANGE_LIMITED,
                    hdrStaticInfo = null,
                ),
            ),
            hasCrossDissolve = false,
        )
        assertEquals(HdrKind.HLG, plan.kind)
    }

    @Test
    fun sdrOnlyTimelineStaysSdr() {
        val plan = HdrSourcePolicy.plan(
            listOf(
                SourceVideoColor(
                    colorStandard = C.COLOR_SPACE_BT709,
                    colorTransfer = C.COLOR_TRANSFER_SDR,
                    colorRange = C.COLOR_RANGE_LIMITED,
                    hdrStaticInfo = null,
                ),
            ),
            hasCrossDissolve = false,
        )
        assertEquals(HdrKind.SDR, plan.kind)
    }

    @Test
    fun mixingHdrAndSdrIsRefused() {
        expectRefusal(UNSUPPORTED_SOURCE_FORMAT) {
            HdrSourcePolicy.plan(
                listOf(
                    hdr10(),
                    SourceVideoColor(
                        colorStandard = C.COLOR_SPACE_BT709,
                        colorTransfer = C.COLOR_TRANSFER_SDR,
                        colorRange = C.COLOR_RANGE_LIMITED,
                        hdrStaticInfo = null,
                    ),
                ),
                hasCrossDissolve = false,
            )
        }
    }

    @Test
    fun hdrWithCrossDissolveIsRefusedRatherThanToneMapped() {
        expectRefusal(UNSUPPORTED_TRANSITION) {
            HdrSourcePolicy.plan(listOf(hdr10()), hasCrossDissolve = true)
        }
    }

    @Test
    fun differentStaticMetadataCannotBeGuessed() {
        expectRefusal(UNSUPPORTED_SOURCE_FORMAT) {
            HdrSourcePolicy.plan(
                listOf(hdr10(staticInfo(0)), hdr10(staticInfo(1))),
                hasCrossDissolve = false,
            )
        }
    }

    @Test
    fun nonStandardStaticPayloadIsRefusedBeforeEncoding() {
        expectRefusal(UNSUPPORTED_SOURCE_FORMAT) {
            HdrSourcePolicy.plan(
                listOf(hdr10(ByteArray(8))),
                hasCrossDissolve = false,
            )
        }
    }

    @Test
    fun missingBt2020PrimariesIsRefused() {
        expectRefusal(UNSUPPORTED_SOURCE_FORMAT) {
            HdrSourcePolicy.plan(
                listOf(hdr10(standard = C.COLOR_SPACE_BT709)),
                hasCrossDissolve = false,
            )
        }
    }

    private fun expectRefusal(code: String, block: () -> Unit) {
        try {
            block()
            fail("Expected a typed refusal")
        } catch (failure: MediaRefusal) {
            assertEquals(code, failure.code)
        }
    }
}
