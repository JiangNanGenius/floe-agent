// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.PickPurpose
import com.floe.android.host.WorkspaceSourceAcceptedPick
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * G05-R3 repair 2026-10-27 — the Import form's target seed must come from
 * REAL provider metadata displayName ONLY (a browse-child selection).
 * A SAF document id — decoded or not — is an OPAQUE provider identity and
 * must never be converted into a user-facing path, and the old URI-segment
 * fallback printed percent-encoded ids ("Imported/primary%3ADownload%2F...")
 * straight into the default (device evidence FOLDER_IMPORT_FAILURE.json +
 * the reopened-form observation; Main review 2026-10-27). AUTHORED, NOTRUN
 * (Main runs the composed batch). No expectation weakened.
 */
class WorkspaceSourceImportSuggestionTest {

    private fun pick(displayName: String?, uri: String, kind: String,
                     documentId: String? = null) = WorkspaceSourceAcceptedPick(
        uri = uri, kind = kind, granted = setOf("READ"), persisted = setOf("READ"),
        transientOnly = false, needsRePick = false, purpose = PickPurpose.IMPORT,
        requestKey = "k", documentId = documentId, displayName = displayName,
    )

    @Test
    fun realProviderNameSeedsThePlainFolderOrFileName() {
        assertEquals("Imported/Floe-G05-R3-QA",
                     suggestedImportPath(pick("Floe-G05-R3-QA",
                         "content://com.android.externalstorage.documents/tree/primary%3ADownload%2FFloe-G05-R3-QA",
                         "TREE", documentId = "primary:Download/Floe-G05-R3-QA")))
        assertEquals("Imported/Quarterly report",
                     suggestedImportPath(pick("Quarterly report",
                         "content://com.android.externalstorage.documents/tree/primary%3ADownload%2Fqa/document/primary%3ADownload%2Fqa%2Freport.docx",
                         "DOCUMENT", documentId = "primary:Download/qa/report.docx")))
    }

    @Test
    fun opaqueIdsNeverSeedAnythingEvenWhenDecoded() {
        // Direct platform picks have NO trustworthy display name here: the
        // seed must stay EMPTY (never an opaque id, decoded or encoded), and
        // Import stays disabled until the user states the workspace path.
        assertEquals("", suggestedImportPath(pick(null,
            "content://com.android.externalstorage.documents/tree/primary%3ADownload%2FFloe-G05-R3-QA",
            "TREE", documentId = "primary:Download/Floe-G05-R3-QA")))
        assertEquals("", suggestedImportPath(pick(null,
            "content://media/external/images/media/42",
            "DOCUMENT", documentId = "42")))
        assertEquals("", suggestedImportPath(pick("", "content://provider/document/x", "DOCUMENT")))
        assertEquals("", suggestedImportPath(null))
    }

    @Test
    fun unsafeNameSegmentsAreNotSeeded() {
        listOf("a/b", "a\\b", ".", "..").forEach { bad ->
            assertEquals("", suggestedImportPath(pick(bad, "content://provider/document/x", "DOCUMENT")))
        }
    }
}
