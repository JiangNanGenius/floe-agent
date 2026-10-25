// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.ui

import android.content.Context
import android.graphics.Typeface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeColors
import com.floe.android.feature.ide.IdePresenter
import com.floe.android.feature.ide.IdeSyncPlan
import com.floe.android.feature.ide.IdeViewState
import com.floe.android.feature.ide.api.IdeDiagnostic
import com.floe.android.feature.ide.api.IdeDiagnosticSeverity
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeTextSelection
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.internal.IdeTextMath
import com.floe.android.feature.ide.sora.FloeEditorRoles
import com.floe.android.feature.ide.sora.FloeKeywordLanguage
import com.floe.android.feature.ide.sora.FloeLanguageDefinition
import com.floe.android.feature.ide.sora.floeEditorScheme
import io.github.rosemoe.sora.event.ContentChangeEvent
import io.github.rosemoe.sora.event.ScrollEvent
import io.github.rosemoe.sora.event.SelectionChangeEvent
import io.github.rosemoe.sora.lang.EmptyLanguage
import io.github.rosemoe.sora.lang.diagnostic.DiagnosticDetail
import io.github.rosemoe.sora.lang.diagnostic.DiagnosticRegion
import io.github.rosemoe.sora.lang.diagnostic.DiagnosticsContainer
import io.github.rosemoe.sora.widget.CodeEditor
import io.github.rosemoe.sora.widget.component.EditorAutoCompletion

/** Editor surface tints derived from the shared Floe palette (no new truth). */
internal fun FloeColors.windowEditorBackground(): Int = readingSurface.toArgb()
internal fun FloeColors.chromeEditorGutter(): Int = chromeSurface.toArgb()
internal fun FloeColors.editorSelection(): Int = accent.copy(alpha = 0.24f).toArgb()
internal fun FloeColors.editorCurrentLine(): Int = accent.copy(alpha = 0.06f).toArgb()

/**
 * The real Sora [CodeEditor] embedded by Compose. This file owns editor
 * mechanics only: input/highlighting/selection/IME plumbing, minimal
 * projection sync (never a full reset per recomposition), composition-window
 * capture so CJK marked text commits as ONE versioned transaction, native
 * diagnostics feeding and [CodeEditor.release] on disposal. All document
 * truth stays behind [IdePresenter]/[com.floe.android.feature.ide.api.IdeHost].
 */
@Composable
internal fun SoraEditorView(
    presenter: IdePresenter,
    state: IdeViewState,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val roles = remember(colors.label, colors.accent, colors.isDark) {
        FloeEditorRoles(
            windowBackground = colors.windowEditorBackground(),
            textNormal = colors.label.toArgb(),
            secondaryLabel = colors.secondaryLabel.toArgb(),
            lineNumber = colors.secondaryLabel.toArgb(),
            lineNumberBackground = colors.chromeEditorGutter(),
            accent = colors.accent.toArgb(),
            selectionBackground = colors.editorSelection(),
            currentLine = colors.editorCurrentLine(),
            separator = colors.separator.toArgb(),
            success = colors.success.toArgb(),
            destructive = colors.destructive.toArgb(),
            pending = colors.pending.toArgb(),
        )
    }
    val holder = remember(presenter) { SoraEditorHolder(presenter) }

    AndroidView(
        factory = { ctx ->
            holder.build(ctx, roles)
        },
        update = { editor ->
            if (holder.editor === editor) {
                holder.configure(editor, state)
                holder.refreshScheme(editor, roles)
            }
        },
        onRelease = { editor ->
            if (holder.editor === editor) holder.teardown(editor)
        },
        modifier = modifier,
    )

    // Minimal projection sync at authority changes only (NOT per recomposition).
    val docId = state.activeDocumentKey?.documentId
    LaunchedEffect(
        docId,
        state.editorResetVersion,
        state.snapshot?.revision,
        state.snapshot?.generation,
        state.attached,
    ) {
        holder.editor?.let { editor -> holder.runSyncPlan(editor, state) }
    }

    // Find-jump selection requests.
    LaunchedEffect(state.editorSelectionRequestVersion) {
        val range = state.editorSelectionRequest ?: return@LaunchedEffect
        holder.editor?.let { holder.applyUtf16Selection(it, range) }
    }

    // Native diagnostics feeding (squiggles + tooltip window).
    LaunchedEffect(state.diagnosticsVersion, docId) {
        holder.editor?.let { holder.applyDiagnostics(it, state.diagnostics) }
    }

    // Host (LSP) completion items can land AFTER Sora's own insert-triggered
    // pass already ran (the native round trip is asynchronous; Sora only
    // pulls on content/selection events). Re-run the editor completion pass
    // when fresh items arrive so the async answer becomes visible.
    LaunchedEffect(state.completionVersion, docId) {
        if (state.completionVersion > 0 && state.snapshot?.capabilities?.completion == true) {
            holder.editor?.let { it.getComponent(EditorAutoCompletion::class.java).requireCompletion() }
        }
    }
}

