package com.floe.android.host

import com.floe.android.feature.integrations.GitHubSourceFieldsUi
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SkillUpdateSourceProjectionTest {
    @Test
    fun persistedSourceReachesTheInstalledRowUsedToReopenTheSheet() {
        val value = Json.parseToJsonElement("""
            {"skills":[{"id":"fixture","name":"Fixture","version":"1.0.0",
              "revision":{"version":"digest"},"official":false,
              "savedSource":{"owner":"octo-org","repository":"community-skill",
                "ref":"feature/next","path":"pkg/inventory.json"}}]}
        """)
        val snapshot = checkNotNull(IntegrationsWire.decodeSkillsSnapshot(value))
        assertEquals(GitHubSourceFieldsUi("octo-org", "community-skill", "feature/next", "pkg/inventory.json"),
            snapshot.installed.single().savedSource)
    }

    @Test
    fun legacyRowsAndMalformedSourceDoNotInventAnUpdateTarget() {
        for (suffix in listOf("", ",\"savedSource\":{\"owner\":\"octo-org\",\"repository\":\"repo\",\"ref\":\"main\",\"path\":123}")) {
            val value = Json.parseToJsonElement("""
                {"skills":[{"id":"fixture","version":"1.0.0","revision":{"version":"digest"}$suffix}]}
            """)
            val snapshot = checkNotNull(IntegrationsWire.decodeSkillsSnapshot(value))
            assertNull(snapshot.installed.single().savedSource)
        }
    }
}
