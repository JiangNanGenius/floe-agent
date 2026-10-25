// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.sora

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicLong
import io.github.rosemoe.sora.lang.Language
import io.github.rosemoe.sora.lang.analysis.AnalyzeManager
import io.github.rosemoe.sora.lang.analysis.SimpleAnalyzeManager
import io.github.rosemoe.sora.lang.analysis.StyleReceiver
import io.github.rosemoe.sora.lang.analysis.StyleUpdateRange
import io.github.rosemoe.sora.lang.completion.CompletionCancelledException
import io.github.rosemoe.sora.lang.completion.CompletionHelper
import io.github.rosemoe.sora.lang.completion.IdentifierAutoComplete
import io.github.rosemoe.sora.lang.completion.SimpleCompletionItem
import io.github.rosemoe.sora.lang.format.Formatter
import io.github.rosemoe.sora.lang.smartEnter.NewlineHandler
import io.github.rosemoe.sora.lang.styling.MappedSpans
import io.github.rosemoe.sora.lang.styling.Styles
import io.github.rosemoe.sora.text.CharPosition
import io.github.rosemoe.sora.text.Content
import io.github.rosemoe.sora.text.ContentReference
import io.github.rosemoe.sora.text.TextRange
import io.github.rosemoe.sora.widget.SymbolPairMatch
import io.github.rosemoe.sora.widget.schemes.EditorColorScheme

/**
 * Real Sora-native keyword highlighting + identifier auto-completion for the
 * common workspace languages. This is presentation-grade analysis running on
 * Sora's own analyze thread (no extra dependencies, no desugaring); a later
 * language-textmate / LSP package attaches through the module's host-completion
 * and diagnostics seams and can replace this instance per document.
 *
 * Colors are Sora [EditorColorScheme] slot IDs; the Floe scheme mapping lives
 * in [FloeIdeColorScheme].
 */
public class FloeKeywordLanguage(
    private val definition: FloeLanguageDefinition,
    private val hostCompletion: (caretUtf16: Int, revision: String?) -> List<Pair<String, String>>,
) : Language {

    private val analyzeManager = FloeAnalyzeManager(definition)
    private val autoComplete = IdentifierAutoComplete(definition.keywords.toTypedArray())

    override fun getAnalyzeManager(): AnalyzeManager = analyzeManager

    override fun getInterruptionLevel(): Int = Language.INTERRUPTION_LEVEL_STRONG

    @Throws(CompletionCancelledException::class)
    override fun requireAutoComplete(
        content: ContentReference,
        position: CharPosition,
        publisher: io.github.rosemoe.sora.lang.completion.CompletionPublisher,
        extraArguments: Bundle,
    ) {
        val prefix = CompletionHelper.computePrefix(content, position) { ch ->
            ch.isLetterOrDigit() || ch == '_' || ch == '$'
        }
        if (prefix.isNotEmpty()) {
            autoComplete.requireAutoComplete(content, position, prefix, publisher, null)
        }
        // Host-provided native items (LSP after-bind or Swift policy) merge in.
        val hostItems = hostCompletion(position.index, null)
        if (hostItems.isNotEmpty()) {
            val items = hostItems.map { (label, insert) ->
                SimpleCompletionItem(label, prefix.length, insert)
            }
            publisher.addItems(items)
        }
    }

    override fun getIndentAdvance(content: ContentReference, line: Int, column: Int): Int = 0

    override fun useTab(): Boolean = false

    override fun getFormatter(): Formatter = NoopFormatter

    override fun getSymbolPairs(): SymbolPairMatch = SymbolPairMatch()

    override fun getNewlineHandlers(): Array<NewlineHandler> = EMPTY_NEWLINE_HANDLERS

    override fun destroy() {
        analyzeManager.destroy()
    }

    private companion object {
        val EMPTY_NEWLINE_HANDLERS = emptyArray<NewlineHandler>()
    }
}

internal object NoopFormatter : Formatter {
    override fun format(text: Content, cursorRange: TextRange) = Unit
    override fun formatRegion(text: Content, rangeToFormat: TextRange, cursorRange: TextRange) = Unit
    override fun setReceiver(receiver: Formatter.FormatResultReceiver?) = Unit
    override fun isRunning(): Boolean = false
    override fun destroy() = Unit
}

