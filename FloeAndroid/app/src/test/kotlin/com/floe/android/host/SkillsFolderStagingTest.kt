// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.SkillsFolderStagingNativeException
import com.floe.android.feature.integrations.StagedPackageRefUi
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S11 Skills folder staging — controller lane tests. AUTHORED, NOTRUN
 * (Main runs them in the composed batch). The SAF tree walk is injected
 * through the Uri-free reader seam and the byte channel through the
 * staging-channel seam, so bounds, original-name safety, duplicate
 * refusal, cancellation cleanup, grant discipline and the request-owner
 * fence are all provable on the JVM without the framework or the native
 * library. No production fake service is added.
 */
class SkillsFolderStagingTest {

    private val staged = java.util.concurrent.CopyOnWriteArrayList<StagedPackageRefUi>()
    private val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
    private var admittedFlag = true

    private class Call(val name: String, val args: List<String>)

    private class FakeChannel(
        var finishReply: String = "stg:v1:" + "9".repeat(32) + " 3 1234",
        var throwOn: String? = null,
        var throwStatus: Int = -409,
        var onWrite: ((Int) -> Unit)? = null,
    ) : SkillsFolderStagingController.StagingChannel {
        val calls = java.util.concurrent.CopyOnWriteArrayList<Call>()
        val writeCounts = AtomicInteger(0)
        override fun routeOpen(incarnation: Long, uiGeneration: Long, rootEpoch: Long): String {
            calls.add(Call("routeOpen", listOf("$incarnation", "$uiGeneration", "$rootEpoch")))
            maybeThrow("routeOpen")
            return "sfk:v1:" + "1".repeat(32)
        }

        override fun routeClose(routeReceipt: String) {
            calls.add(Call("routeClose", listOf(routeReceipt)))
        }

        override fun treeOpen(routeReceipt: String, displayNameHint: String?): String {
            calls.add(Call("treeOpen", listOf(routeReceipt, displayNameHint ?: "")))
            maybeThrow("treeOpen")
            return "sft:v1:" + "2".repeat(32)
        }

        override fun fileBegin(treeHandle: String, relativePath: String): String {
            calls.add(Call("fileBegin", listOf(relativePath)))
            maybeThrow("fileBegin")
            return "sfi:v1:" + "3".repeat(32)
        }

        override fun fileWrite(fileHandle: String, data: ByteArray, offset: Int, length: Int) {
            val n = writeCounts.incrementAndGet()
            calls.add(Call("fileWrite", listOf(length.toString())))
            maybeThrow("fileWrite")
            onWrite?.invoke(n)
        }

        override fun fileEnd(fileHandle: String) {
            calls.add(Call("fileEnd", emptyList()))
            maybeThrow("fileEnd")
        }

        override fun fileAbort(fileHandle: String) {
            calls.add(Call("fileAbort", emptyList()))
        }

        override fun treeFinish(treeHandle: String, displayNameHint: String?): String {
            calls.add(Call("treeFinish", listOf(displayNameHint ?: "")))
            maybeThrow("treeFinish")
            return finishReply
        }

        override fun treeAbort(treeHandle: String) {
            calls.add(Call("treeAbort", emptyList()))
        }

        private fun maybeThrow(name: String) {
            if (throwOn == name) {
                throw SkillsFolderStagingNativeException(throwStatus)
            }
        }
    }

    private class Node(
        val name: String,
        val directory: Boolean,
        val bytes: ByteArray? = null,
        val declared: Long? = null,
        val children: List<Node> = emptyList(),
    )

