// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the closed permission/AppOps argument parsing:
 * one selected package for the queries, ordered batches of at most 8
 * validated items for the managers, dedupe within a batch, and fail-closed
 * invalid_arguments on any malformed entry before any device effect.
 *
 * JSON arrays are built with JSONArray (a Kotlin List put stores a raw
 * Collection that optJSONArray cannot read back on the real wire).
 */
class PermissionOpsBatchArgumentsTest {

    private fun itemsJson(vararg items: JSONObject): JSONObject {
        val array = JSONArray()
        for (item in items) array.put(item)
        return JSONObject().put("items", array)
    }

    private fun item(packageName: String, operation: String, mode: String): JSONObject =
        JSONObject()
            .put("packageName", packageName)
            .put("operation", operation)
            .put("mode", mode)

    private fun permissionItem(packageName: String, permission: String, action: String): JSONObject =
        JSONObject()
            .put("packageName", packageName)
            .put("permission", permission)
            .put("action", action)

    @Test
    fun permissionsQueryParsesSelectedPackage() {
        val request = PermissionOpsBatchArguments.permissionsQuery(
            JSONObject().put("packageName", "com.example.app"),
        )
        assertTrue(request is PermissionOpsBatchArguments.Request.PermissionsQuery)
        request as PermissionOpsBatchArguments.Request.PermissionsQuery
        assertEquals("com.example.app", request.packageName)
        assertEquals(0, request.userId)
    }

    @Test
    fun queriesRejectMalformedPackages() {
        assertTrue(
            PermissionOpsBatchArguments.permissionsQuery(
                JSONObject().put("packageName", "not a package"),
            ) is PermissionOpsBatchArguments.Request.Invalid,
        )
        assertTrue(
            PermissionOpsBatchArguments.appOpsQuery(JSONObject()) is
                PermissionOpsBatchArguments.Request.Invalid,
        )
    }

    @Test
    fun permissionsManageParsesAndDedupesItems() {
        val duplicate = PermissionOpsBatchArguments.permissionsManage(
            itemsJson(
                permissionItem("com.example.app", "android.permission.CAMERA", "grant"),
                permissionItem("com.example.app", "android.permission.CAMERA", "revoke"),
            ),
        )
        assertTrue(duplicate is PermissionOpsBatchArguments.Request.Invalid)
        val ok = PermissionOpsBatchArguments.permissionsManage(
            itemsJson(
                permissionItem("com.example.app", "android.permission.CAMERA", "grant"),
                permissionItem("com.example.other", "android.permission.POST_NOTIFICATIONS", "revoke"),
            ),
        )
        assertTrue(ok is PermissionOpsBatchArguments.Request.PermissionsManage)
        ok as PermissionOpsBatchArguments.Request.PermissionsManage
        assertEquals(2, ok.items.size)
        assertEquals("grant", ok.items[0].action)
        assertEquals(0, ok.userId)
    }

    @Test
    fun permissionsManageRejectsUnknownActionAndPermissionShape() {
        val badAction = PermissionOpsBatchArguments.permissionsManage(
            itemsJson(
                permissionItem("com.example.app", "android.permission.CAMERA", "force"),
            ),
        )
        assertTrue(badAction is PermissionOpsBatchArguments.Request.Invalid)
        val badPermission = PermissionOpsBatchArguments.permissionsManage(
            itemsJson(
                permissionItem("com.example.app", "CAMERA", "grant"),
            ),
        )
        assertTrue(badPermission is PermissionOpsBatchArguments.Request.Invalid)
    }

    @Test
    fun appOpsManageParsesClosedCatalogAndModes() {
        val ok = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(
                item("com.example.app", "camera", "ignore"),
                item("com.example.app", "background-run", "default"),
                item("com.example.app", "background-run-any", "allow"),
            ),
        )
        assertTrue(ok is PermissionOpsBatchArguments.Request.AppOpsManage)
        ok as PermissionOpsBatchArguments.Request.AppOpsManage
        assertEquals(3, ok.items.size)
        assertEquals("ignore", ok.items[0].mode)
        val badOp = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(item("com.example.app", "mock-location", "allow")),
        )
        assertTrue(badOp is PermissionOpsBatchArguments.Request.Invalid)
        val badMode = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(item("com.example.app", "camera", "sometimes")),
        )
        assertTrue(badMode is PermissionOpsBatchArguments.Request.Invalid)
    }

    @Test
    fun batchesAreCappedAtEight() {
        val array = JSONArray()
        for (index in 1..9) {
            array.put(item("com.example.app$index", "camera", "allow"))
        }
        val request = PermissionOpsBatchArguments.appOpsManage(
            JSONObject().put("items", array),
        )
        assertTrue(request is PermissionOpsBatchArguments.Request.Invalid)
    }
}
