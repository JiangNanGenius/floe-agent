// SPDX-License-Identifier: MPL-2.0
//
// C06 trusted-host client tests. Authored source; NOT RUN by this lane.

package com.floe.android.host.mail

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C06MailClientTest {
    private val owner = C06MailOwner("host-token-123", 7)

    @Test
    fun capabilitiesParseRealFlags() {
        val client = C06MailClient(C06MailTransport {
            """
            {"ok":true,"schema":"floe.mail/12","coreReady":true,"epoch":7,
             "credentialGatewayReady":true,"schemaReady":true,"transportReady":true,
             "accountCount":2,"maximumAccounts":20,"maximumMessageBytes":16000000,
             "maximumAttachmentBytes":10000000,"maximumChunkBytes":24576,"modelTools":true}
            """.trimIndent()
        })
        val capabilities = client.capabilities()
        assertTrue(capabilities.coreReady)
        assertEquals(7L, capabilities.epoch)
        assertEquals(2, capabilities.accountCount)
        assertTrue(capabilities.modelTools)
    }

    @Test
    fun accountListBuildsTypedRowsAndNeverContainsSecrets() {
        val client = C06MailClient(C06MailTransport {
            """
            {"ok":true,"accounts":[{"id":"11111111-1111-1111-1111-111111111111",
             "displayName":"Work","address":"work@example.com","incomingProtocol":"imap",
             "incoming":{"host":"imap.example.com","port":993,"tls":"implicitTLS","username":"work"},
             "outgoing":{"host":"smtp.example.com","port":465,"tls":"implicitTLS","username":"work"},
             "revision":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
            """.trimIndent()
        })
        val accounts = client.accountList(owner)
        assertEquals(1, accounts.size)
        assertEquals("imap.example.com", accounts[0].incomingHost)
        assertFalse(accounts[0].toString().contains("password"))
    }

    @Test
    fun accountSaveSendsBase64OnlyAndParsesSavedRow() {
        var captured = ""
        val client = C06MailClient(C06MailTransport { request ->
            captured = request
            """
            {"ok":true,"account":{"id":"11111111-1111-1111-1111-111111111111",
             "displayName":"Work","address":"work@example.com","incomingProtocol":"imap",
             "incoming":{"host":"imap.example.com","port":993,"tls":"implicitTLS","username":"work"},
             "outgoing":{"host":"smtp.example.com","port":465,"tls":"implicitTLS","username":"work"},
             "revision":1,"updatedAt":"2026-01-01T00:00:00Z"}}
            """.trimIndent()
        })
        val draft = C06MailAccountDraft(
            id = null,
            displayName = "Work",
            address = "work@example.com",
            incomingProtocol = "imap",
            incoming = C06MailServerUi("imap.example.com", 993, "implicitTLS", "work"),
            outgoing = C06MailServerUi("smtp.example.com", 465, "implicitTLS", "work"),
            incomingSecret = "incoming-pass",
            outgoingSecret = "outgoing-pass",
        )
        val saved = client.accountSave(draft, owner)
        assertEquals("work@example.com", saved.address)
        assertTrue(captured.contains("incomingSecretBase64"))
        assertFalse(captured.contains("incoming-pass"))
    }

    @Test
    fun searchAndMoveParseBoundedPages() {
        val json = Json { ignoreUnknownKeys = true }
        var operation = ""
        val client = C06MailClient(C06MailTransport { request ->
            operation = json.parseToJsonElement(request).jsonObject["operation"]!!.jsonPrimitive.content
            if (operation == "c06.search") {
                """
                {"ok":true,"page":{"folder":"INBOX","mailboxVersion":"100",
                 "messages":[{"id":"9","byteCount":123,"flags":[]}],"hasMore":false,
                 "nextCursor":"","totalMatched":1,"returned":1,"pageTruncated":false}}
                """.trimIndent()
            } else {
                """
                {"ok":true,"status":"completed","requestID":"22222222-2222-2222-2222-222222222222",
                 "messageID":"9","sourceFolder":"INBOX","destination":"Archive",
                 "destinationUID":"77","destinationMailboxVersion":"200","expunged":"targeted",
                 "destinationVerified":true,"replayed":false,"reconciled":false,
                 "receiptPersisted":true,"retryAutomatically":false}
                """.trimIndent()
            }
        })
        val page = client.search(
            accountID = "11111111-1111-1111-1111-111111111111",
            folder = "INBOX",
            draft = C06MailSearchDraft(text = "body"),
            cursor = null,
            limit = 20,
            owner = owner,
        )
        assertEquals(1, page.messages.size)
        assertEquals(1, page.totalMatched)
        val move = client.move(
            accountID = "11111111-1111-1111-1111-111111111111",
            requestID = "22222222-2222-2222-2222-222222222222",
            messageID = "9",
            folder = "INBOX",
            mailboxVersion = "100",
            action = "move",
            destination = "Archive",
            owner = owner,
        )
        assertEquals("completed", move.status)
        assertEquals("Archive", move.destination)
    }

    @Test
    fun typedFailureDoesNotEchoInternalDetail() {
        val client = C06MailClient(C06MailTransport {
            """{"ok":false,"code":"tlsFailed","reason":"tlsFailed","retryable":false}"""
        })
        try {
            client.capabilities()
            throw AssertionError("expected typed failure")
        } catch (failure: C06MailFailure) {
            assertEquals("tlsFailed", failure.code)
            assertFalse(failure.message.orEmpty().contains("password"))
        }
    }
}
