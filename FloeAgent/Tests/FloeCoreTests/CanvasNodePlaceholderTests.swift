import Testing
@testable import FloeCore

@Suite("Canvas node placeholders")
struct CanvasNodePlaceholderTests {
    @Test("Every native canvas kind can be created before external content exists")
    func everyKindHasAPlaceholder() {
        for (index, kind) in CanvasNodeKind.allCases.enumerated() {
            let node = CanvasNode.placeholder(
                kind: kind,
                position: CanvasPoint(x: 120, y: 240),
                zIndex: index
            )

            #expect(node.kind == kind)
            #expect(node.position == CanvasPoint(x: 120, y: 240))
            #expect(node.size.width > 0)
            #expect(node.size.height > 0)
            #expect(node.zIndex == index)
        }
    }

    @Test("Specialized placeholders carry only their native defaults")
    func specializedDefaults() {
        let shape = CanvasNode.placeholder(
            kind: .shape, position: CanvasPoint(x: 0, y: 0)
        )
        let scene = CanvasNode.placeholder(
            kind: .scene3D, position: CanvasPoint(x: 0, y: 0)
        )
        let media = CanvasNode.placeholder(
            kind: .image, position: CanvasPoint(x: 0, y: 0)
        )
        let generation = CanvasNode.placeholder(
            kind: .generationTask, position: CanvasPoint(x: 0, y: 0)
        )

        #expect(shape.shape == .roundedRectangle)
        #expect(scene.scene3D != nil)
        #expect(media.asset == nil)
        #expect(media.metadata["placeholder"] == "true")
        #expect(generation.generationJobID == nil)
        #expect(generation.metadata["placeholder"] == "true")
    }
}
