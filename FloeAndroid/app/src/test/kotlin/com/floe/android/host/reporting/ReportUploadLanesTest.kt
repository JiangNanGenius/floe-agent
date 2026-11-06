package com.floe.android.host.reporting

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class ReportUploadLanesTest {
    @Test fun textFinishesWhileAnAttachmentWaitsAndOtherAttachmentsStaySerialized() = runBlocking {
        val lanes = ReportUploadLanes()
        val releaseImage = CompletableDeferred<Unit>()
        val textReceipt = CompletableDeferred<String>()
        var secondImageStarted = false
        val first = launch(start = CoroutineStart.UNDISPATCHED) {
            lanes.withPermit(true) { releaseImage.await() }
        }
        val second = launch(start = CoroutineStart.UNDISPATCHED) {
            lanes.withPermit(true) { secondImageStarted = true }
        }
        val text = launch {
            lanes.withPermit(false) { textReceipt.complete("real-text-receipt") }
        }
        try {
            assertEquals("real-text-receipt", withTimeout(1000) { textReceipt.await() })
            assertFalse(secondImageStarted)
        } finally { releaseImage.complete(Unit) }
        first.join(); second.join(); text.join()
        assertTrue(secondImageStarted)
    }

    @Test fun cancellingAQueuedRequestDoesNotSendItOrKeepTheLaneLocked() = runBlocking {
        val lanes = ReportUploadLanes()
        val release = CompletableDeferred<Unit>()
        var cancelledRequestSent = false
        val first = launch(start = CoroutineStart.UNDISPATCHED) {
            lanes.withPermit(false) { release.await() }
        }
        val cancelled = launch(start = CoroutineStart.UNDISPATCHED) {
            lanes.withPermit(false) { cancelledRequestSent = true }
        }
        cancelled.cancel(); cancelled.join()
        release.complete(Unit); first.join()
        assertFalse(cancelledRequestSent)
        assertEquals("next", withTimeout(1000) { lanes.withPermit(false) { "next" } })
    }
}
