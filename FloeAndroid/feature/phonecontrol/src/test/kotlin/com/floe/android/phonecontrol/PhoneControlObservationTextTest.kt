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
}