/** Bridges Sora events into the presenter; owns no document truth. */
private class SoraEditorHolder(private val presenter: IdePresenter) {

    var editor: CodeEditor? = null
        private set

    private var programmaticDepth = 0
    private var compositionAnchor: String? = null
    private var loadedDocumentId: String? = null
    private var language: FloeKeywordLanguage? = null
    private var languageNeedsInstall = false
    private var schemeSignature: Int? = null

    fun build(ctx: Context, roles: FloeEditorRoles): CodeEditor {
        val view = CodeEditor(ctx)
        editor = view
        schemeSignature = roles.hashCode()
        view.setTypefaceText(Typeface.MONOSPACE)
        view.setTypefaceLineNumber(Typeface.MONOSPACE)
        view.setTextSize(14f)
        view.setWordwrap(false)
        view.setHighlightCurrentLine(true)
        view.setHighlightBracketPair(true)
        view.setTabWidth(4)
        // Swift undo/drafts are the only undo truth: never let Sora diverge.
        view.setUndoEnabled(false)
        view.setColorScheme(floeEditorScheme(roles))
        // Bounded completion surface (device evidence 2026-10-25, PID 16724
        // ANR): DefaultCompletionLayout scrolls its list with an UNBOUNDED
        // synthetic-touch loop that never converges once the popup viewport
        // collapses to a sub-row strip (compressed editor + IME), and Sora's
        // below-caret placement clipped the candidate under the IME. The
        // replacement flips the popup above the caret when — and only when —
        // the below strip is sub-usable, and places the list in ONE bounded
        // step. Completion stays fully enabled; edit/undo/CAS authority is
        // untouched. replaceComponent disables the old component's event
        // subscriptions (supported 0.24.4 route).
        view.replaceComponent(
            EditorAutoCompletion::class.java,
            com.floe.android.feature.ide.sora.FloeAutoCompletion(view),
        )
        view.contentDescription = "Floe IDE editor"
        return view
    }

    fun refreshScheme(view: CodeEditor, roles: FloeEditorRoles) {
        val signature = roles.hashCode()
        if (schemeSignature == signature) return
        schemeSignature = signature
        view.setColorScheme(floeEditorScheme(roles))
    }

    fun teardown(view: CodeEditor) {
        language?.destroy()
        language = null
        editor = null
        compositionAnchor = null
        // Real Sora release stops background threads and renderer resources.
        view.release()
    }

    init {
        // Subscriptions are attached lazily after the factory runs because
        // subscribeEvent requires the concrete editor instance.
    }

    fun configure(view: CodeEditor, state: IdeViewState) {
        if (view.tag == null) {
            view.tag = true
            subscribe(view)
        }
        val snapshot = state.snapshot
        val editable = state.activeDocumentKey != null && snapshot != null &&
            !snapshot.readOnly && state.inputAdmissionOpen && state.mirrorText != null
        view.setEditable(editable)
        val newDoc = state.activeDocumentKey?.documentId
        if (newDoc != loadedDocumentId) {
            val previous = loadedDocumentId
            loadedDocumentId = newDoc
            detachLanguageForFullSync(view)
            if (previous != null && newDoc != null) {
                // Tab switch: an in-flight composition cannot cross documents.
                finishComposition(abortTransaction = true)
            }
        }
    }

    private fun subscribe(view: CodeEditor) {
        view.subscribeEvent(ContentChangeEvent::class.java) { event, _ -> onContentChange(view, event) }
        view.subscribeEvent(SelectionChangeEvent::class.java) { _, _ -> reportSelection(view) }
        view.subscribeEvent(ScrollEvent::class.java) { _, _ -> reportSelection(view) }
    }

