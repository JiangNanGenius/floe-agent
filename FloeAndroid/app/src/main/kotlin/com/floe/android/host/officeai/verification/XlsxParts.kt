// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import org.w3c.dom.Document

/** Resolves XLSX logical sheet order and shared strings. The logical tab
 * order is the document order of the <sheet> children of xl/workbook.xml
 * <sheets>; each entry's r:id is resolved through xl/_rels/workbook.xml.rels
 * to the ACTUAL worksheet part. Spreadsheet IDs and file-name ordinals are
 * never assumed to equal the logical index (they diverge after tab
 * reorder/delete), and non-worksheet targets (chartsheets) are refused.
 */
internal object XlsxParts {
    const val S_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    const val R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    const val WORKBOOK_PART = "xl/workbook.xml"
    const val WORKBOOK_RELS_PART = "xl/_rels/workbook.xml.rels"
    const val DEFAULT_SHARED_STRINGS_PART = "xl/sharedStrings.xml"
    private const val REL_TYPE_PREFIX =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    internal data class SheetTarget(val partName: String?, val refusalCode: String?)

    internal sealed class WorkbookPlan {
        data class Ready(
            val sheets: List<SheetTarget>,
            val sharedStringsPart: String?,
        ) : WorkbookPlan()

        data class Refused(val code: String) : WorkbookPlan()
    }

    fun plan(zip: BoundedZipReader): WorkbookPlan {
        val workbookBytes = when (val read = zip.readPart(WORKBOOK_PART)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return WorkbookPlan.Refused(VerificationCodes.PART_MISSING)
            is PartReadResult.Refused -> return WorkbookPlan.Refused(read.code)
        }
        val workbookDoc = when (val parsed = TrustedXml.parse(workbookBytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return WorkbookPlan.Refused(parsed.code)
        }
        val relsBytes = when (val read = zip.readPart(WORKBOOK_RELS_PART)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return WorkbookPlan.Refused(
                VerificationCodes.RELATION_UNRESOLVED,
            )
            is PartReadResult.Refused -> return WorkbookPlan.Refused(read.code)
        }
        val relsDoc = when (val parsed = TrustedXml.parse(relsBytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return WorkbookPlan.Refused(parsed.code)
        }
        val rels = OpcRelPaths.relationships(relsDoc)
        val sheetsNodes = DomUtil.elements(workbookDoc, S_NS, "sheets")
        if (sheetsNodes.isEmpty()) {
            return WorkbookPlan.Refused(VerificationCodes.RELATION_UNRESOLVED)
        }
        val sheets = ArrayList<SheetTarget>()
        for (sheetsElement in sheetsNodes) {
            for (sheet in DomUtil.childElements(sheetsElement, S_NS, "sheet")) {
                val relId = sheet.getAttributeNS(R_NS, "id")
                if (relId.isEmpty()) {
                    sheets.add(SheetTarget(null, VerificationCodes.RELATION_UNRESOLVED))
                    continue
                }
                val relationship = rels[relId]
                if (relationship == null) {
                    sheets.add(SheetTarget(null, VerificationCodes.RELATION_UNRESOLVED))
                    continue
                }
                if (relationship.external) {
                    sheets.add(SheetTarget(null, VerificationCodes.RELATION_UNRESOLVED))
                    continue
                }
                when (relationship.type) {
                    REL_TYPE_PREFIX + "worksheet" -> {
                        val path = OpcRelPaths.resolve("xl/", relationship.target)
                        sheets.add(
                            if (path == null) {
                                SheetTarget(null, VerificationCodes.RELATION_UNRESOLVED)
                            } else {
                                SheetTarget(path, null)
                            },
                        )
                    }
                    REL_TYPE_PREFIX + "chartsheet" -> {
                        sheets.add(SheetTarget(null, VerificationCodes.TARGET_NOT_WORKSHEET))
                    }
                    else -> sheets.add(SheetTarget(null, VerificationCodes.TARGET_NOT_WORKSHEET))
                }
            }
        }
        val sharedStringsPart = resolveSharedStrings(rels)
        return WorkbookPlan.Ready(sheets, sharedStringsPart)
    }

    private fun resolveSharedStrings(
        rels: Map<String, OpcRelationship>,
    ): String? {
        for (relationship in rels.values) {
            if (relationship.type == REL_TYPE_PREFIX + "sharedStrings") {
                if (relationship.external) continue
                val path = OpcRelPaths.resolve("xl/", relationship.target) ?: continue
                return path
            }
        }
        return DEFAULT_SHARED_STRINGS_PART
    }

    /** Decodes xl/sharedStrings.xml into the exact ordered si text list.
     * Bounded by the artifact part caps enforced in BoundedZipReader; the
     * index into this list must come from a <v> inside the target cell only.
     */
    fun sharedStrings(zip: BoundedZipReader, partName: String): SharedStringsResult {
        val bytes = when (val read = zip.readPart(partName)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return SharedStringsResult.Missing
            is PartReadResult.Refused -> return SharedStringsResult.Refused(read.code)
        }
        val document = when (val parsed = TrustedXml.parse(bytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return SharedStringsResult.Refused(parsed.code)
        }
        val items = DomUtil.elements(document, S_NS, "si")
        val out = ArrayList<String>(items.size)
        for (item in items) {
            val parts = DomUtil.elementsWithin(item, S_NS, "t")
            val builder = StringBuilder()
            for (text in parts) builder.append(text.getTextContent() ?: "")
            out.add(builder.toString())
        }
        return SharedStringsResult.Ready(out)
    }

    internal sealed class SharedStringsResult {
        data class Ready(val strings: List<String>) : SharedStringsResult()
        object Missing : SharedStringsResult()
        data class Refused(val code: String) : SharedStringsResult()
    }
}
