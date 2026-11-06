// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CoreImage
import Foundation
import ImageIO
import FloeWorkbench
import MediaExchangeCore
import MediaExchangeBridge

enum MediaV2ExchangeFormat: String { case original, references, ora, psd, otio }

extension MediaV2Session {
    /// Full originals preserve every typed object. External formats use their
    /// reviewed subset bridge and refuse unsupported content before export.
    func exportInterchange(_ format: MediaV2ExchangeFormat) async throws -> URL {
        let frozen = project, assets = try resolvedAssets()
        let directory = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("project-r\(frozen.revision)-\(UUID().uuidString)." + (format == .original || format == .references ? "zip" : format.rawValue))
        if format == .original || format == .references {
            let stage = directory.appendingPathComponent(".original-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            var portable = frozen
            if format == .original {
                var references = portable.assets + (portable.prepared?.assets ?? [])
                for entry in portable.preparedJournal?.entries ?? [] {
                    for change in entry.changes {
                        if case .asset(let state)? = change.before { references.append(state.reference) }
                        if case .asset(let state)? = change.after { references.append(state.reference) }
                    }
                }
                var copied = Set<String>()
                let canonical = root.resolvingSymlinksInPath().standardizedFileURL
                for asset in references where copied.insert(asset.relativePath).inserted {
                    guard !asset.relativePath.hasPrefix("/"), !asset.relativePath.split(separator: "/").contains("..") else { throw MediaV2CommandError.unavailable }
                    let source = canonical.appendingPathComponent(asset.relativePath).resolvingSymlinksInPath().standardizedFileURL
                    guard source.path.hasPrefix(canonical.path + "/") else { throw PersonalContentError.outsideLibrary }
                    let target = stage.appendingPathComponent(asset.relativePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                }
                portable.taskWorkspacePath = nil
            } else {
                let references = Dictionary(uniqueKeysWithValues: assets.map { ($0.key.uuidString, $0.value.absoluteString) })
                try JSONEncoder().encode(references).write(to: stage.appendingPathComponent("media-references.json"), options: .atomic)
            }
            let store = MediaProjectStore(directory: stage.appendingPathComponent("Projects"))
            try await store.save(portable)
            try await Task.detached(priority: .utility) {
                var error: NSError?, copyError: (any Error)?
                NSFileCoordinator().coordinate(readingItemAt: stage, options: .forUploading, error: &error) { archive in
                    do {
                        guard try archive.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MediaV2CommandError.invalidInput }
                        try FileManager.default.copyItem(at: archive, to: output)
                    } catch { copyError = error }
                }
                if let error { throw error }; if let copyError { throw copyError }
            }.value
        } else if format == .otio {
            var document = frozen.prepared!
            guard document.trackGraph.tracks.flatMap(\.clips).allSatisfy({ $0.videoMask == nil }) else { throw MediaV2CommandError.unavailable }
            document.trackGraph.tracks.removeAll { $0.clips.isEmpty }
            let sources = try Dictionary(uniqueKeysWithValues: assets.map { (id, url) in (id, try ExchangeMediaSource(externalURL: url.absoluteString)) })
            let timeline = try MediaPreparedExchangeBridge.exportTimeline(document, sources: sources)
            try OTIOAdapter.export(timeline).write(to: output, options: .atomic)
        } else {
            let doc = frozen.prepared!
            guard doc.kind == .image else { throw MediaV2CommandError.unavailable }
            var images: [UUID: RGBAImage] = [:]
            for layer in doc.layers {
                guard case .raster(let raster) = layer.content, case .asset(let id) = raster.source, let url = assets[id],
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      cg.width == doc.canvas?.width, cg.height == doc.canvas?.height else { throw MediaV2CommandError.unavailable }
                images[id] = try PNGCodec.decode(cgImage: cg)
            }
            let portable = try MediaPreparedExchangeBridge.exportImage(doc, images: images)
            if format == .ora { try ORAArchive.write(LayeredExchange.toORA(portable), to: output) }
            else {
                let bytes = try LayeredExchange.toPSD(portable, codec: PSDCodec.bundled())
                try bytes.write(to: output, options: .atomic)
            }
        }
        guard project.revision == frozen.revision else { throw MediaPreparedCoreError.documentChanged }
        recordExport(output)
        return output
    }
}
#endif
