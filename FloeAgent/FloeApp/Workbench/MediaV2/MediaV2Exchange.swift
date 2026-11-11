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
            var images: [UUID: RGBAImage] = [:], previews: [UUID: PortableLayer] = [:], masks: [UUID: RGBAImage] = [:]
            guard let canvas = doc.canvas else { throw MediaV2CommandError.unavailable }
            for layer in doc.layers {
                if let mask = layer.mask {
                    guard layer.transform == .init(), layer.canvasSpace == nil else { throw MediaV2CommandError.unavailable }
                    masks[layer.id] = try PNGCodec.decode(cgImage: await imageRenderer.exchangeMask(mask, canvas: .init(width: canvas.width, height: canvas.height)))
                }
                if case .raster(let raster) = layer.content, case .asset(let id) = raster.source, let url = assets[id],
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
                    if url.pathExtension.lowercased() == "png", orientation == 1 {
                        images[id] = try PNGCodec.decode(Data(contentsOf: url, options: .mappedIfSafe))
                    } else { images[id] = try PNGCodec.decode(cgImage: cg) }
                    let scale = min(Double(canvas.width) / Double(cg.width), Double(canvas.height) / Double(cg.height)) * layer.transform.scale
                    if orientation == 1, raster.crop == nil, abs(scale - 1) < 0.000001, layer.transform.rotationDegrees == 0,
                       layer.transform.flipX != true, layer.transform.flipY != true { continue }
                }
                guard layer.contentKind == .raster || layer.contentKind == .text else { continue }
                var single = doc, source = layer
                source.parentID = nil; source.opacity = 1; source.isVisible = true; source.mask = nil; source.clip = nil
                single.layers = [source]
                let rendered = try await imageRenderer.renderPrepared(single, canvas: .init(width: canvas.width, height: canvas.height),
                    resolveAsset: { assets[$0] }, applyCanvasAdjustment: false)
                var frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
                if case .text(let text) = layer.content {
                    let legacy = ImageLayer(kind: .text, name: layer.name, text: text)
                    guard let size = try await imageRenderer.naturalSize(of: legacy, canvas: frame.size, resolveAsset: { assets[$0] }) else { throw MediaV2CommandError.unavailable }
                    let width = size.width * layer.transform.scale, height = size.height * layer.transform.scale
                    frame = CGRect(x: layer.transform.centerX * Double(canvas.width) - width / 2,
                        y: layer.transform.centerY * Double(canvas.height) - height / 2, width: width, height: height).integral
                    guard CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height).contains(frame) else { throw MediaV2CommandError.unavailable }
                }
                guard let pixels = rendered.cropping(to: frame) else { throw MediaV2CommandError.unavailable }
                previews[layer.id] = .init(name: layer.name, image: try PNGCodec.decode(cgImage: pixels), left: Int(frame.minX), top: Int(frame.minY))
            }
            let portable = try MediaPreparedExchangeBridge.exportImage(doc, images: images, layerPreviews: previews, masks: masks)
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

