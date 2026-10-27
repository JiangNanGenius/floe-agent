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