/**
 * Line scanner feeding Sora's [MappedSpans] builder. Tokenizes one logical
 * line at a time with carried state (block comments, string quotes), so
 * highlighting survives multi-line constructs without extra dependencies.
 *
 * CRITICAL lifecycle contract (device crash 2026-10-25, FATAL
 * IndexOutOfBoundsException Index 1 / length 1 at
 * MappedSpans$MappedSpansAccessor.getSpansOnLine): the renderer indexes the
 * published spans PER CONTENT LINE with no bounds clamp, so the returned
 * Styles MUST cover every line of the analyzed text. Two rules guarantee it:
 *  1. lines are split exactly like Sora's LineSeparator (CR, LF or CRLF as
 *     one break) — counting only LF under-covered lone-CR content;
 *  2. Builder.determine() takes the LAST LINE INDEX of the whole text. The
 *     previous code passed `lineIndex - 1` even after breaking on the final
 *     line, and addIfNeeded de-duplicates a trailing empty line's normal
 *     span away, so any text ending with a newline published one line fewer
 *     than the content had — pressing Enter at end-of-document therefore
 *     crashed the next draw. determine() extends every missing line with the
 *     carried normal style, so it is called with the true separator count.
 */
internal class FloeAnalyzeManager(
    private val definition: FloeLanguageDefinition,
) : SimpleAnalyzeManager<Unit>() {

    private val receiverEpoch = AtomicLong()
    private val uiHandler by lazy { Handler(Looper.getMainLooper()) }

    override fun setReceiver(receiver: StyleReceiver?) {
        val epoch = receiverEpoch.incrementAndGet()
        super.setReceiver(receiver?.let { target ->
            object : StyleReceiver by target {
                // Sora checks manager identity BEFORE posting its UI callback.
                // Fence on the UI thread as well so an old queued style cannot
                // be applied after this manager's Content/owner was retired.
                override fun setStyles(source: AnalyzeManager, styles: Styles?) {
                    deliverStyles(epoch) { target.setStyles(source, styles) }
                }
                override fun setStyles(source: AnalyzeManager, styles: Styles?, onComplete: Runnable?) {
                    deliverStyles(epoch) { target.setStyles(source, styles, onComplete) }
                }
                override fun updateStyles(source: AnalyzeManager, styles: Styles, range: StyleUpdateRange) {
                    deliverStyles(epoch) { target.updateStyles(source, styles, range) }
                }
            }
        })
    }

    private fun deliverStyles(epoch: Long, apply: () -> Unit) {
        uiHandler.post {
            if (receiverEpoch.get() == epoch) apply()
        }
    }

    override fun destroy() {
        receiverEpoch.incrementAndGet()
        super.destroy()
    }

    override fun analyze(text: StringBuilder, delegate: Delegate<Unit>): Styles {
        val builder = MappedSpans.Builder()
        // Sora joins the analyzed container with the content's OWN per-line
        // separators; the final index equals the separator count. Computed
        // up front so even a cancelled partial scan still determines the
        // full coverage (a cancelled result is re-run by SimpleAnalyzeManager
        // before publishing, but the geometry must never be short).
        val lastLineIndex = countLineSeparators(text)
        var state = FloeLanguageTokenizer.FloeLineState()
        var lineIndex = 0
        var lineStart = 0
        while (lineStart <= text.length) {
            if (delegate.isCancelled()) break
            var end = lineStart
            while (end < text.length && text[end] != '\n' && text[end] != '\r') end++
            val spans = FloeLanguageTokenizer.spansFor(
                text = text.subSequence(lineStart, end),
                definition = definition,
                state = state,
            )
            state = spans.second
            for ((column, styleId) in spans.first) {
                if (delegate.isCancelled()) break
                builder.addIfNeeded(lineIndex, column, styleId)
            }
            if (end >= text.length) break
            // Consume the one separator (CR, LF or CRLF) that ends this line.
            lineStart = if (text[end] == '\r' && end + 1 < text.length && text[end + 1] == '\n') {
                end + 2
            } else {
                end + 1
            }
            lineIndex++
        }
        builder.determine(lastLineIndex)
        builder.addNormalIfNull()
        return Styles(builder.build())
    }

    private fun countLineSeparators(text: CharSequence): Int {
        var count = 0
        var i = 0
        while (i < text.length) {
            when (text[i]) {
                '\r' -> {
                    count++
                    i += if (i + 1 < text.length && text[i + 1] == '\n') 2 else 1
                }
                '\n' -> {
                    count++
                    i++
                }
                else -> i++
            }
        }
        return count
    }
}

