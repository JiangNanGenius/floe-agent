// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY synthetic IDE preview (debug variant source set only).
//
// NEVER compiled into a release build, never reachable from production
// navigation. The [SyntheticIdeHost] below fabricates a small workspace so
// Main's qualification stage can inspect composition (tree, tabs, editor,
// find bar, diff, conflict) BEFORE the Swift bridge is wired. Everything it
// shows is synthetic — it is not evidence of a working backend, and the real
// entry point remains [com.floe.android.feature.ide.FloeIdeWorkspace] with a
// production [com.floe.android.feature.ide.api.IdeHost].

package com.floe.android.feature.ide.debug

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.Composable
import com.floe.android.feature.ide.FloeIdeWorkspace
import com.floe.android.feature.ide.api.IdeCommandPayload
import com.floe.android.feature.ide.api.IdeCommandReply
import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeReplyOutcome
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeTreeChildrenEvent
import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.api.NativeRevision
import com.floe.android.feature.ide.rememberIdePresenter
import java.util.concurrent.atomic.AtomicLong

/** Synthetic host: echoes edits into an in-RAM string, zero disk/network. */
private class SyntheticIdeHost : IdeHost {
    override val taskId = "debug-task"
    override val workspaceId = "debug-workspace"
    override val bindingGeneration = 1L

    private val main = Handler(Looper.getMainLooper())
    private val rev = AtomicLong(0)
    private var receiver: IdeReceiver? = null
    private val body = StringBuilder("fun main() {\n    println(\"hello floe\")\n}\n")

    override fun attach(receiver: IdeReceiver): () -> Unit {
        this.receiver = receiver
        main.post { pushWarmup() }
        return { this.receiver = null }
    }

    private fun pushWarmup() {
        pushTreeRoot()
        receiver?.onTabs(
            IdeTabsSnapshot(
                owner = com.floe.android.feature.ide.api.IdeOwnerScope(taskId, workspaceId, bindingGeneration),
                activeDocumentId = "main.kt",
                tabs = listOf(com.floe.android.feature.ide.api.IdeTabDescriptor("main.kt", "main.kt", "main.kt", "kotlin")),
                generation = 1,
            ),
        )
        receiver?.onDocumentSnapshot(snapshot())
    }

    private fun pushTreeRoot() {
        val owner = com.floe.android.feature.ide.api.IdeOwnerScope(taskId, workspaceId, bindingGeneration)
        receiver?.onCommandReply(
            IdeCommandReply(
                requestId = "synthetic-tree-root",
                owner = owner,
                documentKey = null,
                outcome = IdeReplyOutcome.Executed(
                    IdeCommandPayload(
                        kind = IdeCommandPayload.Kind.TREE_CHILDREN,
                        treeChildren = IdeTreeChildrenEvent(
                            owner = owner,
                            parentRelativePath = null,
                            requestGeneration = 1,
                            children = listOf(IdeFileRow("main.kt", "main.kt", false, 32L)),
                        ),
                    ),
                ),
            ),
        )
    }

    private fun snapshot() = IdeDocumentSnapshot(
        key = IdeDocumentKey(taskId, workspaceId, "main.kt"),
        revision = NativeRevision("synthetic-${rev.get()}"),
        generation = rev.get(),
        text = body.toString(),
        fileName = "main.kt",
        relativePath = "main.kt",
        languageId = "kotlin",
        readOnly = false,
        capabilities = com.floe.android.feature.ide.api.IdeDocumentCapabilities(
            undo = false,
            redo = false,
            save = true,
            find = true,
            replace = true,
            diff = false,
            run = false,
            openPreview = false,
            terminal = false,
            completion = false,
        ),
    )

    override fun submitEdit(transaction: IdeEditTransaction) {
        val s = transaction.range.startUtf16.coerceIn(0, body.length)
        val e = transaction.range.endUtf16.coerceIn(s, body.length)
        body.replace(s, e, transaction.replacement)
        rev.incrementAndGet()
        main.post {
            receiver?.onCommandReply(
                IdeCommandReply(
                    requestId = transaction.transactionId,
                    owner = com.floe.android.feature.ide.api.IdeOwnerScope(taskId, workspaceId, bindingGeneration),
                    documentKey = transaction.documentKey,
                    outcome = IdeReplyOutcome.Acknowledged(snapshot().revision),
                ),
            )
        }
    }

    override fun sendCommand(command: IdeCommandRequest) {
        // Synthetic host answers the few commands the preview exercises.
    }
}

/**
 * DEBUG-ONLY composition surface with a SYNTHETIC banner host. This is a UI
 * inspection aid, not real workspace content, and must never be presented as
 * actual App evidence.
 */
@Composable
public fun FloeIdeDebugPreview(
    onBack: () -> Unit = {},
) {
    val host = androidx.compose.runtime.remember { SyntheticIdeHost() }
    val presenter = rememberIdePresenter(host)
    FloeIdeWorkspace(presenter = presenter, onBack = onBack)
}
