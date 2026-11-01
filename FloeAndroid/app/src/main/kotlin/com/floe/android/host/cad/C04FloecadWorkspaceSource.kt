// SPDX-License-Identifier: MPL-2.0
//
// Production byte source for the C04C native package reader. Every file is
// staged through the SAME G04 native workspace egress used by Office/Notes;
// the package path is never converted into a host path and the reader only
// asks for package-relative names it has itself validated.
package com.floe.android.host.cad

import com.floe.android.host.WorkspaceOfficeSnapshotStager
import java.util.Locale

internal class C04FloecadWorkspaceSource(
    private val stager: WorkspaceOfficeSnapshotStager,
    private val owner: WorkspaceOfficeSnapshotStager.Owner,
    private val isCurrent: () -> Boolean,
    private val onSnapshot: (WorkspaceOfficeSnapshotStager.Snapshot) -> Unit,
) : C04FloecadSource {
    override fun stage(relativePath: String, maxBytes: Long): C04FloecadStaged {
        val extension = relativePath.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension !in WORKSPACE_EXTENSIONS) {
            throw C04FloecadFailure("invalidPackage", "extension")
        }
        val snapshot = try {
            stager.stage(
                owner = owner,
                relativePath = relativePath,
                formats = setOf(extension),
                maxBytes = maxBytes,
                isCurrent = isCurrent,
            )
        } catch (error: WorkspaceOfficeSnapshotStager.Failure) {
            if (error.code == "ownerChanged") {
                throw C04FloecadFailure("ownerChanged", "owner")
            }
            if (error.code == "contentTooLarge") {
                throw C04FloecadFailure("previewTooLarge", "blobBytes")
            }
            if (error.code == "invalidOfficePath") {
                throw C04FloecadFailure("invalidPackage", "path")
            }
            throw C04FloecadFailure("resourceMissing", error.code.take(120))
        }
        onSnapshot(snapshot)
        return C04FloecadStaged(
            relativePath = snapshot.logicalPath,
            file = snapshot.file,
            bytes = snapshot.bytes,
            sha256 = snapshot.sha256,
        )
    }
}

private val WORKSPACE_EXTENSIONS = setOf("json", "mesh", "brep", "img")
