// SPDX-License-Identifier: MPL-2.0
// FloeNotes — NoteCapabilityMatrix extension for the Office283 region lane.
//
// The core matrix constants live in NoteCapabilities.swift. `officeLivePage`
// has always been unioned ad-hoc inside NotesReadTool because that constant
// file is owned by another lane; this extension gives the region lane its
// OWN home for the Office region read surface so the section name exists in
// exactly one compiled place, and keeps a single truth statement for the
// region capability until the one-line merge into `readSections` (when the
// owning lane is free) can absorb both entries.

import Foundation

public extension NoteCapabilityMatrix {
    /// The live-editor capture section implemented in the App target
    /// (NotesAgentTools) — declared here so the schema union and the
    /// model-facing matrix agree on ONE literal.
    static let officeLivePageSection = "officeLivePage"

    /// The saved/committed bounded REGION section implemented in the App
    /// target (NotesAgentTools + OfficeDocumentRegionRenderer): discovery of
    /// real sheet/page identity, then an actual engine print export of the
    /// exact requested region rendered to a bounded PNG that reaches the
    /// provider through the existing tool-artifact vision evidence chain.
    static let officeRegionSection = "officeRegion"

    /// Additional sections this build accepts beyond `readSections`, in ONE
    /// compiled list. Schema generation and validation must both derive from
    /// this so an advertised section can never lack its implementation
    /// branch (and vice versa).
    static let appendedReadSections = [officeLivePageSection, officeRegionSection]

    /// The truthful matrix entry for the region surface. Tier is
    /// `implemented` in the full App build (pinned engine + PDFKit render +
    /// focused opt-in proof tests); the native engine route's final
    /// qualification runs in the primary hosted App build, so this detail
    /// text states exactly what is proven where.
    static var officeRegionCapability: Capability {
        Capability(
            id: "officeRegion", tier: .implemented, path: "native", tool: "notes.read",
            actions: [officeRegionSection], grant: .notesRead, uiConfirmationRequired: false,
            detail: "Bounded assistant-requested Office region reads with real vision artifacts: discovery returns the workbook's own tab-order sheets (name/index/visibility) or the ACTUAL print pages of the saved Word/PowerPoint file; a region call renders the exact target through the pinned engine — workbooks via a private immutable print-area export copy (scoped _xlnm.Print_Area + fitToPage in the copy only, other sheets suppressed in the copy only, canonical bounded A1 ranges, unknown/oversized regions refused with usable bounds), Word/PowerPoint via pageIndex plus optional cropBox pointsRect — and returns the PNG as a digest-verified tool artifact that the provider vision evidence chain attaches to the NEXT request, with source revision/sha256, page/pixel mapping and honest page continuation. Saved content renders with the editor closed; when the live editor is bound, the autosave owner's verified save transaction runs first and active-pen/busy/unproven-dirty states refuse honestly instead of rendering stale bytes. The live viewport, zoom and the user's document are never touched; internal read-evidence renders are not user output files; device OCR is auxiliary only.")
    }
}
