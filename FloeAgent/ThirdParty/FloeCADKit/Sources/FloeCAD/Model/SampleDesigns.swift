//
//  SampleDesigns.swift
//  openshape3d
//
//  The sample designs that ship in the app bundle (`openshape3d/Demos/*.os3d`)
//  and the "Demos" gallery folder they are installed into. Each is an
//  ordinary `.os3d` archive baked from a live build over the agent bridge
//  (`scripts/demo_models.py`, `GET /v1/archive`), so a sample opens with its
//  full feature history and every step stays editable.
//
//  Installing is idempotent: the folder is created once and a sample is
//  skipped when a design of that name is already in it, so "Add Sample
//  Designs" after a user deleted one puts only that one back.
//

import Foundation
import SwiftData

nonisolated enum SampleDesigns {
    /// The gallery folder the samples land in.
    static let folderName = "Demos"

    struct Sample: Identifiable, Sendable, Equatable {
        /// The archive's file name without extension (also its `id`).
        let id: String
        /// Gallery name; the archive's own name is ignored so a rename in
        /// the baking session cannot leak through.
        let name: String
        /// One line for the welcome screen.
        let blurb: String
        let systemImage: String
    }

    /// Order is the welcome screen's order. A sample listed here without a
    /// matching archive in the bundle is skipped, not shown.
    static let catalog: [Sample] = [
        Sample(id: "motorcycle-wheel", name: "Motorcycle Wheel",
               blurb: "A revolved rim with patterned spoke holes, mirrored and unioned, on a rubber tyre.",
               systemImage: "circle.circle"),
        Sample(id: "mounting-plate", name: "Mounting Plate",
               blurb: "Sketch, extrude, fillet and a boss: the four steps behind most parts.",
               systemImage: "square.on.square.dashed"),
        Sample(id: "glass-bottle", name: "Glass Bottle",
               blurb: "A spline profile revolved, shelled to a 2 mm wall and rounded at the lip.",
               systemImage: "waterbottle"),
        Sample(id: "plate-cam", name: "Plate Cam",
               blurb: "A cycloidal motion law drawn as one closed spline and extruded.",
               systemImage: "gearshape"),
    ]

    /// Catalog entries whose archive is actually in the bundle.
    static func available(in bundle: Bundle = .main) -> [Sample] {
        catalog.filter { url(for: $0, in: bundle) != nil }
    }

    static func url(for sample: Sample, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: sample.id, withExtension: "os3d", subdirectory: "Demos")
            ?? bundle.url(forResource: sample.id, withExtension: "os3d")
    }

    /// A small PNG baked next to the archive for the welcome screen, so the
    /// list does not decode four mesh archives just to show their pictures.
    static func thumbnailURL(for sample: Sample, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: sample.id + "-thumb", withExtension: "png", subdirectory: "Demos")
            ?? bundle.url(forResource: sample.id + "-thumb", withExtension: "png")
    }

    /// Decoded archive for one sample; nil when the file is missing or was
    /// written by a newer format than this build reads.
    static func archive(for sample: Sample, in bundle: Bundle = .main) -> ProjectArchive? {
        guard let url = url(for: sample, in: bundle),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProjectArchive.decode(data)
    }

    /// Which samples `install` would add, given the designs already in the
    /// Demos folder. Pure, so the decision is unit-testable.
    static func missing(from installedNames: Set<String>, available: [Sample]) -> [Sample] {
        available.filter { !installedNames.contains($0.name) }
    }

    /// Install every sample not already in the Demos folder. Returns the
    /// folder (created if needed) and how many designs were added. The
    /// caller saves the context.
    @MainActor
    @discardableResult
    static func install(into context: ModelContext, bundle: Bundle = .main)
        -> (folderID: UUID, added: Int)
    {
        let folder = demosFolder(in: context) ?? {
            let folder = ProjectFolder(name: folderName, parentID: nil)
            context.insert(folder)
            return folder
        }()
        let installed = Set(
            ((try? context.fetch(FetchDescriptor<Project>())) ?? [])
                .filter { $0.folderID == folder.folderID }
                .map(\.name))
        var added = 0
        // Newest lists first in the gallery, so insert in reverse: the
        // catalog's first sample (the hero) is the first card.
        for sample in missing(from: installed, available: available(in: bundle)).reversed() {
            guard let archive = archive(for: sample, in: bundle) else { continue }
            let project = archive.remappingAllUUIDs()
                .insert(into: context, name: sample.name, trustingBRep: true)
            project.folderID = folder.folderID
            added += 1
        }
        if added > 0 { folder.modifiedAt = Date() }
        return (folder.folderID, added)
    }

    /// The top-level "Demos" folder, if the user still has one.
    @MainActor
    static func demosFolder(in context: ModelContext) -> ProjectFolder? {
        let folders = (try? context.fetch(FetchDescriptor<ProjectFolder>())) ?? []
        return folders.first { $0.parentID == nil && $0.name == folderName }
    }
}
