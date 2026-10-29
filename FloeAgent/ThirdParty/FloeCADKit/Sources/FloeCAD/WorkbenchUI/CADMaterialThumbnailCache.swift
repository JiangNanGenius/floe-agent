//
//  CADMaterialThumbnailCache.swift
//  FloeCADKit
//
//  Cached material swatches for library rows. The cache is shared by every
//  inspector instance; a row never owns a live GPU renderer or rebuilds a
//  preview during SwiftUI body evaluation. A swatch is derived from the real
//  material values (base colour, metallic, roughness, emission, colour map)
//  and is cached in memory plus a bounded on-disk cache keyed by the material
//  content. The actual 3D PBR preview lives in Present mode.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class CADMaterialThumbnailCache {
    static let shared = CADMaterialThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL?
    private let size = CGSize(width: 120, height: 120)

    init() {
        memory.countLimit = 256
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first
        directory = caches?
            .appendingPathComponent("FloeCAD", isDirectory: true)
            .appendingPathComponent("MaterialThumbnails", isDirectory: true)
    }

    func image(for definition: CADMaterialDefinition) -> UIImage? {
        let key = definition.cacheKey
        let cacheKey = key as NSString
        if let cached = memory.object(forKey: cacheKey) {
            return cached
        }
        if let directory {
            let url = directory.appendingPathComponent("\(key).png")
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                memory.setObject(image, forKey: cacheKey)
                return image
            }
        }
        guard let image = render(definition) else { return nil }
        memory.setObject(image, forKey: cacheKey)
        persist(image, key: key)
        return image
    }

    func clear() {
        memory.removeAllObjects()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Render

    private func render(_ definition: CADMaterialDefinition) -> UIImage? {
        let clean = definition.sanitized
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let texel = clean.texture(for: .baseColor).flatMap { UIImage(data: $0.bytes) }
        let base = UIColor(
            red: CGFloat(clean.baseColor.x), green: CGFloat(clean.baseColor.y),
            blue: CGFloat(clean.baseColor.z), alpha: 1)
        let emission = clean.emissiveStrength > 0
            ? UIColor(red: CGFloat(clean.emissive.x), green: CGFloat(clean.emissive.y),
                      blue: CGFloat(clean.emissive.z), alpha: 1)
            : .black
        let emissionAlpha = CGFloat(min(clean.emissiveStrength / 8, 1))
        return renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemBackground.setFill()
            UIBezierPath(roundedRect: bounds, cornerRadius: 14).fill()

            let sphere = bounds.insetBy(dx: 10, dy: 10)
            context.cgContext.saveGState()
            UIBezierPath(ovalIn: sphere).addClip()
            base.setFill()
            UIBezierPath(ovalIn: sphere).fill()
            if let texel {
                texel.draw(in: sphere, blendMode: .normal, alpha: 0.82)
            }
            // Emissive wash.
            emission.withAlphaComponent(emissionAlpha * 0.55).setFill()
            UIBezierPath(ovalIn: sphere).fill()

            // Diffuse shading: darker rim, lighter upper-left.
            let colors = [UIColor.white.withAlphaComponent(0.26).cgColor,
                          UIColor.clear.cgColor,
                          UIColor.black.withAlphaComponent(0.42).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray,
                                         locations: [0, 0.55, 1]) {
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: sphere.midX - sphere.width * 0.22,
                                         y: sphere.midY - sphere.height * 0.24),
                    startRadius: 1,
                    endCenter: CGPoint(x: sphere.midX, y: sphere.midY),
                    endRadius: sphere.width * 0.75,
                    options: [])
            }

            // A metallic surface reads as a tighter, brighter highlight; a
            // rough dielectric gets a broad soft one.
            let tightness = 1 - CGFloat(clean.roughness) * 0.75
            let highlightRadius = sphere.width * (0.10 + 0.14 * (1 - tightness))
            let highlightCenter = CGPoint(x: sphere.midX - sphere.width * 0.20,
                                          y: sphere.midY - sphere.height * 0.22)
            let highlight = UIColor.white.withAlphaComponent(
                0.30 + 0.45 * CGFloat(clean.metallic) + 0.20 * tightness)
            highlight.setFill()
            UIBezierPath(ovalIn: CGRect(
                x: highlightCenter.x - highlightRadius,
                y: highlightCenter.y - highlightRadius * 0.7,
                width: highlightRadius * 2,
                height: highlightRadius * 1.45)).fill()
            context.cgContext.restoreGState()

            UIBezierPath(ovalIn: sphere).lineWidth = 1
            UIColor.separator.withAlphaComponent(0.5).setStroke()
            UIBezierPath(ovalIn: sphere).stroke()
        }
    }

    private func persist(_ image: UIImage, key: String) {
        guard let directory, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(key).png")
        try? data.write(to: url, options: .atomic)
        pruneDiskCache(directory)
    }

    /// Bounded on-disk cache: thumbnails are regenerable, so old files are
    /// removed once the directory grows past a small ceiling.
    private func pruneDiskCache(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]), files.count > 512 else { return }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l < r
        }
        for url in sorted.prefix(files.count - 384) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension CADMaterialDefinition {
    /// Content identity: the swatch must change when any visible property or
    /// image changes, and stay cached when only the name changes.
    var cacheKey: String {
        // Deterministic across launches: Swift's Hasher is randomly seeded, so
        // it must not key the on-disk thumbnail cache.
        var parts: [String] = [
            String(baseColor.x), String(baseColor.y), String(baseColor.z),
            String(baseColor.w), String(metallic), String(roughness),
            String(opacity), String(emissive.x), String(emissive.y),
            String(emissive.z), String(emissiveStrength),
        ]
        for texture in textures.sorted(by: { $0.slot.rawValue < $1.slot.rawValue }) {
            parts.append(texture.slot.rawValue)
            parts.append(texture.sha256)
        }
        let digest = CADMaterialTexture.digest(Data(parts.joined(separator: "|").utf8))
        return "mt-" + String(digest.prefix(32))
    }
}
#endif
