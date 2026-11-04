// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.state

import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.*
import com.floe.android.feature.workbench.ui.api.*
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlin.coroutines.CoroutineContext
import org.junit.Assert.*
import org.junit.Test

class MediaEditorGallerySaveTest {
 private class Queue : CoroutineDispatcher() {
  private val pending = ArrayDeque<Runnable>()
  override fun dispatch(context: CoroutineContext, block: Runnable) { pending.addLast(block) }
  fun drain() { while (pending.isNotEmpty()) pending.removeFirst().run() }
 }
 private fun controller(scope: CoroutineScope, save: MediaGallerySavePort): MediaEditorController {
  val host = Proxy.newProxyInstance(WorkbenchHostApi::class.java.classLoader,
   arrayOf(WorkbenchHostApi::class.java)) { _, method, _ ->
    error("Unexpected native call: ${method.name}")
   } as WorkbenchHostApi
  val ports = object : MediaEditorPorts {
   override val sourceCreate: MediaSourceCreate get() = error("Unused source port")
   override val assetImport: MediaAssetImport get() = error("Unused import port")
   override val gallerySave = save
  }
  val project = MediaProject(id="project-current", kind="video", name="same-name",
   createdAt="2026-11-04T00:00:00Z", updatedAt="2026-11-04T00:00:00Z", revision=2, ownerKind="standalone")
  return MediaEditorController(host, ports,
   MediaProjectEnvelope(project, "/fixture", CreativeStorageLayer.AppOwned, true),
   "session-current", CreativeStorageLayer.AppOwned, null, false, scope)
 }
 private fun receipt(projectID: String = "project-current") = MediaExportReceipt(
  MediaExportReceiptBinding(projectID, "/fixture", 2, "digest", "attempt-current"),
  MediaExportKind.VIDEO, "Exports/current.mp4", "video/mp4", 4,
  "a".repeat(64), ExportVerification(true, 1.0, 16, 16, 0, "mp4", "video/avc"),
  "2026-11-04T00:00:00Z")

 @Test fun duplicateSaveAndClearCannotDropPendingOwnership() {
  val queue = Queue()
  val scope = CoroutineScope(SupervisorJob() + queue)
  val completion = CompletableDeferred<MediaGallerySaveOutcome>()
  var calls = 0
  val editor = controller(scope, MediaGallerySavePort { _, _, _ -> calls++; completion.await() })
  editor.saveReceiptToGallery("job-first", receipt())
  assertTrue(editor.gallerySave.busy)
  assertEquals("job-first", editor.gallerySave.jobID)
  editor.saveReceiptToGallery("job-second", receipt())
  editor.clearGallerySave("job-first")
  assertTrue(editor.gallerySave.busy)
  queue.drain()
  assertEquals(1, calls)
  completion.complete(MediaGallerySaveOutcome.Saved(
   "content://fixture/1", "first.mp4", 4, "a".repeat(64), "a".repeat(64)))
  queue.drain()
  assertFalse(editor.gallerySave.busy)
  assertEquals("job-first", editor.gallerySave.jobID)
  assertEquals("first.mp4", editor.gallerySave.savedDisplayName)
  editor.clearGallerySave("job-other")
  assertEquals("first.mp4", editor.gallerySave.savedDisplayName)
  editor.clearGallerySave("job-first")
  assertNull(editor.gallerySave.jobID)
  scope.cancel()
 }
 @Test fun foreignReceiptNeverReachesGalleryAndFailureKeepsRequestedJob() {
  val queue = Queue()
  val scope = CoroutineScope(SupervisorJob() + queue)
  var calls = 0
  val editor = controller(scope, MediaGallerySavePort { _, _, _ -> calls++
   error("Foreign receipt reached gallery") })
  editor.saveReceiptToGallery("job-foreign", receipt("other-project"))
  queue.drain()
  assertEquals(0, calls)
  assertFalse(editor.gallerySave.busy)
  assertEquals("job-foreign", editor.gallerySave.jobID)
  assertEquals("galleryOwnerMismatch", editor.gallerySave.failure?.code)
  scope.cancel()
 }
}
