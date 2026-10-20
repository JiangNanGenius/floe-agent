// SPDX-License-Identifier: MPL-2.0
//
// Shared JVM-test wire helpers: the fbd-authored exchange doubles are nested
// classes, so these id extractors must be TOP-LEVEL (a nested class cannot
// call the enclosing test class's private instance methods).

package com.floe.android.host

internal fun correlationOf(raw: String): String {
    val marker = "\"correlationID\":\""
    val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
    val from = start + marker.length
    val end = raw.indexOf('"', from)
    return if (end > from) raw.substring(from, end) else ""
}

internal fun receiptOf(raw: String): String {
    val marker = "\"operationReceiptID\":\""
    val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
    val from = start + marker.length
    val end = raw.indexOf('"', from)
    return if (end > from) raw.substring(from, end) else ""
}