/**
 * Pure tokenizer: column → Sora color-ID pairs for one line, given the
 * carried [FloeLineState]. Testable without Android.
 */
internal object FloeLanguageTokenizer {

    data class FloeLineState(
        val inBlockComment: Boolean = false,
        val stringQuote: Char? = null,
    )

    fun spansFor(
        text: CharSequence,
        definition: FloeLanguageDefinition,
        state: FloeLineState,
    ): Pair<List<Pair<Int, Long>>, FloeLineState> {
        val spans = ArrayList<Pair<Int, Long>>()
        var block = state.inBlockComment
        var quote = state.stringQuote
        var i = 0
        val n = text.length
        fun emit(column: Int, colorId: Long) {
            if (spans.isEmpty() || spans.last().first != column) spans.add(column to colorId)
        }
        // Section start color depends on incoming state.
        when {
            block -> emit(0, EditorColorScheme.COMMENT.toLong())
            quote != null -> emit(0, EditorColorScheme.LITERAL.toLong())
            else -> emit(0, EditorColorScheme.TEXT_NORMAL.toLong())
        }
        while (i < n) {
            val c = text[i]
            when {
                block -> {
                    if (definition.blockEnd.isNotEmpty() && c == definition.blockEnd[0] &&
                        matches(text, i, definition.blockEnd)
                    ) {
                        block = false
                        i += definition.blockEnd.length
                        emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                    } else {
                        i++
                    }
                }
                quote != null -> {
                    when {
                        c == '\\' && i + 1 < n -> i += 2
                        c == quote -> {
                            quote = null
                            i += 1
                            emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                        }
                        else -> i++
                    }
                }
                matches(text, i, definition.blockStart) -> {
                    block = true
                    emit(i, EditorColorScheme.COMMENT.toLong())
                    i += definition.blockStart.length
                }
                definition.lineComment.isNotEmpty() && matches(text, i, definition.lineComment) -> {
                    emit(i, EditorColorScheme.COMMENT.toLong())
                    break // rest of line is comment
                }
                c == '"' || (definition.singleQuoteStrings && c == '\'') -> {
                    quote = c
                    emit(i, EditorColorScheme.LITERAL.toLong())
                    i++
                }
                c.isDigit() || (c == '.' && i + 1 < n && text[i + 1].isDigit()) -> {
                    emit(i, EditorColorScheme.LITERAL.toLong())
                    while (i < n && (text[i].isLetterOrDigit() || text[i] == '.' || text[i] == '_')) i++
                    emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                }
                isWordStart(c, definition) -> {
                    val start = i
                    while (i < n && isWordPart(text[i], definition)) i++
                    val word = text.subSequence(start, i).toString()
                    when {
                        word in definition.keywords -> {
                            emit(start, EditorColorScheme.KEYWORD.toLong())
                            emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                        }
                        i < n && text[i] == '(' -> {
                            emit(start, EditorColorScheme.FUNCTION_NAME.toLong())
                            emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                        }
                        else -> emit(start, EditorColorScheme.TEXT_NORMAL.toLong())
                    }
                }
                c in definition.operators -> {
                    emit(i, EditorColorScheme.OPERATOR.toLong())
                    i++
                    emit(i, EditorColorScheme.TEXT_NORMAL.toLong())
                }
                else -> i++
            }
        }
        // Line-scoped state never carries a string open across lines except
        // for languages with multiline strings; block comments do carry.
        return spans to FloeLineState(inBlockComment = block, stringQuote = null)
    }

