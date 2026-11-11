// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the N02 AppOps UID write scope argument parsing:
 *  - absent scope keeps the legacy package default (old requests unchanged);
 *  - scope is a closed two-token enum; anything else fails the whole call;
 *  - batch dedupe stays on (packageName, operation) so a batch can never
 *    carry the same target+op twice under different scopes.
 */
class PermissionOpsUidScopeArgumentsTest {

    private fun itemsJson(vararg items: JSONObject): JSONObject {
        val array = JSONArray()
        for (item in items) array.put(item)
        return JSONObject().put("items", array)
    }

    private fun item(
        packageName: String,
        operation: String,
        mode: String,
        scope: String? = null,
    ): JSONObject {
        val json = JSONObject()
            .put("packageName", packageName)
            .put("operation", operation)
            .put("mode", mode)
        if (scope != null) json.put("scope", scope)
        return json
    }

    @Test
    fun absentScopeKeepsLegacyPackageDefault() {
        val request = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(item("com.example.app", "camera", "ignore")),
        )
        assertTrue(request is PermissionOpsBatchArguments.Request.AppOpsManage)
        request as PermissionOpsBatchArguments.Request.AppOpsManage
        assertEquals(1, request.items.size)
        assertEquals("package", request.items[0].scope)
    }

    @Test
    fun explicitUidScopeParses() {
        val request = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(item("com.example.app", "camera", "ignore", scope = "uid")),
        )
        assertTrue(request is PermissionOpsBatchArguments.Request.AppOpsManage)
        request as PermissionOpsBatchArguments.Request.AppOpsManage
        assertEquals("uid", request.items[0].scope)
    }

    @Test
    fun scopeIsAClosedEnum() {
        assertTrue(
            PermissionOpsBatchArguments.appOpsManage(
                itemsJson(item("com.example.app", "camera", "ignore", scope = "UID")),
            ) is PermissionOpsBatchArguments.Request.Invalid,
        )
        assertTrue(
            PermissionOpsBatchArguments.appOpsManage(
                itemsJson(item("com.example.app", "camera", "ignore", scope = "user")),
            ) is PermissionOpsBatchArguments.Request.Invalid,
        )
        assertTrue(
            PermissionOpsBatchArguments.appOpsManage(
                itemsJson(item("com.example.app", "camera", "ignore", scope = "")),
            ) is PermissionOpsBatchArguments.Request.Invalid,
        )
    }

    @Test
    fun dedupeStillCoversScopeVariants() {
        // Same target+op with different scopes in one batch is ambiguous and
        // refuses, exactly like a plain duplicate today.
        val duplicate = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(
                item("com.example.app", "camera", "ignore", scope = "package"),
                item("com.example.app", "camera", "ignore", scope = "uid"),
            ),
        )
        assertTrue(duplicate is PermissionOpsBatchArguments.Request.Invalid)
    }

    @Test
    fun mixedScopesAcrossDifferentTargetsParse() {
        val request = PermissionOpsBatchArguments.appOpsManage(
            itemsJson(
                item("com.example.a", "camera", "ignore", scope = "uid"),
                item("com.example.b", "camera", "allow"),
            ),
        )
        assertTrue(request is PermissionOpsBatchArguments.Request.AppOpsManage)
        request as PermissionOpsBatchArguments.Request.AppOpsManage
        assertEquals("uid", request.items[0].scope)
        assertEquals("package", request.items[1].scope)
    }
}