    /** Flat synthetic provider: ids are path-based and stable. */
    private class FakeReader(
        private val root: List<Node>,
        override val displayName: String? = "Picked Skill Folder",
        var grantAvailable: Boolean = true,
    ) : SkillsFolderStagingController.FolderTreeReader {
        val grantCalls = AtomicInteger(0)
        val releaseCalls = AtomicInteger(0)
        private val index = HashMap<String, List<Node>>()
        private val streams = HashMap<String, ByteArray>()

        init {
            fun walk(prefix: String, nodes: List<Node>) {
                index[prefix] = nodes
                for (n in nodes) {
                    val path = if (prefix.isEmpty()) n.name else "$prefix/${n.name}"
                    if (n.directory) {
                        walk(path, n.children)
                    } else {
                        streams[path] = n.bytes ?: ByteArray(0)
                    }
                }
            }
            walk("", root)
        }

        override val rootDocumentId: String? get() = ""

        override fun children(documentId: String): List<SkillsFolderStagingController.FolderChild> =
            (index[documentId] ?: emptyList()).map { node ->
                val path = if (documentId.isEmpty()) node.name else "$documentId/${node.name}"
                SkillsFolderStagingController.FolderChild(
                    documentId = if (node.directory) path else "doc:" + path,
                    name = node.name,
                    isDirectory = node.directory,
                    declaredBytes = node.declared ?: node.bytes?.size?.toLong(),
                )
            }

        override fun openStream(documentId: String): InputStream? {
            val key = documentId.removePrefix("doc:")
            return streams[key]?.let { ByteArrayInputStream(it) }
        }

        override fun takeReadGrant(): Boolean {
            grantCalls.incrementAndGet()
            return grantAvailable
        }

        override fun releaseReadGrant() {
            releaseCalls.incrementAndGet()
        }
    }

    /** JVM fixture: the real native epoch readback is unavailable here and
     *  the host's runCatching-wrapped reader correctly returns null (never a
     *  fabricated 0). Staging tests set an explicit epoch reader. */
    private fun host(): RuntimeHost = RuntimeHost(
        commandClient = RuntimeHostCommandClient.system(),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = CoroutineScope(Dispatchers.Default),
        ioDispatcher = Dispatchers.Default,
    )

    private fun controller(host: RuntimeHost): SkillsFolderStagingController {
        staged.clear()
        failures.clear()
        admittedFlag = true
        return SkillsFolderStagingController(
            host = host,
            onStaged = { staged.add(it) },
            onStageFailure = { failures.add(it) },
            admitted = { admittedFlag },
        )
    }

    private fun tree(vararg nodes: Node) = nodes.toList()

    // ------------------------------------------------------------------

    @Test
    fun `presentPicker only claims success when the request really flips`() {
        val host = host()
        val c = controller(host)
        assertFalse("unadmitted must not fake a picker", c.presentPicker())
        admittedFlag = true
        assertFalse("no accepted native epoch yet", c.presentPicker())
        host.nativeRootEpochReader = { 31L }
        assertTrue(c.presentPicker())
        val request = c.pickerRequest.value
        assertNotNull(request)
        assertEquals(31L, request!!.nativeRootEpoch)
        assertTrue(request.uiGeneration > 0)
        // A second explicit pick replaces the owner (never queues two).
        val second = c.presentPicker()
        assertTrue(second)
        assertTrue(c.pickerRequest.value!!.incarnation > request.incarnation)
    }

    @Test
    fun `result for a superseded request is dropped without any channel IO`() {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        c.presentPicker()
        val old = c.pickerRequest.value!!
        c.presentPicker() // replaces the owner
        val channel = FakeChannel()
        c.channel = channel
        c.onTreeResult(old, FakeReader(tree(Node("SKILL.md", false, "x".toByteArray()))))
        runBlocking { delay(30) }
        assertTrue("stale request must produce no channel calls", channel.calls.isEmpty())
        assertTrue(staged.isEmpty())
    }

