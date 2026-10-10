//
//  AppDragPayload.swift
//  openshape3d
//
//  The one drag-and-drop payload the panels use (history rows, Items rows
//  and folders). It is a typed Transferable on purpose: the first version
//  dragged plain Strings, and a String drop is something every text field
//  accepts — dropping a history row onto another row's Distance field
//  PASTED the feature's UUID into it (found by HistoryReorderUITests,
//  2026-09-05). A custom content type is refused by text fields and lands
//  on the row's own drop destination instead.
//

import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// In-app only; never written to disk, so no Info.plist declaration.
    nonisolated static let os3dDragPayload = UTType(exportedAs: "com.laan.labs.openshape3d.drag-payload")
}

nonisolated struct AppDragPayload: Codable, Hashable, Sendable, Transferable {
    /// "feature", "body", "sketch", "plane", "axis", "image", "itemfolder".
    let kind: String
    /// The referenced object's UUID string.
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .os3dDragPayload)
    }
}
