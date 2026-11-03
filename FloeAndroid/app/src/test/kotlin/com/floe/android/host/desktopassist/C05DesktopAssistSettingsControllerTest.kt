// SPDX-License-Identifier: MPL-2.0
//
// Authored, NOT RUN in this lane: the App-scoped settings controller's
// edit/save/delete lifecycle, its stale-epoch refusal, its RAM-only secret
// boundary and its drain-on-stop ownership.

package com.floe.android.host.desktopassist

import com.floe.android.feature.desktopassist.DesktopAssistCardUi
import com.floe.android.feature.desktopassist.DesktopAssistHostUi
import com.floe.android.feature.desktopassist.DesktopAssistKinds
import com.floe.android.feature.desktopassist.DesktopAssistNotice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C05DesktopAssistSettingsControllerTest {
    private class FakePort : DesktopAssistHostPort {
        var cards = mutableListOf<DesktopAssistCardUi>()
        var hosts = listOf(DesktopAssistHostUi("h1", "Studio", "10.0.0.9"))
        var qualified = true
        var created = mutableListOf<Triple<String, String, String>>()
        var updates = mutableListOf<Triple<String, String?, String?>>()
        var deletes = mutableListOf<String>()
        var failNext = false

        override fun ocrStatus(epoch: Long): Boolean = qualified

        override fun listCards(epoch: Long): List<DesktopAssistCardUi> = cards

        override fun listHosts(epoch: Long): List<DesktopAssistHostUi> = hosts

        override fun createCard(
            epoch: Long,
            label: String,
            kind: String,
            secret: String,
            hostID: String?,
        ): DesktopAssistCardUi {
            if (failNext) throw com.floe.android.host.remote.C05RemoteFailure("desktopAssistCredentialUnavailable")
            created.add(Triple(label, kind, secret))
            val card = DesktopAssistCardUi(
                id = "c${created.size}",
                reference = "⟨credential:c${created.size}⟩",
                label = label,
                kind = kind,
                hostID = hostID,
                typingAllowed = true,
                updatedAtLabel = null,
            )
            cards = (cards + card).toMutableList()
            return card
        }

        override fun updateCard(
            epoch: Long,
            id: String,
            label: String?,
            secret: String?,
        ): DesktopAssistCardUi {
            if (failNext) throw com.floe.android.host.remote.C05RemoteFailure("desktopAssistCardNotFound")
            updates.add(Triple(id, label, secret))
            val existing = cards.first { it.id == id }
            val updated = existing.copy(label = label ?: existing.label)
            cards = cards.map { if (it.id == id) updated else it }.toMutableList()
            return updated
        }

        override fun deleteCard(epoch: Long, id: String) {
            deletes.add(id)
            cards = cards.filterNot { it.id == id }.toMutableList()
        }
    }

    private fun controller(
        port: FakePort,
        epoch: Long? = 7,
    ): C05DesktopAssistSettingsController = C05DesktopAssistSettingsController(
        scope = CoroutineScope(Dispatchers.Unconfined),
        ioDispatcher = Dispatchers.Unconfined,
        currentNativeEpoch = { epoch },
        client = port,
    )

    @Test
    fun refreshLoadsCardsHostsAndOcrReadiness() {
        val port = FakePort()
        port.cards = mutableListOf(
            DesktopAssistCardUi("c1", "⟨credential:c1⟩", "Desk", DesktopAssistKinds.WEBSITE_PASSWORD, null, true, null),
        )
        val controller = controller(port)
        controller.refresh()
        val state = controller.state.value
        assertFalse(state.loading)
        assertTrue(state.loaded)
        assertEquals(1, state.cards.size)
        assertEquals(1, state.hosts.size)
        assertEquals(true, state.linuxShellQualified)
    }

    @Test
    fun staleEpochRefusesEveryEffect() {
        val port = FakePort()
        val controller = controller(port, epoch = null)
        controller.refresh()
        controller.beginCreate()
        controller.save("any", "Desk", DesktopAssistKinds.WEBSITE_PASSWORD, null, "pw")
        controller.delete("c1")
        assertTrue(port.created.isEmpty())
        assertTrue(port.deletes.isEmpty())
        assertEquals(DesktopAssistNotice.UNAVAILABLE, controller.state.value.notice)
    }

    @Test
    fun saveKeepsSecretOutOfStateAndDrainsOnStop() = runBlocking {
        val port = FakePort()
        val controller = controller(port)
        controller.refresh()
        controller.beginCreate()
        val editor = controller.state.value.editor!!
        controller.save(
            editor.editorID,
            "Desk login",
            DesktopAssistKinds.WEBSITE_PASSWORD,
            "h1",
            "super-secret",
        )
        assertEquals(1, port.created.size)
        assertEquals("super-secret", port.created.single().third)
        assertEquals(DesktopAssistNotice.SAVED, controller.state.value.notice)
        assertNull(controller.state.value.editor)
        // The immutable state must never carry the typed secret.
        assertFalse(controller.state.value.toString().contains("super-secret"))

        controller.stop()
        controller.beginCreate()
        controller.save(
            controller.state.value.editor?.editorID ?: "gone",
            "Later",
            DesktopAssistKinds.GENERIC_TOKEN,
            null,
            "later-secret",
        )
        assertEquals(1, port.created.size)
    }

    @Test
    fun editingAnExistingCardCanKeepTheSavedSecret() {
        val port = FakePort()
        port.cards = mutableListOf(
            DesktopAssistCardUi("c1", "⟨credential:c1⟩", "Desk", DesktopAssistKinds.WEBSITE_PASSWORD, null, true, null),
        )
        val controller = controller(port)
        controller.refresh()
        controller.beginEdit("c1")
        val editor = controller.state.value.editor!!
        controller.save(editor.editorID, "Desk 2", DesktopAssistKinds.WEBSITE_PASSWORD, null, "")
        assertEquals(1, port.updates.size)
        assertEquals("Desk 2", port.updates.single().second)
        assertNull(port.updates.single().third)
    }

    @Test
    fun overlongSecretIsRejectedBeforeTheBridge() {
        val port = FakePort()
        val controller = controller(port)
        controller.refresh()
        controller.beginCreate()
        val editor = controller.state.value.editor!!
        controller.save(
            editor.editorID,
            "Desk",
            DesktopAssistKinds.WEBSITE_PASSWORD,
            null,
            "x".repeat(4_097),
        )
        assertTrue(port.created.isEmpty())
        assertEquals(DesktopAssistNotice.INVALID, controller.state.value.notice)
    }

    @Test
    fun deleteUsesTheCardIdentityAndReportsDeletion() {
        val port = FakePort()
        port.cards = mutableListOf(
            DesktopAssistCardUi("c1", "⟨credential:c1⟩", "Desk", DesktopAssistKinds.WEBSITE_PASSWORD, null, true, null),
        )
        val controller = controller(port)
        controller.refresh()
        controller.delete("c1")
        assertEquals(listOf("c1"), port.deletes)
        assertEquals(DesktopAssistNotice.DELETED, controller.state.value.notice)
        assertTrue(controller.state.value.cards.isEmpty())
    }
}