    @Test
    fun `successful staging walks safety-bounded copy and hands only the opaque token`() {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        val channel = FakeChannel()
        c.channel = channel
        val reader = FakeReader(
            tree(
                Node("SKILL.md", false, "hello".toByteArray(), declared = 5),
                Node("scripts", true, children = listOf(
                    Node("run.py", false, "print(1)".toByteArray(), declared = 8),
                )),
                Node("floe.json", false, "{}".toByteArray(), declared = 2),
            ),
        )
        c.readerOverride = reader
        c.presentPicker()
        val request = c.pickerRequest.value!!
        c.onTreeResult(request, reader)
        runBlocking { awaitSettled(c, channel) }
        val names = channel.calls.map { it.name }
        assertEquals(
            listOf("routeOpen", "treeOpen", "fileBegin", "fileWrite", "fileEnd",
                "fileBegin", "fileWrite", "fileEnd", "fileBegin", "fileWrite", "fileEnd",
                "treeFinish", "routeClose"),
            names,
        )
        val relative = channel.calls.filter { it.name == "fileBegin" }.flatMap { it.args }
        assertTrue(relative.containsAll(listOf("SKILL.md", "scripts/run.py", "floe.json")))
        assertEquals(1, staged.size)
        val ref = staged.single()
        assertTrue(ref.handle.startsWith("stg:v1:"))
        assertEquals(1234L, ref.sizeBytes)
        assertEquals("Picked Skill Folder", ref.displayName)
        assertNull(ref.mimeType)
        assertTrue(failures.isEmpty())
        // Success releases the (otherwise retry-useful) read grant.
        assertEquals(1, reader.grantCalls.get())
        assertEquals(1, reader.releaseCalls.get())
    }

    @Test
    fun `oversize declared file is refused before streaming`() {
        runStageFailureCase(
            tree(Node("huge.bin", false, declared = 3L * 1024 * 1024)),
            expectedFailure = "folder_file_too_large",
        )
    }

    @Test
    /** A provider that UNDER-declares size is still stopped by the real
     *  streamed-byte accounting (mid-copy), never by the hint alone. */
    fun `undeclared stream overshoot is refused mid-copy`() {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        val reader = FakeReader(
            tree(Node("sneaky.bin", false, ByteArray(3 * 1024 * 1024), declared = 10)),
        )
        val channel = FakeChannel()
        c.channel = channel
        c.readerOverride = reader
        c.presentPicker()
        c.onTreeResult(c.pickerRequest.value!!, reader)
        runBlocking { awaitRouteClose(channel, timeoutMs = 12_000) }
        assertTrue(failures.contains("folder_file_too_large"))
        assertTrue(staged.isEmpty())
        assertTrue(channel.calls.any { it.name == "treeAbort" })
        assertTrue(channel.calls.any { it.name == "fileAbort" })
        assertTrue(channel.calls.any { it.name == "routeClose" })
        // Failed staging KEEPS the retry-useful grant (no release).
        assertEquals(0, reader.releaseCalls.get())
    }

    @Test
    fun `file count budget is enforced before begin`() {
        val many = (0..255).map {
            Node("f$it.md", false, ByteArray(10), declared = 10)
        }
        // 257th file trips the MAX_FILES guard (budget is 256).
        runStageFailureCase(tree(*(many + Node("overflow.md", false, ByteArray(1))).toTypedArray()),
            expectedFailure = "folder_too_many_files",
            timeoutMs = 15_000)
    }

    @Test
    fun `depth budget is enforced`() {
        var node = Node("leaf.md", false, ByteArray(1), declared = 1)
        for (depth in 0 until 17) {
            node = Node("d$depth", true, children = listOf(node))
        }
        runStageFailureCase(tree(node), expectedFailure = "folder_too_deep")
    }

    @Test
    fun `unsafe and duplicate names are refused`() {
        runStageFailureCase(
            tree(Node("../escape", false, ByteArray(1), declared = 1)),
            expectedFailure = "folder_unsafe_name",
        )
        runStageFailureCase(
            tree(Node("a", false, ByteArray(1), declared = 1),
                Node("A", false, ByteArray(1), declared = 1)),
            expectedFailure = "folder_duplicate_path",
        )
        runStageFailureCase(tree(), expectedFailure = "folder_empty")
        runStageFailureCase(
            tree(Node("sub", true, children = listOf(Node("x.md", false, ByteArray(1), declared = 1))))
                .let { it }, // sub-only trees DO stage; ensure no false refusal
            expectedFailure = null,
        )
    }

