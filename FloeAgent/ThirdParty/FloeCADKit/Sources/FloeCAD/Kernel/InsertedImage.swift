//
//  InsertedImage.swift
//  openshape3d
//
//  Insert Image (plan §B10): a reference picture pinned to a plane — sized in
//  model units (mm), with Items-Manager opacity/visibility. Tracing and
//  splitting-tool aid. Pure data; the viewport samples `imageData` into a
//  textured quad.
//

import Foundation
import simd

nonisolated struct InsertedImageID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

nonisolated struct InsertedImage: Identifiable, Codable, Equatable, Sendable {
    let id: InsertedImageID
    var name: String
    /// Plane the quad lies on. The image is centered on the plane origin and
    /// spans ±width/2 along xAxis, ±height/2 along yAxis.
    var plane: SketchPlane
    /// Quad size in model units (mm).
    var width: Double
    var height: Double
    /// 0 (invisible) … 1 (opaque); clamped on init.
    var opacity: Double
    /// Items Manager visibility (spec §11).
    var isHidden: Bool
    /// Original PNG/JPEG bytes exactly as picked (decoded lazily for display).
    var imageData: Data

    init(
        id: InsertedImageID = InsertedImageID(),
        name: String = "Image",
        plane: SketchPlane,
        width: Double,
        height: Double,
        opacity: Double = 1,
        isHidden: Bool = false,
        imageData: Data
    ) {
        self.id = id
        self.name = name
        self.plane = plane
        self.width = width
        self.height = height
        self.opacity = min(max(opacity, 0), 1)
        self.isHidden = isHidden
        self.imageData = imageData
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, plane, width, height, opacity, isHidden, imageData
    }

    /// Everything but the geometric core is optional on decode so trimmed
    /// payloads (persistence stores the blob out-of-line) and future field
    /// additions stay loadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(InsertedImageID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Image"
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData) ?? Data()
    }
}
