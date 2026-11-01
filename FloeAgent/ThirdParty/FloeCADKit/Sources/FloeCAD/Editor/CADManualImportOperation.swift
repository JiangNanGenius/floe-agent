//
//  CADManualImportOperation.swift
//  FloeCADKit
//
//  E31-R3 manual import ownership. One opaque identity per user-initiated
//  manual import: the picker file read, the mesh probe, the units apply and
//  the exact STEP/IGES parse. The editor view model owns the single active
//  identity. Beginning a newer operation supersedes every older one, so a
//  late callback (a cancelled parse's error, a superseded probe's return, an
//  old units prompt's apply) can only touch user-visible import state while it
//  is still the active owner.
//
//  This is deliberately NOT a second task/job/store: the Workbench's existing
//  owned `Task` remains the cancellation owner, the parse keeps its own
//  service/token, and nothing is persisted. The identity only decides WHO may
//  write the manual import UI (selection, mode, error, probe, notice, camera).
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// Identity of one manual import operation. MainActor-owned; never persisted
/// and never used as a permission or a document identity.
nonisolated struct CADManualImportOperation: Hashable, Sendable {
    let raw: UInt64
}

/// The failure deliveries a stale manual import could otherwise apply. Only
/// used by the DEBUG ordering seam; production branches on the value too, so
/// a release build keeps the same code path.
nonisolated enum CADManualImportFailureStage: String, Sendable {
    /// A STEP/IGES manual parse failed (or was refused as superseded).
    case exact
    /// The mesh units prompt's probe parse failed.
    case meshProbe
    /// The units prompt's scale/apply step failed.
    case meshApply
}