    private fun matches(text: CharSequence, at: Int, token: String): Boolean {
        if (token.isEmpty() || at + token.length > text.length) return false
        for (k in token.indices) {
            if (text[at + k] != token[k]) return false
        }
        return true
    }

    private fun isWordStart(c: Char, definition: FloeLanguageDefinition): Boolean =
        c.isLetter() || c == '_' || (c == '$' && definition.dollarIdentifiers)

    private fun isWordPart(c: Char, definition: FloeLanguageDefinition): Boolean =
        c.isLetterOrDigit() || c == '_' || (c == '$' && definition.dollarIdentifiers)
}

/** Keyword/comment/string/operator definition for one language ID. */
public data class FloeLanguageDefinition(
    public val languageId: String,
    public val keywords: Set<String>,
    public val lineComment: String,
    public val blockStart: String,
    public val blockEnd: String,
    public val singleQuoteStrings: Boolean = true,
    public val dollarIdentifiers: Boolean = false,
) {
    public val operators: Set<Char> = "+-*/%=<>!&|^~?:;,.(){}[]".toSet()

    public companion object {
        /** Extension-based registry: presentation hint only, never file truth. */
        public val PLAIN = FloeLanguageDefinition("plaintext", emptySet(), "", "", "")

        private val defs: Map<String, FloeLanguageDefinition> = mapOf(
            "swift" to FloeLanguageDefinition(
                "swift",
                setOf("if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "return", "func", "init", "deinit", "class", "struct", "enum", "protocol", "extension", "mutating", "override", "static", "final", "let", "var", "private", "fileprivate", "internal", "public", "open", "import", "typealias", "where", "throw", "throws", "try", "catch", "defer", "as", "is", "in", "nil", "true", "false", "await", "async", "some", "any", "self", "super"),
                "//", "/*", "*/", dollarIdentifiers = false,
            ),
            "kotlin" to FloeLanguageDefinition(
                "kotlin",
                setOf("package", "import", "fun", "val", "var", "object", "class", "interface", "enum", "sealed", "data", "when", "if", "else", "while", "for", "do", "return", "break", "continue", "try", "catch", "finally", "throw", "is", "as", "in", "nil", "null", "true", "false", "private", "internal", "protected", "public", "override", "open", "abstract", "companion", "suspend", "inline", "reified", "lateinit", "const", "this", "super"),
                "//", "/*", "*/",
            ),
            "java" to FloeLanguageDefinition(
                "java",
                setOf("package", "import", "public", "private", "protected", "static", "final", "class", "interface", "enum", "record", "extends", "implements", "new", "return", "if", "else", "while", "for", "do", "switch", "case", "break", "continue", "try", "catch", "finally", "throw", "throws", "void", "int", "long", "double", "float", "boolean", "byte", "char", "short", "null", "true", "false", "this", "super", "abstract", "synchronized", "volatile", "transient"),
                "//", "/*", "*/",
            ),
            "javascript" to FloeLanguageDefinition(
                "javascript",
                setOf("const", "let", "var", "function", "return", "if", "else", "while", "for", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "this", "class", "extends", "super", "import", "export", "from", "async", "await", "yield", "try", "catch", "finally", "throw", "true", "false", "null", "undefined", "void"),
                "//", "/*", "*/", dollarIdentifiers = true,
            ),
            "typescript" to FloeLanguageDefinition(
                "typescript",
                setOf("const", "let", "var", "function", "return", "if", "else", "while", "for", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "this", "class", "extends", "implements", "interface", "type", "enum", "super", "import", "export", "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "true", "false", "null", "undefined", "void", "never", "unknown", "any", "public", "private", "protected", "readonly", "abstract", "declare", "namespace", "module"),
                "//", "/*", "*/", dollarIdentifiers = true,
            ),
            "python" to FloeLanguageDefinition(
                "python",
                setOf("def", "class", "return", "if", "elif", "else", "while", "for", "in", "not", "and", "or", "is", "None", "True", "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "async", "await", "del", "print"),
                "#", "", "", singleQuoteStrings = true,
            ),
            "go" to FloeLanguageDefinition(
                "go",
                setOf("package", "import", "func", "return", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "type", "nil", "true", "false", "string", "int", "int64", "float64", "bool", "byte", "rune", "error", "make", "new", "append", "len", "cap"),
                "//", "/*", "*/",
            ),
            "rust" to FloeLanguageDefinition(
                "rust",
                setOf("fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "super", "where", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "move", "ref", "as", "dyn", "async", "await", "unsafe", "extern", "type", "in", "true", "false", "None", "Some", "Ok", "Err", "String", "Vec", "i32", "u32", "i64", "u64", "f64", "bool", "char", "str", "usize", "isize"),
                "//", "/*", "*/", dollarIdentifiers = false,
            ),
            "c" to FloeLanguageDefinition(
                "c",
                setOf("auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "char", "double", "float", "NULL"),
                "", "/*", "*/", singleQuoteStrings = false,
            ),
            "cpp" to FloeLanguageDefinition(
                "cpp",
                setOf("auto", "bool", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "export", "extern", "float", "for", "friend", "goto", "if", "inline", "int", "long", "namespace", "new", "operator", "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "try", "typedef", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "char", "nullptr", "true", "false"),
                "//", "/*", "*/",
            ),
            "shell" to FloeLanguageDefinition(
                "shell",
                setOf("if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "in", "export", "local", "return", "echo", "cd", "set", "source", "trap", "exit"),
                "#", "", "", singleQuoteStrings = true, dollarIdentifiers = true,
            ),
            "json" to FloeLanguageDefinition(
                "json",
                setOf("true", "false", "null"),
                "", "", "", singleQuoteStrings = false,
            ),
            "sql" to FloeLanguageDefinition(
                "sql",
                setOf("select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner", "outer", "on", "as", "and", "or", "not", "null", "is", "in", "like", "between", "order", "by", "group", "having", "limit", "offset", "distinct", "primary", "key", "foreign", "references", "index", "view", "begin", "commit", "rollback", "transaction", "case", "when", "then", "else", "end"),
                "--", "/*", "*/", singleQuoteStrings = true,
            ),
            "yaml" to FloeLanguageDefinition(
                "yaml",
                emptySet(),
                "#", "", "", singleQuoteStrings = true,
            ),
            "toml" to FloeLanguageDefinition(
                "toml",
                setOf("true", "false"),
                "#", "", "", singleQuoteStrings = true,
            ),
            "css" to FloeLanguageDefinition(
                "css",
                emptySet(),
                "", "/*", "*/", singleQuoteStrings = true,
            ),
        )

        private val byExtension: Map<String, String> = mapOf(
            "swift" to "swift",
            "kt" to "kotlin", "kts" to "kotlin",
            "java" to "java",
            "js" to "javascript", "mjs" to "javascript", "cjs" to "javascript", "jsx" to "javascript",
            "ts" to "typescript", "tsx" to "typescript",
            "py" to "python", "pyw" to "python",
            "go" to "go",
            "rs" to "rust",
            "c" to "c", "h" to "c",
            "cpp" to "cpp", "cc" to "cpp", "hpp" to "cpp", "cxx" to "cpp", "hh" to "cpp",
            "sh" to "shell", "bash" to "shell", "zsh" to "shell",
            "json" to "json", "jsonc" to "json",
            "sql" to "sql",
            "yaml" to "yaml", "yml" to "yaml",
            "toml" to "toml",
            "css" to "css",
        )

        public fun forLanguageId(languageId: String?): FloeLanguageDefinition {
            if (languageId == null) return PLAIN
            return defs[languageId.lowercase()] ?: PLAIN
        }

        public fun forPath(relativePath: String): FloeLanguageDefinition {
            val ext = relativePath.substringAfterLast('.', "").lowercase()
            val id = byExtension[ext] ?: return PLAIN
            return defs[id] ?: PLAIN
        }

        public fun languageIdForPath(relativePath: String): String? {
            val ext = relativePath.substringAfterLast('.', "").lowercase()
            return byExtension[ext]
        }
    }
}
