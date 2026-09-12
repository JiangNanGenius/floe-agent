import SwiftUI
import Testing
import VideoEditorKit

@MainActor
@Suite("VideoExportSheetModifierCompileTests")
struct VideoExportSheetModifierCompileTests {

    // MARK: - Public Methods

    @Test
    func publicBooleanExportSheetModifierCanBeComposed() {
        let request = VideoExportSheetRequest(
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )

        let view = Text("Export")
            .videoExportSheet(
                isPresented: .constant(false),
                request: request,
                onExported: { _ in }
            )

        #expect(Mirror(reflecting: view).children.isEmpty == false)
    }

    @Test
    func publicItemExportSheetModifierCanBeComposed() {
        let item = ExportProbeItem(
            id: UUID(),
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4")
        )

        let view = Text("Export")
            .videoExportSheet(
                item: .constant(Optional(item)),
                request: { item in
                    VideoExportSheetRequest(
                        id: item.id.uuidString,
                        sourceVideoURL: item.sourceVideoURL
                    )
                },
                onExported: { _, _ in }
            )

        #expect(Mirror(reflecting: view).children.isEmpty == false)
    }

}

private struct ExportProbeItem: Identifiable {

    // MARK: - Public Properties

    let id: UUID
    let sourceVideoURL: URL

}
