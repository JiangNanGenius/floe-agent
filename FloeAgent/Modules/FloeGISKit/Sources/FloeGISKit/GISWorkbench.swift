// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeHeavyEditorSupport
public enum GISWorkbench {
    public static var descriptor: HeavyEditorDescriptor {
        HeavyEditorDescriptor(kind: .gis, title: EditorText.t("地图编辑器", "Map Editor"), symbol: "map",
            resourceRoot: Bundle.module.url(forResource: "Web", withExtension: nil)!, projectExtension: "floegis",
            importExtensions: ["floegis", "geojson", "json", "csv", "gpx", "kml", "kmz", "zip", "shp", "dbf", "shx", "cpg", "prj", "png", "jpg", "jpeg", "webp", "pgw", "jgw", "tfw", "wld", "pngw", "jpgw", "gpkg", "tif", "tiff", "asc", "mbtiles"])
    }
    public static func makeDocument(title: String = EditorText.t("新地图", "New map"), id: UUID = UUID()) -> HeavyEditorDocument {
        HeavyEditorDocument(id: id, kind: .gis, title: title, content: .object([
            "title": .string(title), "crs": .string("EPSG:4326"), "layers": .array([]),
            "bookmarks": .array([]), "view": .object(["center": .array([.number(0), .number(20)]), "zoom": .number(2)]),
            "layout": .object(["title": .string(title), "paper": .string("A4"), "legend": .bool(true), "north": .bool(true), "scale": .bool(true)])
        ]))
    }
    @MainActor public static func open(directory: URL, documentID: UUID, owner: HeavyEditorOwner,
                                       hooks: HeavyEditorHostHooks) async throws -> HeavyEditorController {
        let store = try HeavyEditorProjectStore(directory: directory, documentID: documentID, kind: .gis)
        return try HeavyEditorController(descriptor: descriptor, document: await store.read(), store: store, owner: owner, hooks: hooks)
    }
}
@MainActor public struct GISEditorView: View {
    private let controller: HeavyEditorController
    private let onClose: () -> Void
    public init(controller: HeavyEditorController, onClose: @escaping () -> Void = {}) { self.controller = controller; self.onClose = onClose }
    public var body: some View {
        HeavyEditorView(controller: controller, onClose: onClose,
            outline: AnyView(GISNativeOutline(controller: controller)),
            canvasToolbar: AnyView(GISNativeCanvasToolbar(controller: controller)),
            inspector: AnyView(GISNativeInspector(controller: controller)),
            canvasContent: controller.presentation["ui"]["mode"].string == "table" ? AnyView(GISNativeAttributeTable(controller: controller)) : nil,
            bottomBar: AnyView(GISNativeStatusBar(controller: controller)))
    }
}
