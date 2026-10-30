// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeCommandPayload
import com.floe.android.feature.ide.api.IdeCommandReply
import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeDocumentCapabilities
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeOwnerScope
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeReplyOutcome
import com.floe.android.feature.ide.api.IdeTabDescriptor
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeTreeChildrenEvent
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Files re-entry refresh contract (G07.2):
 *  - re-entry reads the visible tree only after the retained presenter has a
 *    settled root, so first composition does not duplicate the initial read;
 *  - repeated re-entry signals while that read is in flight coalesce;
 *  - expanded folders are re-read, collapsed ones are not;
 *  - an open document's mirror/draft/undo lineage is untouched by a tree
 *    refresh;
 *  - late tree answers from a retired binding owner (task/workspace/root
 *    epoch generation) never overwrite the current listing.
 *
 * AUTHORED SOURCE ONLY: Main owns compilation/execution in the unified batch.
 */
class IdeTreeReentryRefreshTest {

    private val owner get() = IdeOwnerScope("task", "ws", 7L)
    private val key get() = IdeDocumentKey("task", "ws", "doc-1")

    private inner class FakeHost(
        override var bindingGeneration: Long = 7L,
        override val taskId: String = "task",
        override val workspaceId: String = "ws",
    ) : IdeHost {
        var receiver: IdeReceiver? = null
        val commands = ArrayList<IdeCommandRequest>()
        val edits = ArrayList<IdeEditTransaction>()
        override fun attach(receiver: IdeReceiver): () -> Unit {
            this.receiver = receiver
            return { this.receiver = null }
        }
        override fun submitEdit(transaction: IdeEditTransaction) { edits += transaction }
        override fun sendCommand(command: IdeCommandRequest) { commands += command }
    }

    private inner class Fixture {
        val host = FakeHost()
        val presenter = IdePresenter(host)
        init { presenter.start() }
        val trees get() = host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>()
    }

    private fun file(name: String, directory: Boolean = false) =
        IdeFileRow(relativePath = name, name = name, isDirectory = directory)

    private fun treeReply(
        request: IdeCommandRequest.ExpandTree,
        replyOwner: IdeOwnerScope = owner,
        parent: String? = request.parentRelativePath,
        children: List<IdeFileRow>,
        generation: Long = request.requestGeneration,
    ): IdeCommandReply = IdeCommandReply(
        request.requestId, replyOwner, null,
        IdeReplyOutcome.Executed(
            IdeCommandPayload(
                kind = IdeCommandPayload.Kind.TREE_CHILDREN,
                treeChildren = IdeTreeChildrenEvent(replyOwner, parent, generation, children),
            ),
        ),
    )

    private fun settleInitialRoot(f: Fixture, children: List<IdeFileRow> = listOf(file("a.kt"))) {
        val start = f.trees.single()
        f.host.receiver!!.onCommandReply(treeReply(start, children = children))
        assertEquals(children.map { it.name }, f.presenter.state.value.tree.rows.map { it.file.name })
    }

    @Test
    fun reentrySkipsInitialLoadAndCoalescesUntilRootSettles() {
        val f = Fixture()
        assertFalse("first composition already has a root read in flight", f.presenter.refreshTreeForReentry())
        assertEquals(1, f.trees.size)

        settleInitialRoot(f)
        assertTrue(f.presenter.refreshTreeForReentry())
        val reentry = f.trees.last()
        assertEquals(owner, reentry.owner)
        assertEquals(2, f.trees.size)

        assertFalse("a second re-entry while the root is loading must coalesce", f.presenter.refreshTreeForReentry())
        assertEquals(2, f.trees.size)

        f.host.receiver!!.onCommandReply(treeReply(reentry, children = listOf(file("a.kt"), file("b.kt"))))
        assertEquals(listOf("a.kt", "b.kt"), f.presenter.state.value.tree.rows.map { it.file.name })
        assertTrue("a later real re-entry is allowed after the answer settles", f.presenter.refreshTreeForReentry())
        assertEquals(3, f.trees.size)
    }

