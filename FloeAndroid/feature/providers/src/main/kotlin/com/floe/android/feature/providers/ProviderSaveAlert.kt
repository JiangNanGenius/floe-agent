// SPDX-License-Identifier: MPL-2.0
//
// Save-only alert lifecycle (⇄ ProviderEditorView.swift's save-error .alert).
//
// The host projection remains the only source of a save failure. This file
// adds presentation-only acknowledgement/attempt state so that:
//  - the current failure opens the alert immediately;
//  - dismissing/back only acknowledges it, never closes the editor or resets
//    the draft;
//  - the same message from a LATER attempt alerts again once the host reports
//    a new attempt boundary (save-in-flight or cleared error);
//  - a projection carrying an older editor id/epoch can never supply a
//    failure to the current editor.
//
// It is deliberately pure so the lifecycle is unit-testable without a device.

package com.floe.android.feature.providers

/** Presentation-only state of the save-failure alert for one editor. */
internal data class ProviderSaveAlertUi(
    /** Non-null while the alert is visible. */
    val message: String? = null,
    /** Host failure sequence this message belongs to (null for legacy input). */
    val failureSequence: Long? = null,
    /** Failure already acknowledged for the current attempt generation. */
    val acknowledgedMessage: String? = null,
    /** Host failure sequence acknowledged together with [acknowledgedMessage]. */
    val acknowledgedFailureSequence: Long? = null,
) {
    /**
     * Fold one host projection into the alert state.
     *
     * [saveInFlight] (or a cleared error) marks a new attempt boundary: the
     * previous acknowledgement is released so the SAME message from the new
     * attempt can alert again. [failureSequence] is the host's monotonic
     * save-failure sequence: a LATER sequence re-opens even an identical
     * message, which covers a retry that fails synchronously inside the save
     * dispatch and therefore never exposes a distinct in-flight frame. While
     * the same failure/sequence remains acknowledged, recomposition does not
     * reopen the alert.
     *
     * A null [failureSequence] keeps the legacy message-only behaviour used by
     * pure callers and older host projections.
     */
    fun observe(
        failureMessage: String?,
        saveInFlight: Boolean,
        failureSequence: Long? = null,
    ): ProviderSaveAlertUi {
        if (failureMessage == null) {
            return ProviderSaveAlertUi()
        }
        if (saveInFlight) {
            return copy(acknowledgedMessage = null, acknowledgedFailureSequence = null)
        }
        if (message != null) return this
        val sameAcknowledgedFailure = acknowledgedMessage == failureMessage &&
            (failureSequence == null || acknowledgedFailureSequence == failureSequence)
        if (sameAcknowledgedFailure) return this
        return copy(message = failureMessage, failureSequence = failureSequence)
    }

    /** Dismiss/OK: hide the current alert, remember exactly this failure. */
    fun acknowledge(): ProviderSaveAlertUi {
        val current = message ?: return this
        return copy(
            message = null,
            acknowledgedMessage = current,
            acknowledgedFailureSequence = failureSequence,
        )
    }
}

/**
 * Save-path failure for the CURRENT editor identity+epoch. A structured
 * [SaveOutcomeUi.Failed] is honoured when no plain save error exists; a
 * projection for another editor id/epoch is stale and returns null.
 */
internal fun currentSaveFailureMessage(
    editor: ProviderEditorUiState?,
    identity: ProviderEditorIdentity,
): String? {
    val current = editor?.takeIf { it.identity.isCurrentFor(identity) } ?: return null
    return current.saveError?.takeIf { it.isNotBlank() }
        ?: (current.saveOutcome as? SaveOutcomeUi.Failed)
            ?.message
            ?.takeIf { it.isNotBlank() }
}
