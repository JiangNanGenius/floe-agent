// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.*
import org.junit.Test

class PhoneControlObservationTextTest {
    @Test fun emptyInputAndLabelledParentSurviveTheCompactProjection() {
        val nodes = listOf(
            testNode(ref = "n0", className = "android.widget.FrameLayout"),
            testNode(ref = "n1", parentRef = "n0", clickable = true),
            testNode(ref = "n2", parentRef = "n1", contentDescription = "Save"),
            testNode(ref = "n3", parentRef = "n0", className = "android.widget.EditText", editable = true),
        )
        val text = PhoneControlObservationText.summary(testObservation(nodes))
        assertTrue(text.contains("n3|EditText|e|[empty input]"))
        assertTrue(text.contains("n1|TextView|c|Save"))
        assertTrue(text.contains("n2|TextView|-|Save"))
        assertTrue(text.indexOf("n3|") < text.indexOf("n2|"))
    }

    @Test fun nestedButtonDoesNotGiveItsLabelToAnotherButtonAndSecretsStayMasked() {
        val nodes = listOf(
            testNode(ref = "n0", clickable = true),
            testNode(ref = "n1", parentRef = "n0", clickable = true),
            testNode(ref = "n2", parentRef = "n1", text = "Save"),
            testNode(ref = "n3", editable = true, text = "private-value", password = true),
            testNode(ref = "n4", text = "hidden-value", redacted = true),
        )
        val text = PhoneControlObservationText.summary(testObservation(nodes))
        assertTrue(text.contains("n0|TextView|c|[button]"))
        assertTrue(text.contains("n1|TextView|c|Save"))
        assertFalse(text.contains("private-value"))
        assertFalse(text.contains("hidden-value"))
        assertFalse(text.contains("n3|TextView|e|"))
    }

    @Test fun emptyInputWinsTheBudgetAndProtectedFloeHasNoNodeRefs() {
        val labels = (0..100).map { testNode(ref = "n$it", text = "Label ".repeat(30)) }
        val input = testNode(ref = "n200", className = "android.widget.EditText", editable = true)
        val observation = testObservation(labels + input)
        val text = PhoneControlObservationText.summary(observation)
        assertTrue(text.length <= 1_850)
        assertTrue(text.contains("n200|EditText|e|[empty input]"))
        val protected = PhoneControlObservationText.summary(observation.copy(navigationOnly = true))
        assertTrue(protected.contains("navigation-only"))
        assertFalse(protected.contains("n200|"))
    }

    @Test fun coverageDigestSeparatesSummaryFromCaptureTruncation() {
        val nodes = listOf(
            testNode(ref = "n0", text = "Editor"),
            testNode(ref = "n1", parentRef = "n0", text = "Title", clickable = true),
            testNode(ref = "n2", parentRef = "n0", className = "android.widget.EditText", editable = true),
            testNode(ref = "n3", text = "Hidden", visible = false),
        )
        val complete = PhoneControlObservationText.summary(testObservation(nodes), maxNodes = 40)
        assertTrue(complete.contains("coverage=capturedPage"))
        assertTrue(complete.contains("source=nativeTree"))
        assertTrue(complete.contains("assoc=structural"))
        assertTrue(complete.contains("parents=2"))
        assertTrue(complete.contains("bounds=4"))
        assertTrue(complete.contains("next=page observationId+offset") || complete.contains("next=all captured"))

        val projection = PhoneControlObservationText.summary(testObservation(nodes), maxNodes = 1)
        assertTrue(projection.length <= 1_800)
        assertTrue(projection.contains("rows="))
        assertTrue(projection.contains("next=page observationId+offset for retained rows"))
        assertTrue(projection.contains("short is not absent"))

        val capture = PhoneControlObservationText.summary(
            testObservation(nodes, truncated = true, scannedNodeCount = 400,
                selectionLimited = true, omittedActionableCount = 2),
            maxNodes = 1,
        )
        assertTrue(capture.length <= 1_800)
        assertTrue(capture.contains("next=page observationId+offset for retained rows; refresh/scroll"))
        assertTrue(capture.contains("short is not absent"))

        val unready = PhoneControlObservationText.summary(
            testObservation(emptyList(), scannedNodeCount = 0), maxNodes = 40)
        assertTrue(unready.contains("next=observe again"))
        assertTrue(unready.contains("short is not absent"))
    }

    @Test fun adbStructuredSourceAndBackendAreReportedWithoutInventingFacts() {
        val text = PhoneControlObservationText.summary(
            testObservation(listOf(testNode(ref = "n0", text = "Save", clickable = true)))
                .copy(
                    backend = PhoneControlBackend.ADB_UI_AUTOMATION,
                    provenance = "adbUiAutomation",
                ),
        )
        assertTrue(text.contains("source=adbUiAutomation"))
        assertTrue(text.contains("backend=adbUiAutomation"))
        assertTrue(text.contains("short is not absent"))
    }

    @Test fun textOnlyTruncationIsNamedAsARealValueCap() {
        val text = PhoneControlObservationText.summary(
            testObservation(listOf(testNode(text = "A long label")),
                truncated = true, textLimited = true),
        )
        assertTrue(text.contains("long values are genuinely shortened"))
        assertTrue(text.contains("short is not absent"))
    }
}
