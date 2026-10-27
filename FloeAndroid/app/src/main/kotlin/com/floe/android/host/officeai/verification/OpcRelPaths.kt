// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import org.w3c.dom.Document
import org.w3c.dom.Element

data class OpcRelationship(
    val type: String,
    val target: String,
    val external: Boolean,
)

/** Resolves OPC relationship targets without trusting the writer's ordinal
 * file names: logical order comes from the source XML list, and each target
 * is path-normalized against its base directory. Escapes and External rels
 * are refused, never followed.
 */
internal object OpcRelPaths {
    const val PACKAGE_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

    fun relationships(document: Document): Map<String, OpcRelationship> {
        val out = LinkedHashMap<String, OpcRelationship>()
        val roots = DomUtil.elements(document, PACKAGE_REL_NS, "Relationship")
        val pool: List<Element> = if (roots.isEmpty()) {
            // Some writers omit the namespace prefix declaration; accept the
            // unprefixed default only when the namespaced scan found nothing.
            allChildrenWithName(document.documentElement, "Relationship")
        } else {
            roots
        }
        for (element in pool) {
            val id = element.getAttribute("Id")
            val type = element.getAttribute("Type")
            val target = element.getAttribute("Target")
            val mode = element.getAttribute("TargetMode")
            if (id.isEmpty()) continue
            out.put(id, OpcRelationship(type, target, mode.equals("External", ignoreCase = true)))
        }
        return out
    }

    /** Normalizes a rel Target against baseDir ("ppt/", "xl/"); null when the
     * path would escape the package root or is otherwise unsafe.
     */
    fun resolve(baseDir: String, target: String): String? {
        if (target.isEmpty() || target.contains("\\")) return null
        val raw = if (target.startsWith("/")) target.substring(1) else baseDir + target
        val stack = ArrayList<String>()
        for (segment in raw.split("/")) {
            when (segment) {
                "", "." -> { }
                ".." -> {
                    if (stack.isEmpty()) return null
                    stack.removeAt(stack.size - 1)
                }
                else -> stack.add(segment)
            }
        }
        if (stack.isEmpty()) return null
        return stack.joinToString("/")
    }

    private fun allChildrenWithName(root: Element?, name: String): List<Element> {
        if (root == null) return emptyList()
        val kids = root.childNodes
        val out = ArrayList<Element>()
        for (index in 0 until kids.length) {
            val node = kids.item(index)
            if (node is Element && node.localName == name) out.add(node)
        }
        return out
    }
}