extension MediaV2Session {
    /// A system-picked layered file enters the existing asset staging and CAS
    /// transaction. The original container is retained as a separate asset.
    func importLayeredFile(_ url: URL) async throws {
        guard document.kind == .image, !saving, !processingTool, document.canvas != nil else { throw MediaV2CommandError.unavailable }
        processingTool = true
        let worker = Task { @MainActor in try await executeLayeredImport(url) }
        cancelToolWork = { worker.cancel() }
        defer { processingTool = false; cancelToolWork = nil }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func executeLayeredImport(_ url: URL) async throws {
        guard let destinationCanvas = document.canvas else { throw MediaV2CommandError.unavailable }
        let revision = document.revision, root = root
        let scope = MediaV2ImportScope(token: nil), writer = MediaV2LayeredImportWriter()
        defer { Task { await writer.close() } }
        let copy = Task.detached(priority: .userInitiated) {
            try MediaV2StagedAsset.copy(source: url, destinationRoot: root, token: nil, ephemeralSource: false)
        }
        let original = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
        scope.add(original)
        guard original.byteCount <= 536_870_912 else { throw MediaV2CommandError.invalidInput }
        let file = original.url, name = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension.lowercased()
        let parse = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let portable: PortableDocument
            if ext == "psd" {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                switch try PSDCodec.bundled().importDocument(data) {
                case .editable(let image): portable = try LayeredExchange.fromPSD(image)
                case .preserved(_, let compatibility): throw PSDCodecError.unsupported(compatibility.reasons)
                }
            } else { portable = try LayeredExchange.fromORA(ORAArchive.read(from: file)) }
            try Task.checkCancellation()
            return try MediaPreparedExchangeBridge.importImage(portable, name: name)
        }
        let imported = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
        guard let incoming = imported.project.prepared, let sourceCanvas = incoming.canvas else { throw MediaV2CommandError.invalidInput }
        var operations: [MediaPreparedOperation] = [], mapping: [UUID: MediaAssetReference] = [:]
        let preserved = MediaAssetReference(kind: .image, relativePath: "Assets/" + file.lastPathComponent,
            originalName: url.lastPathComponent, byteCount: original.byteCount, contentHash: original.sha256)
        operations.append(.init(action: .insertAsset(preserved)))
        for reference in incoming.assets {
            guard let bytes = imported.pendingPNGs[reference.id] else { throw MediaV2CommandError.invalidInput }
            let temporary = try await writer.write(bytes, root: root)
            let (staged, asset) = try await MediaV2ImportIO.stage(temporary, root: root, token: nil, ephemeralSource: true)
            scope.add(staged); mapping[reference.id] = asset; operations.append(.init(action: .insertAsset(asset)))
        }
        let targetCanvas: MediaCanvas, startsEmpty = document.layers.isEmpty
        if startsEmpty {
            operations += try MediaCanvasLayout.actions(document, width: sourceCanvas.width, height: sourceCanvas.height, mode: .scaleImage).map { .init(action: $0) }
            targetCanvas = sourceCanvas
        } else { targetCanvas = destinationCanvas }
        let scale = min(Double(targetCanvas.width) / Double(sourceCanvas.width), Double(targetCanvas.height) / Double(sourceCanvas.height))
        var importGroupID: UUID?
        if !startsEmpty {
            var group = MediaPreparedLayer(name: name, content: .group(.init(isIsolated: true)))
            if targetCanvas != sourceCanvas {
                group.canvasSpace = .init(referenceCanvas: sourceCanvas, transform: .init(a: scale, d: scale,
                    tx: (Double(targetCanvas.width) - Double(sourceCanvas.width) * scale) / 2,
                    ty: (Double(targetCanvas.height) - Double(sourceCanvas.height) * scale) / 2))
            }
            importGroupID = group.id
            operations.append(.init(action: .insertLayer(layer: group, parentID: nil, index: nil)))
        }
        for var layer in incoming.layers {
            if case .raster(var raster) = layer.content, case .asset(let id) = raster.source {
                guard let asset = mapping[id] else { throw MediaV2CommandError.invalidInput }
                raster.source = .asset(asset.id); layer.content = .raster(raster)
            }
            layer.parentID = layer.parentID ?? importGroupID
            operations.append(.init(action: .insertLayer(layer: layer, parentID: layer.parentID, index: nil)))
        }
        guard operations.count <= MediaPreparedSchema.maximumOperationsPerApply else { throw MediaV2CommandError.unavailable }
        try scope.validate(); try Task.checkCancellation()
        _ = try await apply(operations, expectedRevision: revision, actor: .user, didCommit: { scope.didCommit() })
        selectedLayerID = importGroupID ?? incoming.layers.last(where: { $0.parentID == nil })?.id
    }
}

private actor MediaV2LayeredImportWriter {
    private var files: [MediaV2ImportTemporaryFile] = []
    func write(_ data: Data, root: URL) throws -> URL {
        let file = try MediaV2ImportTemporaryFile(root: root, fileExtension: "png")
        try file.write(data); files.append(file); return file.url
    }
    func close() { files.removeAll() }
}
#endif
