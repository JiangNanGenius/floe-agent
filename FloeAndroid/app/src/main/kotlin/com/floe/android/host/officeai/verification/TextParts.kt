// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import org.w3c.dom.Document
import org.w3c.dom.Element

/** Normalizes the ACTUAL text of a WordprocessingML part (word/document.xml).
 * Rules: paragraph (w:p leaf) boundaries become '\n' separators; w:tab becomes
 * '\t'; w:br/w:cr become '\n'; w:del/w:delText (deleted content) and
 * w:instrText (field instructions) are excluded; w:ins text counts (it is
 * visible). w:t content is used verbatim, so meaningful whitespace inside a
 * run (xml:space="preserve") is never trimmed. Header/footer/footnote parts are
 * separate package parts and are deliberately NOT inspected: text found there
 * does not prove a body edit.
 */
internal object WordText {
    const val W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private const val MC_NS = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    const val DOCUMENT_PART = "word/document.xml"
    const val NUMBERING_PART = "word/numbering.xml"

    fun normalizedBodyText(document: Document): String {
        val leaves = DomUtil.elements(document, W_NS, "p").filter { paragraph ->
            DomUtil.elementsWithin(paragraph, W_NS, "p").isEmpty()
        }
        val builder = StringBuilder()
        for ((index, paragraph) in leaves.withIndex()) {
            if (index > 0) builder.append('\n')
            collect(paragraph, builder)
        }
        return builder.toString()
    }

    private data class ClipboardParagraph(
        val text: String,
        val numId: String?,
        val level: Int,
    )

    private data class NumberingCatalog(
        val abstracts: Map<String, Element>,
        val nums: Map<String, Element>,
    )

    /** Reconstructs the Writer ASCII clipboard representation used by
     * getSelectionTypeAndText for a whole-body plain-text selection. This is
     * NOT whitespace normalization: every run/paragraph character is kept,
     * LF separates paragraphs, one standard terminal empty body paragraph is
     * omitted, and direct decimal numPr labels get their source-defined four-
     * spaces-per-level indentation plus `N.` and one space. Unsupported list
     * machinery stays unprovable instead of guessing a native label. */
    fun normalizedClipboardBodyText(document: Document, numbering: Document?): String? {
        val paragraphs = clipboardParagraphs(document) ?: return null
        val catalog = numbering?.let(::numberingCatalog)
        val counters = HashMap<Pair<String, Int>, Int>()
        val builder = StringBuilder()
        for ((index, paragraph) in paragraphs.withIndex()) {
            if (index > 0) builder.append('\n')
            if (paragraph.numId != null) {
                val label = clipboardNumberLabel(paragraph, catalog, counters) ?: return null
                builder.append(label).append(' ')
            }
            builder.append(paragraph.text)
        }
        return builder.toString()
    }

    private fun clipboardParagraphs(document: Document): List<ClipboardParagraph>? {
        val leaves = DomUtil.elements(document, W_NS, "p").filter { paragraph ->
            DomUtil.elementsWithin(paragraph, W_NS, "p").isEmpty()
        }
        val paragraphs = ArrayList<ClipboardParagraph>()
        for (paragraph in leaves) {
            val text = StringBuilder().also { collect(paragraph, it) }.toString()
            val properties = DomUtil.childElements(paragraph, W_NS, "pPr").firstOrNull()
            val num = properties?.let {
                DomUtil.childElements(it, W_NS, "numPr").firstOrNull()
            }
            var numId: String? = null
            var level = 0
            if (num != null) {
                val idElement = DomUtil.childElements(num, W_NS, "numId").firstOrNull()
                    ?: return null
                val rawId = idElement.getAttributeNS(W_NS, "val")
                if (rawId.isEmpty()) return null
                val levelElement = DomUtil.childElements(num, W_NS, "ilvl").firstOrNull()
                if (levelElement != null) {
                    level = levelElement.getAttributeNS(W_NS, "val").toIntOrNull() ?: return null
                    if (level !in 0..8) return null
                }
                if (rawId != "0") numId = rawId
            }
            paragraphs.add(ClipboardParagraph(text, numId, level))
        }
        // Writer's whole-document clipboard copy excludes the standard final
        // empty body node. Remove exactly that one node, never arbitrary blank
        // paragraphs or whitespace from real content.
        if (paragraphs.isNotEmpty() && paragraphs.last().text.isEmpty() &&
            paragraphs.last().numId == null
        ) {
            paragraphs.removeAt(paragraphs.lastIndex)
        }
        return paragraphs
    }

