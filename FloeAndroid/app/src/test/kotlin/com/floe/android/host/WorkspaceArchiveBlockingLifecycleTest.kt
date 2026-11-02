// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

/** Deliberately blocking transport models JNI: coroutine cancellation alone
 * cannot settle it. No archive, network, provider or device is accessed. */
class WorkspaceArchiveBlockingLifecycleTest {
    private class Fixture : AutoCloseable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val discarded = CountDownLatch(1)
        val nativeActive = AtomicBoolean(false)
        var epoch = 42L
        val owner = Owner(UUID.randomUUID().toString(), UUID.randomUUID().toString(), 42L, 7L)
        val controller = WorkspaceArchiveHostController(scope, Dispatchers.IO, { epoch }, { 7L }, { false },
            WorkspaceArchiveHostClient(WorkspaceArchiveTransport { request ->
                when {
                    request.contains("g04.archive.listing") -> """{"ok":true,"version":25,"format":"zip","entries":[{"path":"a.txt","isDirectory":false,"size":3}],"entryCount":1,"truncated":false,"summary":"listed"}"""
                    request.contains("g04.archive.previewEntry") -> {
                        entered.countDown()
                        check(release.await(5, TimeUnit.SECONDS))
                        """{"ok":true,"version":25,"previewable":true,"byteCount":3,"truncated":false,"text":"old"}"""
                    }
                    request.contains("g04.archive.previewDiscard") -> {
                        discarded.countDown()
                        """{"ok":true,"version":25,"discarded":1}"""
                    }
                    request.contains("g04.archive.extract") -> {
                        nativeActive.set(true)
                        """{"ok":false,"version":25,"code":"failed"}"""
                    }
                    request.contains("g04.archive.cancel") -> """{"ok":true,"version":25,"cancelled":true}"""
                    request.contains("g04.archive.progress") -> if (nativeActive.get())
                        """{"ok":true,"version":25,"phase":"running","completedBytes":0,"completedEntries":0,"cancelled":true}"""
                    else """{"ok":false,"version":25,"code":"invalidOperationID"}"""
                    else -> error("Unexpected archive request")
                }
            }), pollIntervalMillis = 10_000)

        suspend fun open(token: Long) {
            assertTrue(controller.open(owner, "docs/$token.zip", token))
            withTimeout(2_000) { controller.state.first { it is WorkspaceArchiveState.Listed && it.token == token } }
        }
        override fun close() {
            release.countDown()
            nativeActive.set(false)
            runBlocking { controller.prepareForRootStop(3_000) }
            scope.cancel()
        }
    }

    @Test fun closeReturnsWhileJNIIsBlockedAndOldPreviewCannotReplaceNextDocument() = runBlocking {
        Fixture().use { f ->
            f.open(1)
            f.controller.previewEntry("a.txt")
            assertTrue(f.entered.await(2, TimeUnit.SECONDS))
            val ui = Executors.newSingleThreadExecutor()
            try {
                ui.submit { f.controller.close(1) }.get(1, TimeUnit.SECONDS)
                assertEquals(1L, f.discarded.count)
                f.open(2)
                f.release.countDown()
                assertTrue(f.discarded.await(2, TimeUnit.SECONDS))
                assertEquals(2L, (f.controller.state.value as WorkspaceArchiveState.Listed).token)
                assertEquals(WorkspaceArchivePreviewState.Idle, f.controller.preview.value)
            } finally {
                f.release.countDown()
                ui.shutdownNow()
            }
        }
    }

    @Test fun rootDrainWaitsForPhysicalReturnAndFencesTheRetiringEpoch() = runBlocking {
        Fixture().use { f ->
            f.open(1)
            f.controller.previewEntry("a.txt")
            assertTrue(f.entered.await(2, TimeUnit.SECONDS))
            assertFalse(f.controller.prepareForRootStop(100))
            assertFalse(f.controller.open(f.owner, "docs/new.zip", 2))
            f.release.countDown()
            assertTrue(f.controller.prepareForRootStop(2_000))
        }
    }

    @Test fun failedBridgeReplyDoesNotProveNativeMutationSettled() = runBlocking {
        Fixture().use { f ->
            f.open(1)
            f.controller.extractConfirmed(1)
            withTimeout(2_000) { f.controller.state.first { it is WorkspaceArchiveState.Listed && it.extractFailure != null } }
            assertFalse(f.controller.prepareForRootStop(1_000))
            f.nativeActive.set(false)
            assertTrue(f.controller.prepareForRootStop(1_000))
        }
    }
}
