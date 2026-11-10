// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PackageStageArgumentsTest {
    private fun workspace(path: String) = JSONObject()
        .put("origin", "workspace").put("path", path)
    private fun parse(vararg items: Any): PackageStageArguments.Request =
        PackageStageArguments.parse(JSONObject().put("sources", JSONArray(items.toList())))

    @Test fun mixedOriginsKeepTheirAuthorityAndDeduplicateOnlyIdenticalSources() {
        val root = JSONObject().put("origin", "fileRoot")
            .put("root", "downloads").put("path", "a.apk")
        val result = parse(workspace("a.apk"), root, workspace("a.apk"))
        assertEquals(listOf(PackageStageArguments.Source.Workspace("a.apk"),
            PackageStageArguments.Source.FileRoot("downloads", "a.apk")),
            (result as PackageStageArguments.Request.Stage).sources)
    }

    @Test fun aModelCannotTurnAnAbsoluteOrEscapingPathIntoWorkspaceAuthority() {
        for (path in listOf("/sdcard/a.apk", "../a.apk", "x/../a.apk",
            "./a.apk", "x//a.apk", "x\\a.apk", "a\u0000.apk", "a.txt")) {
            assertTrue(path, parse(workspace(path)) is PackageStageArguments.Request.Invalid)
        }
        assertTrue(parse(JSONObject().put("origin", "url").put("path", "a.apk"))
            is PackageStageArguments.Request.Invalid)
        assertTrue(parse(JSONObject().put("origin", "fileRoot").put("path", "a.apk"))
            is PackageStageArguments.Request.Invalid)
    }

    @Test fun malformedOrUnboundedBatchesFailBeforeAnyFileEffect() {
        assertTrue(parse() is PackageStageArguments.Request.Invalid)
        assertTrue(parse(7) is PackageStageArguments.Request.Invalid)
        val nine = Array<Any>(9) { workspace("a$it.apk") }
        assertTrue(parse(*nine) is PackageStageArguments.Request.Invalid)
        assertTrue(parse(workspace("x".repeat(513) + ".apk"))
            is PackageStageArguments.Request.Invalid)
    }
}
