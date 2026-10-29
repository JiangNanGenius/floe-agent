// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class OfficeReadOnlyProtocolTest {
    @Test fun orderedReplyRecordsLoadReadonlyWithoutConfusingFalseWithMissing() {
        assertEquals(false, OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":"false"}""".toByteArray()))
        assertEquals(true, OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":true}""".toByteArray()))
        assertNull(OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:Other","success":true}""".toByteArray()))
        assertNull(OfficeReadOnlyProtocol.barrierReport("""commandvalues: {"commandName":".uno:ReadOnly","success":"unknown"}""".toByteArray()))
    }

    @Test fun fontCacheUsesActualSecondaryUserDataDirectory() {
        val original = "<cachedir>/data/data/com.collabora.libreoffice/fontconfig</cachedir>"
        val actual = OfficePayloadBootstrap.rewriteFontsConf(original, "com.floe.agent.full", "/data/user/11/com.floe.agent.full")
        assertEquals("<cachedir>/data/user/11/com.floe.agent.full/fontconfig</cachedir>", actual)
        assertFalse(actual.contains("/data/data/"))
    }

    @Test fun nativeLoadCannotSwitchSnapshotOrAcquireRemoteAuthority() {
        val snapshot = File("/private/office/document.docx")
        assertTrue(OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=file:///private/office/document.docx lang=en", snapshot))
        assertTrue(OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=file%3A%2F%2F%2Fprivate%2Foffice%2Fdocument.docx", snapshot))
        for (url in listOf("https://example.org/document.docx", "file://host/private/office/document.docx", "file:///private/office/other.docx", "file:///private/office/document.docx?x=1", "file:///private/office/document.docx#part")) {
            assertFalse(url, OfficeReadOnlyProtocol.matchesSnapshotLoad("load url=$url", snapshot))
        }
    }

    @Test fun browserCannotEnableEditsOrRunUnknownMutationThroughPreviewGate() {
        for (command in listOf("uno .uno:Paste", "uno .uno:Cut", "uno .uno:DeleteRows", "uno .uno:InsertText text=x", "setviewreadonly value=false", "allowlinkupdate", "editwithpassword password=x", "future-mutation x=y", "status\nuno .uno:Paste")) {
            assertNotEquals(command, CoolMessageGate.Decision.FORWARD, CoolMessageGate.decide(command, true).decision)
        }
        for (command in listOf("tilecombine nviewid=0", "clientvisiblearea x=0 y=0 width=100 height=100", "uno .uno:Copy", "uno .uno:Zoom")) {
            assertEquals(command, CoolMessageGate.Decision.FORWARD, CoolMessageGate.decide(command, true).decision)
        }
    }

    @Test fun enterEditScriptActivatesProbesTransportBeforeAnyAck() {
        val script = OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT
        val activate = script.indexOf("notifyActive")
        val probe = script.indexOf("doSend")
        val connected = script.indexOf("connected")
        val witness = script.indexOf("'useractive'")
        val hook = script.indexOf("_proceedEditMode")
        // The causal ORDER is the safety property (page-mode79): genuine
        // activity first; then the bounded synchronous transport probe that
        // forces the pinned proxy's 30 s no-response watchdog to evaluate
        // BEFORE any edit ack (a dying socket closes here and the script
        // returns false instead of acking); then the connected() gate; then
        // the real `useractive` uplink witness the host must observe before
        // readiness; and only then the guarded page edit hook. A missing
        // hook or transport stays an honest false, never a fabricated ack.
        assertTrue(activate in 0 until probe)
        assertTrue(probe < connected)
        assertTrue(connected < witness)
        assertTrue(witness < hook)
        assertTrue(script.contains("return false"))
        assertTrue(script.contains("ps.readyState===1"))
    }

    @Test fun enterViewScriptStaysTheUntouchedPinnedHook() {
        val script = OfficeReadOnlyProtocol.PAGE_ENTER_VIEW_SCRIPT
        assertTrue(script.contains("_enterReadOnlyMode('readonly')"))
        assertFalse(script.contains("notifyActive"))
        assertFalse(script.contains("doSend"))
    }

    // --- page-transport85: genuine background transport surface ---

    @Test fun transportPingIsThePinnedProtocolHeartbeatToken() {
        // Verified against the pinned producer revision
        // 2333344185931274f9c49d6c12a408cefcef6844: wsd/ClientSession.cpp
        // answers a client `ping` itself with `pong rendercount=<n>`
        // (WSD-local, never forwarded to the kit, only after the document is
        // loaded). It must not alias any host-side reserved/interaction
        // class: it is not the `.uno:ReadOnly` barrier query and not an
        // interaction command (the host sends it on the native wire, never
        // through the page gate — a page could not smuggle it as one).
        assertEquals("ping", OfficeReadOnlyProtocol.TRANSPORT_PING)
        assertEquals("ping", OfficeReadOnlyProtocol.command(OfficeReadOnlyProtocol.TRANSPORT_PING))
        assertFalse(OfficeReadOnlyProtocol.isReservedQuery(OfficeReadOnlyProtocol.TRANSPORT_PING))
        assertFalse(OfficeReadOnlyProtocol.isInteraction(OfficeReadOnlyProtocol.TRANSPORT_PING))
        // A `pong` downlink answer is not a readiness/permission/save fact:
        // the triage classifies it OTHER (relay-only), asserted here against
        // the reserved host-side parsers.
        val pong = "pong rendercount=7".toByteArray()
        assertNull(OfficeReadOnlyProtocol.barrierReport(pong))
    }

    @Test fun transportHealthScriptIsStrictlyReadOnly() {
        val script = OfficeReadOnlyProtocol.PAGE_TRANSPORT_HEALTH_SCRIPT
        // Reads the page's OWN pinned counters (global.js:1552/1555/1564):
        assertTrue(script.contains("readyState"))
        assertTrue(script.contains("msgInflight"))
        assertTrue(script.contains("lastDataTimestamp"))
        assertTrue(script.contains("performance.now()"))
        // Never mutates page or transport state: no poll, no frame, no
        // lifecycle call. A health READ can never itself walk the throttle
        // ladder or close the socket.
        assertFalse(script.contains("doSend"))
        assertFalse(script.contains("sendMessage"))
        assertFalse(script.contains("_proceedEditMode"))
        assertFalse(script.contains("_enterReadOnlyMode"))
        assertFalse(script.contains("loadDocument"))
        assertFalse(script.contains("notifyActive"))
        // Guarded honesty shapes.
        assertTrue(script.contains("'nosocket'"))
        assertTrue(script.contains("return 'err'"))
    }

    @Test fun pollProbeScriptIsExactlyOneGuardedDoSend() {
        val script = OfficeReadOnlyProtocol.PAGE_POLL_PROBE_SCRIPT
        // ONE guarded doSend — the pump/drain probe with an execution
        // callback. No frame content, no edit entry, no activity forgery:
        // the poll is ordinary pinned downlink traffic (and the watchdog
        // evaluation it forces is the page's own pinned logic).
        // Exactly two occurrences: the typeof guard and the single call.
        assertEquals(2, Regex("doSend").findAll(script).count())
        assertTrue(script.contains("typeof window.socket.doSend==='function'"))
        assertFalse(script.contains("sendMessage"))
        assertFalse(script.contains("useractive"))
        assertFalse(script.contains("_proceedEditMode"))
        assertTrue(script.contains("return false"))
    }

    @Test fun parseTransportHealthAcceptsOnlyWellFormedPageTruth() {
        val ok = OfficeReadOnlyProtocol.parseTransportHealth("\"1|0|1234\"")
        assertEquals(1, ok?.readyState)
        assertEquals(0, ok?.msgInflight)
        assertEquals(1234L, ok?.stalenessMs)
        // Unquoted (defensive) and boundary shapes.
        assertEquals(1234L, OfficeReadOnlyProtocol.parseTransportHealth("1|0|1234")?.stalenessMs)
        val inflight = OfficeReadOnlyProtocol.parseTransportHealth("\"1|4|300000\"")
        assertEquals(4, inflight?.msgInflight)
        assertEquals(300000L, inflight?.stalenessMs)
        // A clock anomaly is reported, not hidden (decide() treats it as
        // NOT fresh).
        assertEquals(-1L, OfficeReadOnlyProtocol.parseTransportHealth("\"1|0|-1\"")?.stalenessMs)
        // Honest nulls: absent socket, page error, missing callback value,
        // garbage, wrong field count — never promoted to a health fact.
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("\"nosocket\""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("\"err\""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth(null))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth(""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("\"1|0\""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("\"1|0|2|3\""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("\"a|b|c\""))
        assertNull(OfficeReadOnlyProtocol.parseTransportHealth("null"))
    }

    @Test fun enterEditScriptStaysTheSingleAdmissionVerdict() {
        // The drain and the pump NEVER weaken the page-mode79 handshake:
        // the ordered script is unchanged and stays the only path that can
        // produce an edit ack (probe → connected gate → witness → hook).
        val script = OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT
        assertTrue(script.contains("for(var i=0;i<24&&ps.readyState===1;i++){ps.doSend();}"))
        assertTrue(script.contains("s.sendMessage('useractive')"))
        assertTrue(script.contains("_proceedEditMode"))
        // Separation: the health read is not smuggled into the admission
        // script and vice versa.
        assertFalse(script.contains("lastDataTimestamp"))
        assertFalse(
            OfficeReadOnlyProtocol.PAGE_TRANSPORT_HEALTH_SCRIPT.contains("_proceedEditMode"),
        )
    }
}
