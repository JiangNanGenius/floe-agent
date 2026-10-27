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
