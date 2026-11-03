// SPDX-License-Identifier: MPL-2.0
// DEBUG starting data and read-only observations for the shipped material UI.
#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import simd

@MainActor
public enum CADTextureImportUIFixture {
    public static let argument = "--ui-test-cad-texture-import"
    public static let resetArgument = "--ui-test-cad-texture-import-reset"
    public static let reopenArgument = "--ui-test-cad-texture-import-reopen"
    private static let bodyName = "Synthetic texture panel"
    private static let sourceNames = ["Synthetic color.png", "Synthetic normal.png"]
    private static let colorPixels: [[UInt8]] = [
        [220, 40, 30, 255], [30, 210, 60, 255],
        [40, 60, 220, 128], [220, 190, 30, 255],
    ]
    private static let normalPixels: [[UInt8]] = [
        [64, 128, 220, 255], [192, 128, 220, 255],
        [128, 64, 220, 128], [128, 192, 220, 255],
    ]

    private final class WeakDraft {
        weak var value: CADMaterialDraftModel?
        init(_ value: CADMaterialDraftModel) { self.value = value }
    }
    private static var stagedOwners: [ObjectIdentifier: WeakDraft] = [:]

    public static func open(reset: Bool, reopen: Bool) async throws -> FloeCADDocument {
        let root = try fixtureRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("texture-import.floecad")
        let document: FloeCADDocument
        if reopen {
            guard !reset else { throw failure("Reset and reopen cannot be requested together.") }
            document = try await FloeCADDocument.open(at: url)
        } else {
            if reset, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw failure("Use reset or reopen for the fixture-owned package.") }
            let sources = try [pattern(colorPixels), pattern(normalPixels)]
            var sourceHashes: [String: String] = [:]
            for (index, bytes) in sources.enumerated() {
                try bytes.write(to: root.appendingPathComponent(sourceNames[index]), options: .atomic)
                sourceHashes[sourceNames[index]] = CADMaterialTexture.digest(bytes)
            }
            try JSONEncoder().encode(sourceHashes).write(to: root.appendingPathComponent("sources.json"), options: .atomic)
            document = try await FloeCADDocument.create(at: url, name: "Texture import")
            do {
                let material = CADMaterialDefinition(name: "Synthetic texture material", uvMapping: .mesh)
                var body = Body(id: BodyID(), name: bodyName, transform: .identity, primitive: nil,
                    render: RenderMesh(positions: [.init(-60, 0, -30), .init(60, 0, -30), .init(60, 0, 30), .init(-60, 0, 30)],
                        normals: Array(repeating: .init(0, 1, 0), count: 4), indices: [0, 2, 1, 0, 3, 2],
                        texcoords: [.init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)]), revision: 1)
                body.material = material.bodyMaterialSpec()
                document.session.perform(AddBodyCommand(body: body, title: "Synthetic texture panel"))
                guard let library = CADMaterialLibraryCodec.encode(CADMaterialLibrary(entries: [material])) else {
                    throw failure("The initial document material could not be encoded.")
                }
                document.session.perform(SetMaterialLibraryDataCommand(before: nil, after: library))
                let saved = await document.save()
                guard saved.succeeded else { throw failure(saved.error ?? "The initial document could not be saved.") }
            } catch { document.close(); throw error }
        }
        guard let body = document.session.document.bodies.first(where: { $0.name == bodyName }) else {
            document.close(); throw failure("The real saved panel is missing.")
        }
        let editor = document.viewModel()
        editor.selection = [body.id]
        // The existing editor presents its existing material inspector. The
        // hook below supplies starting input only; all choices remain UI work.
        editor.showMaterialSheet = !reopen
        return document
    }

    /// Called only by the inspector's DEBUG onAppear hook. No conversion,
    /// acceptance, Apply, undo or save is executed here. Each real draft owner
    /// gets one starting batch, so cancelling does not immediately re-arm it.
    static func stageIfRequested(_ model: CADMaterialDraftModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(argument), !arguments.contains(reopenArgument),
              let root = try? fixtureRoot(),
              model.document.url.standardizedFileURL == root.appendingPathComponent("texture-import.floecad").standardizedFileURL,
              !model.document.isClosed,
              model.document.session.document.bodies.first(where: { $0.name == bodyName })?.material?.hasAnyTexture == false else { return }
        stagedOwners = stagedOwners.filter { $0.value.value != nil }
        let owner = ObjectIdentifier(model)
        guard stagedOwners[owner]?.value !== model else { return }
        stagedOwners[owner] = WeakDraft(model)
        do {
            let library = CADMaterialLibraryCodec.decode(model.document.session.document.materialLibraryData)
            guard let entry = library.entries.first else { throw failure("The real document material is missing.") }
            // The starting document copy keeps Apply within this fixture's
            // document library; it never adds synthetic data to My Materials.
            model.select(entry, origin: .document(entry.id))
            let sources = try CADTextureImport.readFiles(sourceNames.map { root.appendingPathComponent($0) })
            let token = model.beginTextureImport()
            model.stageTextureImport(sources, startingAt: .baseColor, token: token)
        } catch { model.setExternalError(error.localizedDescription) }
    }

    static func readback(_ document: FloeCADDocument) -> String {
        do {
            guard !document.isClosed,
                  let body = document.session.document.bodies.first(where: { $0.name == bodyName }),
                  let material = body.material else { throw failure("The live material is missing.") }
            let library = CADMaterialLibraryCodec.decode(document.session.document.materialLibraryData)
            let entry = material.materialID.flatMap(UUID.init(uuidString:)).flatMap { library.entry(MaterialID(raw: $0)) }
            let sources = try sourcesUnchanged()
            let undo = document.session.undoStack.undoCommands.count
            let redo = document.session.undoStack.redoCommands.count
            guard let color = material.baseColorTexture, let normal = material.normalTexture else {
                let empty = !material.hasAnyTexture
                return "state=\(empty ? "empty" : "partial")|base=none|normal=none|sources=\(sources ? "unchanged" : "changed")|undo=\(undo)|redo=\(redo)|document=texture-import.floecad"
            }
            let c = try probe(color, expected: colorPixels), n = try probe(normal, expected: normalPixels)
            let metadata = material.verifiedTextureMetadata(for: .baseColor)?.colorSpace == .srgb
                && material.verifiedTextureMetadata(for: .normal)?.colorSpace == .linear
                && material.textureOrientation(for: .baseColor) == .topLeft
                && material.textureOrientation(for: .normal) == .topLeft
            let stored = entry?.texture(for: .baseColor)?.bytes == color
                && entry?.texture(for: .normal)?.bytes == normal
            return "state=applied|base=\(c.width)x\(c.height)|normal=\(n.width)x\(n.height)|colors=\(c.matches ? "match" : "mismatch")|data=\(n.matches ? "match" : "mismatch")|alpha=\(c.alpha)/\(n.alpha)|metadata=\(metadata ? "verified" : "mismatch")|library=\(stored ? "match" : "mismatch")|sources=\(sources ? "unchanged" : "changed")|undo=\(undo)|redo=\(redo)|document=texture-import.floecad"
        } catch { return "readback_error=\(error.localizedDescription)" }
    }

    private static func fixtureRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/CADFixtures/TextureImport", isDirectory: true)
    }

    private static func sourcesUnchanged() throws -> Bool {
        let root = try fixtureRoot()
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("sources.json")))
        return try sourceNames.allSatisfy { name in
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            return manifest[name] == CADMaterialTexture.digest(bytes)
        }
    }

    private static func pattern(_ colors: [[UInt8]]) throws -> Data {
        let width = 4096, height = 2048
        func row(_ a: [UInt8], _ b: [UInt8]) -> Data {
            Data(Array(repeating: a, count: width / 2).flatMap { $0 }
                + Array(repeating: b, count: width / 2).flatMap { $0 })
        }
        let upper = row(colors[0], colors[1]), lower = row(colors[2], colors[3])
        var rgba = Data(capacity: width * height * 4)
        for y in 0..<height { rgba.append(y < height / 2 ? upper : lower) }
        guard let provider = CGDataProvider(data: rgba as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw failure("The synthetic pixel image could not be made.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw failure("The synthetic PNG encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("The synthetic PNG did not encode.") }
        return data as Data
    }

    /// Read the pixels of the actual encoded material bytes, independently of
    /// the import service's prepared receipts and preview thumbnails.
    private static func probe(_ bytes: Data, expected: [[UInt8]]) throws -> (width: Int, height: Int, matches: Bool, alpha: Int) {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw failure("The saved texture could not be decoded.") }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var drew = false
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drew = true
        }
        guard drew else { throw failure("The saved texture pixels could not be sampled.") }
        var matches = true, bottomAlpha = -1
        for quadrant in 0..<4 {
            let x = width * (quadrant % 2 == 0 ? 1 : 3) / 4
            let y = height * (quadrant < 2 ? 1 : 3) / 4
            let offset = (y * width + x) * 4
            let alpha = Int(rgba[offset + 3])
            if quadrant == 2 { bottomAlpha = alpha }
            for channel in 0..<4 {
                let actual = channel == 3 ? alpha
                    : (alpha == 0 ? 0 : min(255, (Int(rgba[offset + channel]) * 255 + alpha / 2) / alpha))
                matches = matches && abs(actual - Int(expected[quadrant][channel])) <= 3
            }
        }
        return (width, height, matches, bottomAlpha)
    }

    private static func failure(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "texture_import_ui_fixture", message: message)
    }
}

/// No fixture control performs edits. This panel observes the real session;
/// after process relaunch the same code decodes the newly opened package.
public struct CADTextureImportReadbackPanel: View {
    let document: FloeCADDocument
    @State private var report = "reading"
    public init(document: FloeCADDocument) { self.document = document }
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            Text(report).font(.system(size: 9, design: .monospaced))
                .lineLimit(5).frame(maxWidth: 400, alignment: .leading)
                .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(report).accessibilityIdentifier("CADTextureImportState")
                .allowsHitTesting(false)
                .task(id: document.liveChangeCount) { report = CADTextureImportUIFixture.readback(document) }
        }
    }
}
#endif
