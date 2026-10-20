// SPDX-License-Identifier: MPL-2.0
//
// Component performance probe for the synchronous literal Find/Replace
// scanner over a meaningful long draft. It runs the same holder actions the
// real full-editor Find surface calls (query changes, rapid draft edits and
// close/reopen cancel) on the main thread and records the observed wall time
// for each step. It is evidence, not a benchmark claim: an emulator timing is
// not a device/App frame-rate proof. The generous 2s guard only catches an
// ANR-scale regression; it does not weaken any functional assertion.

package com.floe.android.feature.conversation

import android.content.Context
import android.util.Log
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConversationFindReplacePerformanceProbe {

    @get:Rule
    val composeRule = createAndroidComposeRule<ConversationUiFixtureActivity>()

    private lateinit var controller: ConversationFixtureController

    @Before
    fun setUp() {
        controller = composeRule.activity.controller
    }

    @Test
    fun longDraftRapidQueryEditAndCancelFlowRecordsActualStalls() {
        composeRule.runOnUiThread { controller.applyScenario(ConversationUiScenario.FULL_EDITOR) }
        composeRule.waitForIdle()
        val holder = requireNotNull(controller.threadHolder)
        val draft = buildString {
            while (length < 24_000) append("alpha beta gamma Δ 中文🙂 literal $\\. ")
        }
        val samples = mutableListOf<Pair<String, Double>>()

        fun measure(label: String, block: () -> Unit) {
            val started = System.nanoTime()
            block()
            samples += label to (System.nanoTime() - started) / 1_000_000.0
        }

        composeRule.runOnUiThread {
            measure("set-24k-draft") { holder.onDraftChange(TextFieldValue(draft)) }
            measure("open-editor-find") {
                holder.openFullEditor()
                holder.openFindInFullEditor()
            }
            // Rapid query growth, recomputing count/current over the same text.
            for (length in 1..16) {
                val query = "alpha beta gamma Δ 中文🙂 literal $\\".take(length)
                measure("query-$length") { holder.setFindQuery(query) }
            }
            // Rapid edits invalidate/recompute the Find snapshot while open.
            for (index in 1..12) {
                measure("edit-append-$index") {
                    holder.onDraftChange(holder.draft.value.copy(text = holder.draft.value.text + " x$index"))
                }
                measure("edit-delete-$index") {
                    holder.onDraftChange(holder.draft.value.copy(text = holder.draft.value.text.dropLast(3)))
                }
            }
            // Cancel/reopen only clears and recomputes the RAM presentation.
            for (index in 1..10) {
                measure("cancel-$index") { holder.closeFindInFullEditor() }
                measure("reopen-$index") { holder.openFindInFullEditor() }
            }
        }
        composeRule.waitForIdle()

        assertTrue("Find stayed on the shared long draft", holder.findReplace.isOpen)
        // Nine balanced append/delete pairs net 0; the three 4-character
        // appends (x10..x12) leave one extra character each.
        assertEquals(draft.length + 3, holder.draft.value.text.length)
        val total = samples.sumOf { it.second }
        val max = samples.maxOf { it.second }
        val report = buildString {
            appendLine("locale=${composeRule.activity.runLocale} theme=${composeRule.activity.runTheme}")
            appendLine("draftChars=${draft.length} steps=${samples.size}")
            appendLine("totalMs=${"%.3f".format(total)} maxMs=${"%.3f".format(max)}")
            samples.forEach { (label, ms) -> appendLine("$label=${"%.3f".format(ms)}") }
        }
        val directory = composeRule.activity.getDir("conversation-ui-screenshots", Context.MODE_PRIVATE)
        File(
            directory,
            "find-replace-perf-probe-${composeRule.activity.runLocale}-${composeRule.activity.runTheme}.txt",
        ).writeText(report)
        Log.i("FloeFindReplacePerf", report.replace('\n', ' '))
        assertTrue(
            "a synchronous Find/Replace step must not stall the main thread " +
                "(max=${"%.1f".format(max)}ms)",
            max < 2_000.0,
        )
    }
}