    private fun numberingCatalog(numbering: Document): NumberingCatalog {
        val abstracts = DomUtil.elements(numbering, W_NS, "abstractNum").mapNotNull { element ->
            element.getAttributeNS(W_NS, "abstractNumId").takeIf { it.isNotEmpty() }
                ?.let { it to element }
        }.toMap()
        val nums = DomUtil.elements(numbering, W_NS, "num").mapNotNull { element ->
            element.getAttributeNS(W_NS, "numId").takeIf { it.isNotEmpty() }
                ?.let { it to element }
        }.toMap()
        return NumberingCatalog(abstracts, nums)
    }

    private fun clipboardNumberLabel(
        paragraph: ClipboardParagraph,
        catalog: NumberingCatalog?,
        counters: MutableMap<Pair<String, Int>, Int>,
    ): String? {
        val numId = paragraph.numId ?: return null
        val definitions = catalog ?: return null
        val num = definitions.nums[numId] ?: return null
        // Overrides/restarts need engine list state; never silently substitute
        // the abstract definition's start value.
        if (DomUtil.childElements(num, W_NS, "lvlOverride").isNotEmpty()) return null
        val abstractIdElement = DomUtil.childElements(num, W_NS, "abstractNumId").firstOrNull()
            ?: return null
        val abstract = definitions.abstracts[abstractIdElement.getAttributeNS(W_NS, "val")]
            ?: return null
        val level = DomUtil.childElements(abstract, W_NS, "lvl").firstOrNull {
            it.getAttributeNS(W_NS, "ilvl") == paragraph.level.toString()
        } ?: return null
        val format = DomUtil.childElements(level, W_NS, "numFmt").firstOrNull()
            ?.getAttributeNS(W_NS, "val")
        val levelText = DomUtil.childElements(level, W_NS, "lvlText").firstOrNull()
            ?.getAttributeNS(W_NS, "val")
        if (format != "decimal" || levelText != "%${paragraph.level + 1}.") return null
        val start = DomUtil.childElements(level, W_NS, "start").firstOrNull()
            ?.getAttributeNS(W_NS, "val")?.toIntOrNull() ?: return null
        if (start < 0) return null
        val key = numId to paragraph.level
        val value = (counters[key] ?: (start - 1)) + 1
        counters[key] = value
        // Writer OutASC_SwTextNode: four spaces for EACH level from zero
        // through actualListLevel, then GetNumString() and one trailing space.
        return "    ".repeat(paragraph.level + 1) + value + "."
    }

    private fun collect(element: Element, builder: StringBuilder) {
        val kids = element.childNodes
        for (index in 0 until kids.length) {
            val node = kids.item(index)
            if (node !is Element) continue
            val namespace = node.namespaceURI
            val local = node.localName
            if (namespace == W_NS) {
                when (local) {
                    "t" -> builder.append(node.getTextContent() ?: "")
                    "tab" -> builder.append('\t')
                    "br", "cr" -> builder.append('\n')
                    "del", "delText", "instrText" -> { }
                    else -> collect(node, builder)
                }
            } else if (namespace == MC_NS && local == "Fallback") {
                // AlternateContent fallback duplicates the Choice content.
            } else {
                collect(node, builder)
            }
        }
    }
}

