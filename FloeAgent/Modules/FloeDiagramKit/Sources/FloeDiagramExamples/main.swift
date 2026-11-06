// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramLayout
import FloeDiagramExchange

@main struct DiagramExamplesRunner {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Diagram examples failed: \(error)\n".utf8))
            exit(1)
        }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw DiagramError.invalid("usage: floe-diagram-examples ABSOLUTE_OUTPUT_DIRECTORY") }
        guard CommandLine.arguments[1].hasPrefix("/") else { throw DiagramError.invalid("absolute output directory required") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let original = DiagramExamples.library(), resources = InMemoryDiagramAssets([DiagramExamples.id(50): DiagramExamples.pixelPNG])
        var reports: [[String: Any]] = []
        for format in DiagramFormat.allCases {
            var input = original
            // XMind's topic subset needs a root topic on every sheet. The flow-only
            // review page is demonstrated by draw.io/native/PDF instead.
            if format == .xmind { input.pages = [original.pages[0],original.pages[2]] }
            let singlePage = [.freemind,.opml,.markdown,.mermaid,.svg,.png].contains(format)
            let pageID = singlePage ? input.pages[0].id : nil
            let output = try await DiagramExchange.export(input,format: format,pageID: pageID,assets: resources)
            let url = directory.appendingPathComponent("community-library."+format.fileExtension)
            try DiagramExchange.save(output,to: url)
            var record: [String: Any] = ["format": format.rawValue,"bytes": output.data.count,"sha256": DiagramCodec.digest(output.data),"exportedPageIDs": (pageID.map { [$0] } ?? input.pages.map(\.id)).map(\.uuidString),"issues": output.issues.map { ["code": $0.code,"detail": $0.detail] }]
            if format == .xmind { record["sampleScope"] = "Two topic sheets; the flow-only sheet uses native/draw.io/PDF artifacts." }
            if ![DiagramFormat.svg,.pdf,.png].contains(format) {
                let imported = try DiagramExchange.importData(output.data,format: format)
                if format == .floemap, imported.document != original { throw DiagramError.invalid("native sample round trip changed the document") }
                record["reimportedPages"] = imported.document.pages.count
                record["reimportedElements"] = imported.document.pages.reduce(0) { $0+$1.elements.count }
                record["reimportValidated"] = true
            }
            reports.append(record)
        }
        for board in [true,false] {
            let projected = try DiagramPlanProjection.document(original,board: board)
            let result = try await DiagramExchange.export(projected,format: .pdf,assets: resources)
            try DiagramExchange.save(result,to: directory.appendingPathComponent(board ? "project-board.pdf" : "project-gantt.pdf"))
            let image = try await DiagramExchange.export(projected,format: .png,assets: resources)
            try DiagramExchange.save(image,to: directory.appendingPathComponent(board ? "project-board.png" : "project-gantt.png"))
        }
        var benchmarks: [[String: Any]] = []
        for (count,rich) in [(500,true),(10_000,false)] {
            let doc = DiagramExamples.large(count: count,rich: rich)
            var times: [Double] = [], visible = 0, encoded = 0, edges = 0
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                try doc.validate(); let layout = try DiagramLayoutEngine.layout(doc.pages[0])
                let focus = layout.frames[doc.pages[0].elements[0].id]!.center
                visible = layout.spatialIndex.query(.init(x: focus.x-500,y: focus.y-400,width: 1_000,height: 800)).count; edges = layout.edges.count
                let bytes = try DiagramCodec.encode(doc); encoded = bytes.count; _ = try DiagramCodec.decode(DiagramDocument.self,from: bytes)
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            benchmarks.append(["nodes": count,"rich": rich,"sharedFixtureAssetCount": doc.assets.count,"validateLayoutEncodeDecodeMilliseconds": times,"medianMilliseconds": times.sorted()[1],"visibleElementsIn1000x800": visible,"edges": edges,"jsonBytes": encoded,"processPeakRSSBytes": usage.ru_maxrss])
        }
        let report: [String: Any] = ["baseline": "49222ba1edd558645900a18909aa2c80aad13d5b","platform": ProcessInfo.processInfo.operatingSystemVersionString,"processorCount": ProcessInfo.processInfo.processorCount,"formatOutputs": reports,"benchmarks": benchmarks,"limits": "Host CPU/codec/layout measurements. These are not device frame-rate, physical Pencil or complete Floe App acceptance."]
        try DiagramAtomicFile.write(JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]),to: directory.appendingPathComponent("report.json"))
        print("Created \(reports.count) format artifacts and \(benchmarks.count) benchmark records in \(directory.path)")
    }
}