    /** A Sora 0.24.4 analyzer must never start against the old Content before
     * setText replaces it. Its async worker reads ContentReference and then
     * request ID separately, so an empty old Content can be paired with the
     * new request and publish one-line spans for a restored multiline file.
     * Retire that manager, replace Content, then attach a fresh manager. */
    private fun detachLanguageForFullSync(view: CodeEditor) {
        language?.destroy()
        language = null
        view.setEditorLanguage(EmptyLanguage())
        languageNeedsInstall = true
    }

    private fun applyLanguage(
        view: CodeEditor,
        docKey: IdeDocumentKey?,
        snapshot: IdeDocumentSnapshot?,
    ) {
        language?.destroy()
        language = null
        if (docKey == null) {
            view.setEditorLanguage(EmptyLanguage())
            return
        }
        val definition = snapshot?.languageId?.let { FloeLanguageDefinition.forLanguageId(it) }
            ?: FloeLanguageDefinition.forPath(snapshot?.relativePath ?: docKey.documentId)
        val lang = FloeKeywordLanguage(definition) { caret, _ ->
            val revision = presenter.snapshotFor(docKey.documentId)?.revision
            if (revision == null) {
                emptyList()
            } else {
                presenter.hostCompletionItems(docKey.documentId, revision, caret)
                    .map { it.label to it.insertText }
            }
        }
        language = lang
        view.setEditorLanguage(lang)
    }

    fun runSyncPlan(view: CodeEditor, state: IdeViewState) {
        val docId = state.activeDocumentKey?.documentId ?: return
        val composing = view.hasComposingText()
        val current = view.getText().toString()
        when (val plan = presenter.syncPlanFor(docId, current, composing)) {
            IdeSyncPlan.Keep -> Unit
            is IdeSyncPlan.ReplaceFull -> {
                detachLanguageForFullSync(view)
                programmatic { view.setText(plan.text) }
                restoreCaret(view, state)
            }
            is IdeSyncPlan.ReplaceRange -> {
                programmatic { view.getText().replace(plan.startUtf16, plan.endUtf16, plan.replacement) }
            }
        }
        if (languageNeedsInstall && state.snapshot != null) {
            applyLanguage(view, state.activeDocumentKey, state.snapshot)
            languageNeedsInstall = false
        }
    }

    private fun restoreCaret(view: CodeEditor, state: IdeViewState) {
        // Live presenter truth, never the captured state's snapshot echo:
        // the native selection echo can lag behind the renderer's own last
        // report, and re-asserting a stale range here re-selects text the
        // next keystroke would silently replace (and resurfaces as a stale
        // "N selected" header after every view reconstruction). The
        // presenter orders local reports against caret-authoritative native
        // adoptions and clamps the result to the current projection.
        val docId = state.activeDocumentKey?.documentId ?: return
        val selection = presenter.restoreSelectionFor(docId) ?: return
        applyUtf16Selection(view, IdeUtf16Range(selection.startUtf16, selection.endUtf16))
    }

    private inline fun programmatic(block: () -> Unit) {
        programmaticDepth += 1
        try {
            block()
        } finally {
            programmaticDepth -= 1
        }
    }