/** Normalizes the ACTUAL text of one PresentationML slide part.
 * Shape paragraphs (a:p) are joined with '\n'; a:t text is verbatim; a:br
 * becomes '\n'. No arbitrary object/paragraph offset targeting exists.
 */
internal object PptxText {
    const val A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    const val P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
    const val R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    const val SLIDE_REL_TYPE =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
    const val PRESENTATION_PART = "ppt/presentation.xml"
    const val PRESENTATION_RELS_PART = "ppt/_rels/presentation.xml.rels"

    fun normalizedSlideText(document: Document): String {
        val paragraphs = DomUtil.elements(document, A_NS, "p")
        val builder = StringBuilder()
        for ((index, paragraph) in paragraphs.withIndex()) {
            if (index > 0) builder.append('\n')
            collect(paragraph, builder)
        }
        return builder.toString()
    }

    private fun collect(element: Element, builder: StringBuilder) {
        val kids = element.childNodes
        for (index in 0 until kids.length) {
            val node = kids.item(index)
            if (node !is Element) continue
            if (node.namespaceURI == A_NS) {
                when (node.localName) {
                    "t" -> builder.append(node.getTextContent() ?: "")
                    "br" -> builder.append('\n')
                    else -> collect(node, builder)
                }
            } else {
                collect(node, builder)
            }
        }
    }

    internal sealed class SlideOrderResult {
        data class Ordered(val slidePartNames: List<String>) : SlideOrderResult()
        data class Refused(val code: String) : SlideOrderResult()
    }

    /** Resolves the LOGICAL slide order: p:sldIdLst document order in
     * presentation.xml, each r:id through presentation.xml.rels to the actual
     * slide part. After a reorder/delete the "slideN.xml" file name is NOT
     * necessarily logical index N, so the file names are never assumed.
     */
    fun resolveSlideOrder(zip: BoundedZipReader): SlideOrderResult {
        val presentation = when (val read = zip.readPart(PRESENTATION_PART)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return SlideOrderResult.Refused(
                VerificationCodes.PART_MISSING,
            )
            is PartReadResult.Refused -> return SlideOrderResult.Refused(read.code)
        }
        val presentationDoc = when (val parsed = TrustedXml.parse(presentation)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return SlideOrderResult.Refused(parsed.code)
        }
        val relBytes = when (val read = zip.readPart(PRESENTATION_RELS_PART)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return SlideOrderResult.Refused(
                VerificationCodes.RELATION_UNRESOLVED,
            )
            is PartReadResult.Refused -> return SlideOrderResult.Refused(read.code)
        }
        val relsDoc = when (val parsed = TrustedXml.parse(relBytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return SlideOrderResult.Refused(parsed.code)
        }
        val rels = OpcRelPaths.relationships(relsDoc)
        val lists = DomUtil.elements(presentationDoc, P_NS, "sldIdLst")
        if (lists.isEmpty()) {
            return SlideOrderResult.Refused(VerificationCodes.RELATION_UNRESOLVED)
        }
        val ordered = ArrayList<String>()
        for (list in lists) {
            for (sldId in DomUtil.childElements(list, P_NS, "sldId")) {
                val relId = sldId.getAttributeNS(R_NS, "id")
                if (relId.isEmpty()) {
                    return SlideOrderResult.Refused(VerificationCodes.RELATION_UNRESOLVED)
                }
                val relationship = rels[relId]
                    ?: return SlideOrderResult.Refused(VerificationCodes.RELATION_UNRESOLVED)
                if (relationship.external || relationship.type != SLIDE_REL_TYPE) {
                    return SlideOrderResult.Refused(VerificationCodes.RELATION_UNRESOLVED)
                }
                val path = OpcRelPaths.resolve("ppt/", relationship.target)
                    ?: return SlideOrderResult.Refused(VerificationCodes.RELATION_UNRESOLVED)
                ordered.add(path)
            }
        }
        return SlideOrderResult.Ordered(ordered)
    }
}