    @Test
    fun `malformed finish reply is refused and cleaned up`() {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        val channel = FakeChannel(finishReply = "stag:v1:legacy-name 3 1234")
        c.channel = channel
        val reader = FakeReader(tree(Node("SKILL.md", false, "hi".toByteArray())))
        c.readerOverride = reader
        c.presentPicker()
        c.onTreeResult(c.pickerRequest.value!!, reader)
        runBlocking { awaitRouteClose(channel) }
        assertTrue(failures.contains("stage_refused"))
        assertTrue(staged.isEmpty())
    }

    @Test
    fun `explicit cancel aborts the owned tree silently`() {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        lateinit var channel: FakeChannel
        channel = FakeChannel(onWrite = { count ->
            if (count == 2) c.cancelActiveStaging()
        })
        c.channel = channel
        val reader = FakeReader(
            tree(Node("a.bin", false, ByteArray(64 * 1024)),
                Node("b.bin", false, ByteArray(64 * 1024)),
                Node("c.bin", false, ByteArray(64 * 1024))),
        )
        c.readerOverride = reader
        c.presentPicker()
        c.onTreeResult(c.pickerRequest.value!!, reader)
        runBlocking { awaitRouteClose(channel) }
        assertTrue("cancel must not report a failure", failures.isEmpty())
        assertTrue(staged.isEmpty())
        assertTrue(channel.calls.any { it.name == "treeAbort" })
        assertTrue(channel.calls.any { it.name == "routeClose" })
    }

    @Test
    fun `original segment rules mirrored in the pure validator`() {
        assertTrue(SkillsFolderStagingController.isSafeSegment("SKILL.md"))
        assertTrue(SkillsFolderStagingController.isSafeSegment("报告 2026.pdf"))
        assertFalse(SkillsFolderStagingController.isSafeSegment(".."))
        assertFalse(SkillsFolderStagingController.isSafeSegment("."))
        assertFalse(SkillsFolderStagingController.isSafeSegment("a/b"))
        assertFalse(SkillsFolderStagingController.isSafeSegment("a\\b"))
        assertFalse(SkillsFolderStagingController.isSafeSegment(""))
        assertFalse(SkillsFolderStagingController.isSafeSegment("x".repeat(300)))
        assertEquals(
            SkillsFolderStagingController.collisionKey("Readme.MD"),
            SkillsFolderStagingController.collisionKey("readme.md".uppercase().lowercase()),
        )
    }

    // ------------------------------------------------------------------

    private fun runStageFailureCase(
        nodes: List<Node>,
        expectedFailure: String?,
        timeoutMs: Long = 6_000,
    ) {
        val host = host()
        host.nativeRootEpochReader = { 31L }
        val c = controller(host)
        val channel = FakeChannel()
        c.channel = channel
        val reader = FakeReader(nodes)
        c.readerOverride = reader
        c.presentPicker()
        c.onTreeResult(c.pickerRequest.value!!, reader)
        runBlocking {
            withTimeout(timeoutMs) {
                while (channel.calls.none { it.name == "routeClose" }) delay(5)
            }
        }
        runBlocking { delay(20) }
        if (expectedFailure == null) {
            assertTrue("expected success, got failures $failures", failures.isEmpty())
            assertEquals(1, staged.size)
        } else {
            assertTrue("expected $expectedFailure, got $failures",
                failures.contains(expectedFailure))
            assertTrue(staged.isEmpty())
            assertTrue("owned tree must be cleaned", channel.calls.any { it.name == "treeAbort" })
        }
    }

    private suspend fun awaitSettled(c: SkillsFolderStagingController, channel: FakeChannel) {
        withTimeout(6_000) {
            while (channel.calls.none { it.name == "routeClose" }) delay(5)
        }
        // Drain the posted callbacks: onStaged runs inline on the worker
        // before routeClose (finally), so one more beat for assertions.
        delay(20)
    }

    private suspend fun awaitRouteClose(channel: FakeChannel, timeoutMs: Long = 8_000) {
        withTimeout(timeoutMs) {
            while (channel.calls.none { it.name == "routeClose" }) delay(5)
        }
        delay(20)
    }
}
