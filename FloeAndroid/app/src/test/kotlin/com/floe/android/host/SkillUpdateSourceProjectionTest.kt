package com.floe.android.host

import com.floe.android.feature.integrations.GitHubSourceFieldsUi
import com.floe.android.feature.integrations.SkillSourceKindUi
import com.floe.android.feature.integrations.CatalogCardStateUi
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillUpdateSourceProjectionTest {
    @Test
    fun bundledGuideIdentityCannotBeRedirectedByACatalogNameCollision() {
        val value = Json.parseToJsonElement("""
            {"skills":[{"id":"floe-pdf","version":"1.0.0","bundled":true,"official":true,
              "revision":{"version":"digest"}}]}
        """)
        val row = checkNotNull(IntegrationsWire.decodeSkillsSnapshot(value)).installed.single()
        assertEquals(SkillSourceKindUi.BUNDLED, row.sourceKind)
        assertNull(IntegrationsWire.catalogUpdateVersion(row, "9.0.0"))
        assertTrue(IntegrationsWire.catalogCardState(row, "9.0.0", "different source") is CatalogCardStateUi.Unavailable)
        assertFalse(row.isBundledReadOnlyGuide)
    }

    @Test
    fun restoringGuidesRequiresDefiniteOutcomesForEveryReportedGuide() {
        assertTrue(IntegrationsWire.bundledRestoreSucceeded(Json.parseToJsonElement("""
            {"outcomes":{"floe-pdf":"installed","floe-shell":"unchanged","local":"userManaged"}}
        """)))
        for (value in listOf("null", "{}", "{\"outcomes\":{}}", "{\"outcomes\":[]}",
            "{\"outcomes\":{\"guide\":\"failed\"}}", "{\"outcomes\":{\"guide\":\"inFlight\"}}",
            "{\"outcomes\":{\"guide\":\"unknown\"}}", "{\"outcomes\":{\"guide\":null}}")) {
            assertFalse(value, IntegrationsWire.bundledRestoreSucceeded(Json.parseToJsonElement(value)))
        }
    }

    @Test
    fun catalogNameCollisionCannotRedirectACommunityInstallation() {
        for (official in listOf(false, true)) {
            val value = Json.parseToJsonElement("""
                {"skills":[{"id":"same-name","version":"1.0.0","official":$official,
                  "revision":{"version":"digest"}}]}
            """)
            val row = checkNotNull(IntegrationsWire.decodeSkillsSnapshot(value)).installed.single()
            assertEquals(if (official) "1.0.1" else null,
                IntegrationsWire.catalogUpdateVersion(row, "1.0.1"))
            val state = IntegrationsWire.catalogCardState(row, "1.0.1", "different source")
            if (official) assertEquals(CatalogCardStateUi.UpdateTo("1.0.1"), state)
            else assertTrue(state is CatalogCardStateUi.Unavailable)
            assertNull(IntegrationsWire.catalogUpdateVersion(row, "1.0.0"))
        }
    }

    @Test
    fun sameVersionWithRealFileChangesStillRequiresReview() {
        val review = checkNotNull(IntegrationsWire.decodeReview(Json.parseToJsonElement("""
            {"reviewToken":"fixture","skillID":"fixture","version":"1.0.0","committed":false,
             "changedFiles":["SKILL.md","examples/update.md"],"addedCapabilities":[],"addedTools":[]}
        """)))
        assertEquals("1.0.0", review.version)
        assertTrue(review.hasChanges)
        assertEquals(listOf("SKILL.md", "examples/update.md"), review.scriptPaths)
    }

    @Test
    fun anUnchangedReviewIsDistinctFromNewPermissions() {
        for (capabilities in listOf("[]", "[\"remoteExecution\"]")) {
            val review = checkNotNull(IntegrationsWire.decodeReview(Json.parseToJsonElement("""
                {"reviewToken":"fixture","skillID":"fixture","version":"1.0.0","committed":false,
                 "changedFiles":[],"addedCapabilities":$capabilities,"addedTools":[]}
            """)))
            if (capabilities == "[]") assertFalse(review.hasChanges) else assertTrue(review.hasChanges)
        }
    }

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
