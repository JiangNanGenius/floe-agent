// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import java.io.File

/** Main-owned, fixed interface for the parallel host and pure verifier lanes.
 * These inputs carry facts from the trusted ticket/engine owner, never model
 * authority. The verifier must independently prove the saved bytes/content.
 */
internal data class OfficeAiVerificationBaseline(
    val file: File,
    val sha256: String,
    val bytes: Long,
    val partIndex: Int?,
    val priorSelectionText: String?,
)

internal data class OfficeAiVerificationInput(
    val file: File,
    val sha256: String,
    val bytes: Long,
    val format: String,
    val command: String,
    val expectedText: String,
    val contentKind: String?,
    val cellAddress: String?,
    val partIndex: Int?,
    val baseline: OfficeAiVerificationBaseline?,
    val nativeTargetEffectVerified: Boolean,
    val trustedCompletedJobProof: Boolean,
)

internal data class OfficeAiVerificationFacts(
    val partName: String?,
    val expectedContentMatches: Boolean,
    val expectedTextFound: Boolean?,
    val occurrenceCount: Int?,
    val replacementScope: String?,
    val cellTypeAttribute: String?,
    val cellHasFormula: Boolean?,
    val cellPersistedValue: String?,
    val cellTypeMatchesIntent: Boolean?,
    /** TRUE only when the SAVED formula's persisted computed result was
     * independently recomputed from the SAME saved workbook's persisted
     * dependency values and agrees with the cell's persisted cache/type
     * (`verified`/`errorCached`/`blankResult`). FALSE means the source is
     * saved but the shape/dependency context is outside the bounded contract:
     * explicitly unverified, never a result success. NULL when this edit is
     * not a formula intent (or its source did not match, so no result claim is
     * made). A missing/contradictory cache never reaches Verified facts: the
     * verifier answers a typed Refused code instead. */
    val cellFormulaResultVerified: Boolean? = null,
    /** `verified`/`errorCached`/`blankResult`/`unsupported`. */
    val cellFormulaResultOutcome: String? = null,
    /** Bounded structural reason (function/range/bound name), never a value
     * copied out of the workbook beyond a cell identity token. */
    val cellFormulaResultDetail: String? = null,
    val semanticDeltaVerified: Boolean,
    val targetEffectVerified: Boolean,
    val proofReused: Boolean,
    val changedFromOriginal: Boolean?,
    val limitations: List<String>,
)

internal sealed class OfficeAiVerificationResult {
    data class Verified(val facts: OfficeAiVerificationFacts) : OfficeAiVerificationResult()
    data class Refused(val code: String) : OfficeAiVerificationResult()
}

internal fun interface OfficeAiSavedPackageVerifier {
    fun inspect(input: OfficeAiVerificationInput): OfficeAiVerificationResult
}
