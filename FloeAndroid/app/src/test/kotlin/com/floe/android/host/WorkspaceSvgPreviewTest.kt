// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException

class WorkspaceSvgPreviewTest {
    private fun svg(body: String) = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 200 120'>$body</svg>".toByteArray()
    private fun refuses(bytes: ByteArray) {
        try { WorkspaceSvgPolicy.check(bytes); fail("must refuse") }
        catch (_: WorkspaceSvgPolicy.Rejected) { }
    }

    @Test fun staticShapeGradientAndForwardSymbolReferencesStayLocal() {
        assertTrue(WorkspaceSvgPolicy.check(svg("<rect width='160' height='80' fill='#008000'/>" )).images.isEmpty())
        WorkspaceSvgPolicy.check(svg("<use href='#symbol'/><defs><g id='symbol'><rect fill='url(#paint)' width='20' height='10'/></g><linearGradient id='paint'><stop offset='0' stop-color='green'/></linearGradient></defs>"))
    }
    @Test fun refusesExternalEntitiesResourcesAndActiveContent() {
        refuses(("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///private/not-readable'>]>" + String(svg("<text>&x;</text>"))).toByteArray())
        refuses(svg("<image href='https://example.invalid/a.png'/>"))
        refuses(svg("<use href='file:///not-readable'/>"))
        refuses(svg("<rect style='fill:url(https://example.invalid/paint)'/>"))
        refuses(svg("<style>@import 'https://example.invalid/styles';</style>"))
        refuses(svg("<script>ignored()</script>"))
        refuses(svg("<rect onclick='ignored()'/>"))
        refuses(svg("<filter id='not-implemented'/>"))
    }
    @Test fun refusesCyclicAndExponentialReusableTreesBeforeRendering() {
        refuses(svg("<defs><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/></g></defs><use href='#a'/>"))
        val body = buildString {
            append("<defs><g id='n0'><rect width='1' height='1'/></g>")
            for (i in 1..18) append("<g id='n$i'><use href='#n${i-1}'/><use href='#n${i-1}'/></g>")
            append("</defs><use href='#n18'/>")
        }
        refuses(svg(body))
    }
    @Test fun boundsBytesDepthDimensionsAndCancellation() {
        refuses(ByteArray(WorkspaceSvgPolicy.MAX_BYTES.toInt() + 1))
        refuses(svg("<g>".repeat(65) + "</g>".repeat(65)))
        for (ratio in listOf(200.0/120, 0.2, 1.0, 1000.0)) {
            val (w,h) = WorkspaceSvgPolicy.dimensions(ratio)
            assertTrue(w > 0 && h > 0 && maxOf(w,h) <= WorkspaceSvgPolicy.MAX_EDGE)
            assertTrue(w.toLong()*h <= WorkspaceSvgPolicy.MAX_PIXELS)
        }
        try { WorkspaceSvgPolicy.check(svg("<rect/>")) { throw CancellationException() }; fail("cancel") }
        catch (_: CancellationException) { }
    }
}