    @Test
    fun reentryRetriesASettledRootErrorWithoutWedgingTheAutomaticPath() {
        val f = Fixture()
        val start = f.trees.single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(
                start.requestId, owner, null,
                IdeReplyOutcome.Executed(
                    IdeCommandPayload(
                        kind = IdeCommandPayload.Kind.TREE_CHILDREN,
                        treeChildren = IdeTreeChildrenEvent(
                            owner, null, start.requestGeneration, emptyList(), error = "io",
                        ),
                    ),
                ),
            ),
        )
        assertEquals("io", f.presenter.state.value.tree.rootError)
        assertTrue(f.presenter.refreshTreeForReentry())
        assertEquals(2, f.trees.size)
    }

    @Test
    fun reentryReReadsExpandedFoldersAndPreservesOpenDraft() {
        val f = Fixture()
        settleInitialRoot(f, listOf(file("a.kt"), file("src", directory = true)))
        f.presenter.toggleTreeExpansion("src")
        val expand = f.trees.last()
        assertEquals("src", expand.parentRelativePath)
        f.host.receiver!!.onCommandReply(treeReply(expand, children = listOf(file("src/one.kt"))))
        assertEquals(
            listOf("a.kt", "src", "src/one.kt"),
            f.presenter.state.value.tree.rows.map { it.file.relativePath },
        )

        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(IdeTabDescriptor("doc-1", "a.kt", "a.kt")), 1))
        f.host.receiver!!.onDocumentSnapshot(
            IdeDocumentSnapshot(
                key = key,
                revision = NativeRevision("r0"),
                generation = 0,
                text = "abc",
                fileName = "a.kt",
                relativePath = "a.kt",
                capabilities = IdeDocumentCapabilities(undo = true, redo = true, save = true),
            ),
        )
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        assertEquals("abc!", f.presenter.state.value.mirrorText)
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        val activeBefore = f.presenter.state.value.activeDocumentKey

        val beforeRefresh = f.trees.size
        assertTrue(f.presenter.refreshTreeForReentry())
        val dispatched = f.trees.drop(beforeRefresh)
        assertEquals(listOf<String?>(null, "src"), dispatched.map { it.parentRelativePath })
        assertEquals("tree refresh never reloads the open document", "abc!", f.presenter.state.value.mirrorText)
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        assertEquals(activeBefore, f.presenter.state.value.activeDocumentKey)
    }

    @Test
    fun lateTreeFromRetiredOwnerAndOlderRootGenerationNeverOverwrite() {
        val f = Fixture()
        val start = f.trees.single()
        f.host.receiver!!.onCommandReply(treeReply(start, children = listOf(file("current.kt"))))
        val currentRows = f.presenter.state.value.tree.rows.map { it.file.name }

        // A late answer from a retired epoch/binding generation: [accept]
        // fences it before the generation check can apply it.
        f.host.receiver!!.onCommandReply(
            treeReply(start, replyOwner = owner.copy(bindingGeneration = 8L), children = listOf(file("stale.kt"))),
        )
        assertEquals(currentRows, f.presenter.state.value.tree.rows.map { it.file.name })

        // A same-owner but older root generation must not rewind the listing.
        f.host.receiver!!.onCommandReply(
            treeReply(start, children = listOf(file("older.kt")), generation = start.requestGeneration - 1),
        )
        assertEquals(currentRows, f.presenter.state.value.tree.rows.map { it.file.name })

        // A genuinely newer current-owner answer still applies.
        f.host.receiver!!.onCommandReply(
            treeReply(start, children = listOf(file("newer.kt")), generation = start.requestGeneration + 1),
        )
        assertEquals(listOf("newer.kt"), f.presenter.state.value.tree.rows.map { it.file.name })
    }
}
