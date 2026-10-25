// SPDX-License-Identifier: MPL-2.0
// Feature/browser unit tests for the G04-R2 address commit contract.
// Authored (job-db20e94a68474091), NOT executed in this source lane; Main's
// unified batch runs :feature/browser unit tests after integration. Pure JVM,
// no Robolectric, same dependency surface as the existing BrowserProjection-
// PresenterTest (testImplementation(libs.junit) only).
package com.floe.android.feature.browser

import com.floe.android.feature.browser.api.BrowserPanelOperation
import com.floe.android.feature.browser.api.BrowserServiceCallbacks
import com.floe.android.feature.browser.api.BrowserServicePort
import org.junit.Assert.assertEquals
import org.junit.Test

class BrowserAddressCommitTest {
    /** Legacy-shape port: implements only the original no-arg commit. */
    private open class LegacyFake : BrowserServicePort {
        var legacyCommits = 0
        var editingClears = 0
        override val taskId: String = "00000000-0000-0000-0000-000000000001"
        override val workspaceId: String = "00000000-0000-0000-0000-000000000002"
        override val rootEpoch: Long = 1
        override fun attach(callbacks: BrowserServiceCallbacks) = Unit
        override fun submitTool(requestId: String, toolName: String, argsJson: String) = Unit
        override fun submitCommand(requestId: String, commandJson: String) = Unit
        override fun ingestLifecycle(eventJson: String) = Unit
        override fun requestPopupDecision(requestId: String, tabId: String, url: String) = Unit
        override fun requestDownload(requestId: String, queryJson: String) = Unit
        override fun bindVisible() = Unit
        override fun unbindVisible() = Unit
        override fun setAddressText(text: String) = Unit
        override fun setEditingAddress(editing: Boolean) { if (!editing) editingClears += 1 }
        override fun navigateFromAddressBar() { legacyCommits += 1 }
        override fun requestReload() = Unit
        override fun goBackTab() = Unit
        override fun goForwardTab() = Unit
        override fun performPanelOperation(operation: BrowserPanelOperation) = Unit
        override fun takeControl() = Unit
        override fun returnToAgent(receiptId: String, continueTask: Boolean) = Unit
        override fun consumePendingPanelRequest() = Unit
        override fun dismissPanel() = Unit
    }

    @Test
    fun `draft commit default preserves the legacy commit shape`() {
        val port = LegacyFake()
        port.navigateFromAddressBar(draft = "http://127.0.0.1:61240/index.html")
        // The interface default is exactly the old UI sequence: clear the
        // editing flag, then commit. A host that overrides the draft method
        // with the atomic owned call replaces it (next test).
        assertEquals(1, port.legacyCommits)
        assertEquals(1, port.editingClears)
    }

    @Test
    fun `draft-carrying override replaces rather than doubles the commit`() {
        val base = LegacyFake()
        var seen: String? = null
        val atomic = object : BrowserServicePort by base {
            override fun navigateFromAddressBar(draft: String) { seen = draft }
        }
        atomic.navigateFromAddressBar(draft = "https://example.test/floe")
        assertEquals("https://example.test/floe", seen)
        assertEquals(0, base.legacyCommits)
        assertEquals(0, base.editingClears)
    }
}