    private fun onContentChange(view: CodeEditor, event: ContentChangeEvent) {
        if (programmaticDepth > 0) return
        if (event.isCausedByUndoManager) return
        val docKey = presenter.activeDocumentKey() ?: return
        if (view.hasComposingText()) {
            // Enter/keep the composition window: absorb intermediates so IME
            // marked text never leaks as multiple transactions.
            if (compositionAnchor == null) {
                compositionAnchor = reconstructBeforeEvent(view, event)
                presenter.setComposing(docKey.documentId, true)
            }
            return
        }
        val anchor = compositionAnchor
        if (anchor != null) {
            // Composition window closed: commit ONE merged transaction.
            val finalText = view.getText().toString()
            val op = IdeTextMath.minimalReplacement(anchor, finalText)
            finishComposition(abortTransaction = false)
            if (op != null) {
                presenter.applyProjectionEdit(
                    docKey,
                    IdeUtf16Range(op.startUtf16, op.endUtf16),
                    op.replacement,
                    IdeEditOrigin.USER_IME_COMMIT,
                )
            }
            reportSelection(view)
            return
        }
        when (event.action) {
            ContentChangeEvent.ACTION_INSERT -> {
                val start = event.changeStart.index.coerceIn(0, view.getText().length)
                presenter.applyProjectionEdit(
                    docKey,
                    IdeUtf16Range(start, start),
                    event.changedText.toString(),
                    IdeEditOrigin.USER_TYPING,
                )
            }
            ContentChangeEvent.ACTION_DELETE -> {
                val deleted = event.changedText.toString()
                val beforeLength = presenter.mirrorLengthFor(docKey.documentId) ?: return
                val range = IdeTextMath.deletionRange(beforeLength,
                    event.changeStart.index, deleted.length) ?: return
                presenter.applyProjectionEdit(
                    docKey,
                    range,
                    "",
                    IdeEditOrigin.USER_DELETE,
                )
            }
            ContentChangeEvent.ACTION_SET_NEW_TEXT -> {
                // User-triggered full replace (rare). One transaction replaces
                // the presenter mirror against its current length.
                val oldLen = presenter.mirrorLengthFor(docKey.documentId) ?: return
                val text = event.changedText.toString()
                presenter.applyProjectionEdit(
                    docKey,
                    IdeUtf16Range(0, oldLen),
                    text,
                    IdeEditOrigin.USER_PASTE,
                )
            }
        }
        reportSelection(view)
    }

    private fun reconstructBeforeEvent(view: CodeEditor, event: ContentChangeEvent): String {
        val current = view.getText().toString()
        val changed = event.changedText.toString()
        val start = event.changeStart.index.coerceIn(0, current.length)
        return when (event.action) {
            ContentChangeEvent.ACTION_INSERT -> {
                val end = (start + changed.length).coerceIn(start, current.length)
                current.substring(0, start) + current.substring(end)
            }
            ContentChangeEvent.ACTION_DELETE -> {
                current.substring(0, start) + changed + current.substring(start)
            }
            else -> current
        }
    }

    private fun finishComposition(abortTransaction: Boolean) {
        compositionAnchor = null
        presenter.activeDocumentKey()?.let { key ->
            presenter.setComposing(key.documentId, false)
        }
        if (abortTransaction) {
            // No transaction is emitted: the sync plan will re-align the editor.
        }
    }

    private fun reportSelection(view: CodeEditor) {
        val docId = presenter.activeDocumentKey()?.documentId ?: return
        val range = view.getCursorRange() ?: return
        presenter.reportEditorSelection(
            docId,
            IdeTextSelection(range.startIndex, range.endIndex),
            view.getFirstVisibleLine(),
        )
    }

    fun applyUtf16Selection(view: CodeEditor, range: IdeUtf16Range) {
        val content = view.getText()
        val length = content.length
        val start = range.startUtf16.coerceIn(0, length)
        val end = range.endUtf16.coerceIn(start, length)
        val s = content.getIndexer().getCharPosition(start)
        val e = content.getIndexer().getCharPosition(end)
        view.setSelectionRegion(s.line, s.column, e.line, e.column, true)
        view.ensureSelectionVisible()
    }

    fun applyDiagnostics(view: CodeEditor, items: List<IdeDiagnostic>) {
        if (items.isEmpty()) {
            view.setDiagnostics(null)
            return
        }
        val container = DiagnosticsContainer(true)
        val length = view.getText().length
        val regions = items.mapNotNull { d ->
            val start = d.range.startUtf16.coerceIn(0, length)
            val end = d.range.endUtf16.coerceIn(start, length)
            if (end <= start) return@mapNotNull null
            val severity = when (d.severity) {
                IdeDiagnosticSeverity.ERROR -> DiagnosticRegion.SEVERITY_ERROR
                IdeDiagnosticSeverity.WARNING -> DiagnosticRegion.SEVERITY_WARNING
                IdeDiagnosticSeverity.INFO -> DiagnosticRegion.SEVERITY_TYPO
                IdeDiagnosticSeverity.HINT -> DiagnosticRegion.SEVERITY_NONE
            }
            DiagnosticRegion(start, end, severity, d.id, DiagnosticDetail(d.message, d.detail))
        }
        container.addDiagnostics(regions)
        view.setDiagnostics(container)
    }
}
