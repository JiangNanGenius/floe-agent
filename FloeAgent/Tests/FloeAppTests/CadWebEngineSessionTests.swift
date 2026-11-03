// FloeAppTests — real WKWebView → cad-host → Worker → wasm smoke test.
//
// Covers the native bridge contract end to end: open, inspect (JSON string, not
// "[object Object]"), query, edit with a JSON-string request, undo, save bytes
// and the DXF projection. These paths cannot be proven by builder or tool
// tests alone.

#if canImport(UIKit)
import Foundation
import Compression
import WebKit
import SwiftUI
import Testing
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace
import FloeWorkbench

@Suite("CAD WKWebView worker bridge", .serialized)
@MainActor
struct CadWebEngineSessionTests {
    private func sampleDXF() throws -> Data {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        return data
    }

    private func object(_ json: String) throws -> [String: Any] {
        guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw FloeError.storageCorrupted("expected a JSON object from the CAD bridge")
        }
        return parsed
    }

    private func entityCount(_ session: CadWebEngineSession) async throws -> Int {
        let info = try object(try await session.inspect(offset: 0, limit: 1))
        return info["entityCount"] as? Int ?? -1
    }

    @Test func fullWorkerBridgeRoundTrip() async throws {
        let sample = try sampleDXF()
        let session = CadWebEngineSession()
        try await session.start()
        do {
            // open
            let opened = try object(try await session.open(bytes: sample, format: "dxf"))
            let base = opened["entityCount"] as? Int ?? 0
            #expect(base > 0, "sample drawing must parse with entities")
            #expect((opened["unit"] as? String)?.isEmpty == false)

            // inspect must be a JSON string, never "[object Object]".
            let inspected = try await session.inspect(offset: 0, limit: 5)
            #expect(inspected.hasPrefix("{"))
            #expect(inspected.contains("entityCount"))

            // query (JSON string passthrough must not be double-encoded)
            let layers = try await session.query(#"{"operation":"layers"}"#)
            #expect(layers.contains("layers"))

            // edit with a JSON-string request: the worker must hand the engine
            // a command object, not a JSON string literal.
            let edit = try object(try await session.edit(
                #"{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}"#))
            let created = edit["created"] as? [String] ?? []
            #expect(created.count == 1, "addLine must report one created handle")
            #expect(try await entityCount(session) == base + 1)

            // undo restores the pre-edit revision.
            try await session.undo()
            #expect(try await entityCount(session) == base)

            // save returns verified DXF bytes for this format.
            let saved = try await session.save()
            #expect(!saved.isEmpty)
            let savedHead = String(decoding: saved.prefix(256), as: UTF8.self)
            #expect(savedHead.contains("SECTION") || savedHead.hasPrefix("  0"))

            // DXF projection is a distinct worker operation (regression).
            let dxf = try await session.displayDXF()
            let dxfText = String(decoding: dxf, as: UTF8.self)
            #expect(dxfText.contains("SECTION"))
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    /// The exact E21 oblique OCS/bulge fixture crosses the real WebKit,
    /// Worker and newly bundled WASM boundary; no native-only stand-in.
    @Test func obliqueBulgeTrimOffsetUndoAndSameFormatReopen() async throws {
        let sample = Data("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1032\n9\n$HANDSEED\n5\nF100\n9\n$INSUNITS\n70\n0\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n5\nF010\n100\nAcDbEntity\n8\n0\n100\nAcDbPolyline\n90\n4\n70\n1\n38\n7\n210\n0\n220\n0.6\n230\n0.8\n10\n0\n20\n0\n42\n0\n91\n1\n10\n20\n20\n0\n42\n1\n91\n2\n10\n20\n20\n10\n42\n0\n91\n3\n10\n0\n20\n10\n42\n1\n91\n4\n0\nLINE\n5\nF011\n100\nAcDbEntity\n8\n0\n100\nAcDbLine\n10\n-10\n20\n16.2\n30\n-3.4\n11\n-10\n21\n-15.8\n31\n20.6\n0\nTEXT\n5\nF012\n100\nAcDbEntity\n8\n0\n100\nAcDbText\n10\n70\n20\n80\n30\n0\n40\n2.5\n1\nUntouched E21\n0\nENDSEC\n0\nEOF\n".utf8)
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func row(_ info: [String: Any], _ handle: String) throws -> [String: Any] {
            let entities = try #require(info["entities"] as? [[String: Any]])
            return try #require(entities.first { $0["handle"] as? String == handle })
        }
        func polyline(_ row: [String: Any]) throws -> [String: Any] {
            let entity = try #require(row["entity"] as? [String: Any])
            return try #require(entity["LwPolyline"] as? [String: Any])
        }
        func check(_ value: [String: Any], closed: Bool, points: [[Double]], bulges: [Double], ids: [Int]) throws {
            #expect(value["is_closed"] as? Bool == closed)
            #expect(value["elevation"] as? Double == 7)
            let normal = try #require(value["normal"] as? [String: Any])
            #expect(normal["x"] as? Double == 0)
            #expect(normal["y"] as? Double == 0.6)
            #expect(normal["z"] as? Double == 0.8)
            let vertices = try #require(value["vertices"] as? [[String: Any]])
            #expect(vertices.count == points.count)
            for (index, vertex) in vertices.enumerated() where points.indices.contains(index) {
                let location = try #require(vertex["location"] as? [String: Any])
                let x = try #require(location["x"] as? Double), y = try #require(location["y"] as? Double)
                let bulge = try #require(vertex["bulge"] as? Double)
                #expect(abs(x - points[index][0]) < 1e-8)
                #expect(abs(y - points[index][1]) < 1e-8)
                #expect(abs(bulge - bulges[index]) < 1e-8)
                #expect(vertex["vertex_id"] as? Int == ids[index])
            }
        }
        let session = CadWebEngineSession()
        try await session.start()
        let saved: Data, trimmed: Data
        do {
            _ = try await session.open(bytes: sample, format: "dxf")
            let before = try object(try await session.inspect(offset: 0, limit: 20))
            let original = try canonical(row(before, "F010"))
            let untouched = try canonical(row(before, "F012"))
            let receipt = try object(try await session.edit(
                #"{"operation":"offset","handle":"F010","distance":2,"side":[-30,0.2,8.6]}"#))
            let handle = try #require((receipt["created"] as? [String])?.first)
            let offset = try object(try await session.inspect(offset: 0, limit: 20))
            try check(polyline(row(offset, handle)), closed: true,
                points: [[0,-2],[20,-2],[20,12],[0,12]], bulges: [0,1,0,1], ids: [1,2,3,4])
            #expect(try canonical(row(offset, "F010")) == original)
            #expect(try canonical(row(offset, "F012")) == untouched)
            try await session.undo()
            #expect(try await entityCount(session) == 3)
            try await session.redo()
            #expect(try await entityCount(session) == 4)
            try await session.undo()
            _ = try await session.edit(
                #"{"operation":"trim","handle":"F010","boundary":"F011","pick":[-25,0.2,8.6]}"#)
            let after = try object(try await session.inspect(offset: 0, limit: 20))
            try check(polyline(row(after, "F010")), closed: false,
                points: [[10,10],[0,10],[0,0],[10,0]], bulges: [0,1,0,0], ids: [5,4,1,6])
            #expect(try canonical(row(after, "F012")) == untouched)
            trimmed = try canonical(row(after, "F010"))
            try await session.undo()
            let undone = try object(try await session.inspect(offset: 0, limit: 20))
            #expect(try canonical(row(undone, "F010")) == original)
            try await session.redo()
            saved = try await session.save()
            #expect(!saved.isEmpty)
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
        let reopened = CadWebEngineSession()
        try await reopened.start()
        do {
            _ = try await reopened.open(bytes: saved, format: "dxf")
            let restored = try object(try await reopened.inspect(offset: 0, limit: 20))
            #expect(try canonical(row(restored, "F010")) == trimmed)
            #expect(try await entityCount(reopened) == 3)
        } catch {
            await reopened.shutdown()
            throw error
        }
        await reopened.shutdown()
    }


    /// E22: actual App WKWebView -> real worker -> bundled WASM, followed by
    /// the production DxfViewer/dxf-worker/font path and target-only pixels.
    @Test func existingDimensionAssociationDisplayUndoSaveAndReopen() async throws {
        // Exact MPL-2.0 synthetic engine fixture, raw DEFLATE (RFC1951), not a
        // new App resource. Apple COMPRESSION_ZLIB uses raw DEFLATE.
        let packed = try #require(Data(base64Encoded: """
            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
            """, options: .ignoreUnknownCharacters))
        var unpacked = [UInt8](repeating: 0, count: 47686)
        let decodedCount = packed.withUnsafeBytes { source in
            unpacked.withUnsafeMutableBytes { destination in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        #expect(decodedCount == unpacked.count)
        let sample = Data(unpacked)
        #expect(FloeDigest.sha256Hex(sample) == "a17130feada22a1243a97632adc9fd03762f7ca54462c3e084927b89740d959f")
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func row(_ info: [String: Any], _ handle: String) throws -> [String: Any] {
            try #require((info["entities"] as? [[String: Any]])?.first { $0["handle"] as? String == handle })
        }
        func records(_ bytes: Data) -> [[[String]]] {
            var result: [[[String]]] = [], current: [[String]] = []
            // Split LF and trim tags so both LF and CRLF fixtures stay paired.
            let raw = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
            for index in stride(from: 0, to: raw.count - 1, by: 2) {
                let pair = [raw[index].trimmingCharacters(in: .whitespacesAndNewlines),
                            raw[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)]
                if pair[0] == "0", !current.isEmpty { result.append(current); current = [] }
                current.append(pair)
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        func record(_ bytes: Data, _ type: String, _ handle: String) throws -> [[String]] {
            try #require(records(bytes).first { $0.first == ["0", type] && $0.contains(["5", handle]) })
        }
        func number(_ tags: [[String]], _ code: String, occurrence: Int = 0) throws -> Double {
            let field = try #require(tags.filter { $0[0] == code }.dropFirst(occurrence).first)
            return try #require(Double(field[1]))
        }
        func alignedSource(_ bytes: Data) -> Data {
            // Same exact synthetic fixture, changing only the native dimension
            // discriminant/subclass. Its native DIMASSOC handles stay intact.
            let tags = records(bytes).flatMap { record -> [[String]] in
                guard record.first == ["0","DIMENSION"], record.contains(["5","31"]) else { return record }
                return record.filter { $0 != ["100","AcDbRotatedDimension"] }.map {
                    $0[0] == "70" ? ["70","1"] : $0
                }
            }.flatMap { $0 }
            return Data((tags.joined(separator: "\n") + "\n").utf8)
        }
        func checkProjection(_ bytes: Data, length: Double, kind: String) throws {
            let dimension = try record(bytes, "DIMENSION", "31")
            #expect(dimension.contains(["1", "Length <> mm"]))
            #expect(Int(try number(dimension, "70")) & 15 == (kind == "Aligned" ? 1 : 0))
            #expect(!dimension.contains { $0[0] == "2" }, "stale anonymous display-cache reference must be absent")
            #expect(abs(try number(dimension, "14") - length) < 1e-8)
            #expect(abs(try number(dimension, "42") - length) < 1e-8)
            #expect(try number(dimension, "10") == 0 && number(dimension, "20") == 7)
            #expect(try number(dimension, "11") == 12 && number(dimension, "21") == 13)
            #expect(abs(try number(dimension, "53") - 15) < 1e-8)
            #expect(Int(try number(dimension, "70")) & 128 == 128)
            let association = try record(bytes, "DIMASSOC", "32")
            #expect(association.filter { $0[0] == "330" }.map { $0[1] } == ["31", "31"])
            #expect(try number(association, "90") == 3)
            #expect(association.filter { $0[0] == "331" }.map { $0[1] } == ["30", "30"])
            #expect(try number(association, "10") == 0)
            #expect(abs(try number(association, "10", occurrence: 1) - length) < 1e-8)
        }

        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
            throw FloeError.notFound("EngineeringViewers")
        }
        // A small, visible, non-key window on the UNIQUE active test App scene
        // gives WebGL requestAnimationFrame a real display. No global firstWindow.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard scenes.count == 1, let scene = scenes.first else {
            throw FloeError.invalidConfiguration("E22 render witness requires one active App test scene")
        }
        let (renderServer, renderPage) = try await LocalPreviewServer.start(root: bundleRoot, entry: "cad-host.html")
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let renderWeb = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        controller.view.addSubview(renderWeb)
        window.isHidden = false
        defer {
            renderWeb.stopLoading()
            renderWeb.loadHTMLString("", baseURL: nil)
            renderWeb.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            renderServer.stop()
        }
        renderWeb.load(URLRequest(url: renderPage.url))
        var pageReady = false
        for _ in 0..<100 {
            let ready = try? await renderWeb.evaluateJavaScript("document.readyState === 'complete' && typeof window.floeCadHostReady === 'function'")
            if ready as? Bool == true { pageReady = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard pageReady else { throw FloeError.internalError("E22 renderer cad-host did not finish loading") }
        func renderWitness(_ bytes: Data, name: String, length: Double, kind: String) async throws -> (png: Data, textPixels: Int) {
            let value = try await renderWeb.callAsyncJavaScript(#"""
            let timer;
            const work = (async () => {
              await window.floeCadHostReady();
              const {DxfViewer,Color} = await import('./dxf.js');
              const {worldToScreen} = await import('./cad-ink.js');
              const surface = document.createElement('div');
              surface.style.cssText='width:640px;height:480px';document.body.append(surface);
              const viewer = new DxfViewer(surface,{autoResize:false,canvasWidth:640,canvasHeight:480,
                retainParsedDxf:true,preserveDrawingBuffer:true,clearColor:new Color('#ffffff'),colorCorrection:true});
              let url;
              try {
                let loaded=false;viewer.Subscribe('loaded',()=>{loaded=true;});
                const binary=atob(bytes),data=Uint8Array.from(binary,c=>c.charCodeAt(0));
                url=URL.createObjectURL(new Blob([data]));
                await viewer.Load({url,fonts:[new URL('MiSans-Regular.ttf',location.href).href],
                  workerFactory:()=>new Worker(new URL('dxf-worker.js',location.href),{type:'module'})});
                if(!loaded)throw Error('Real DxfViewer loaded event did not arrive');
                const layer=viewer.layers.get('FLOE_QA_SOURCE_CONTROL');
                if(!layer||!layer.objects.length)throw Error('Source-line control layer is missing');
                viewer.ShowLayer('FLOE_QA_SOURCE_CONTROL',false);
                if(layer.objects.some(object=>object.visible))throw Error('Source line still contributes pixels');
                const origin=viewer.GetOrigin();viewer.SetView({x:12.5-origin.x,y:6.5-origin.y},35);
                await new Promise(resolve=>requestAnimationFrame(()=>{viewer.Render();requestAnimationFrame(resolve);}));
                viewer.GetRenderer().getContext().finish();
                const canvas=viewer.GetCanvas(),copy=document.createElement('canvas');
                copy.width=canvas.width;copy.height=canvas.height;
                const context=copy.getContext('2d');context.drawImage(canvas,0,0);
                const pixels=context.getImageData(0,0,copy.width,copy.height).data;
                const ink=(x,y)=>{const i=(y*copy.width+x)*4;return pixels[i+3]>0&&Math.min(pixels[i],pixels[i+1],pixels[i+2])<240;};
                let inkPixels=0;for(let y=0;y<copy.height;y++)for(let x=0;x<copy.width;x++)if(ink(x,y))inkPixels++;
                const view={camera:viewer.GetCamera(),origin,canvasWidth:copy.width,canvasHeight:copy.height};
                const p=worldToScreen({x:7,y:14.5},view),q=worldToScreen({x:17,y:11.5},view);
                let textPixels=0;for(let y=Math.max(0,Math.floor(p.y));y<Math.min(copy.height,Math.ceil(q.y));y++)
                  for(let x=Math.max(0,Math.floor(p.x));x<Math.min(copy.width,Math.ceil(q.x));x++)if(ink(x,y))textPixels++;
                const dimensions=viewer.GetDxf().entities.filter(e=>e.type==='DIMENSION');
                if(dimensions.length!==1)throw Error('Expected one rendered native dimension');
                return JSON.stringify({renderer:'bundled-dxf-viewer',loaded,hiddenSourceObjects:layer.objects.length,
                  renderCalls:viewer.GetRenderer().info.render.calls,width:copy.width,height:copy.height,
                  inkPixels,textPixels,dimension:dimensions[0],pngBase64:canvas.toDataURL('image/png').split(',')[1]});
              } finally {if(url)URL.revokeObjectURL(url);viewer.Destroy();surface.remove();}
            })();
            try{return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('E22 real render timeout')),30000);})]);}
            finally{clearTimeout(timer);}
            """#, arguments: ["bytes": bytes.base64EncodedString()], in: nil, contentWorld: .page)
            let json = try #require(value as? String)
            var witness = try object(json)
            #expect(witness["loaded"] as? Bool == true)
            let dimension = try #require(witness["dimension"] as? [String: Any])
            #expect(dimension["handle"] as? String == "31")
            #expect((dimension["dimensionType"] as? Int ?? -1) & 15 == (kind == "Aligned" ? 1 : 0))
            let endpoint = try #require(dimension["linearOrAngularPoint2"] as? [String: Any])
            #expect(abs((endpoint["x"] as? Double ?? .nan) - length) < 1e-8)
            if length > 10 {
                #expect(dimension["text"] as? String == "Length <> mm")
                let anchor = try #require(dimension["middleOfText"] as? [String: Any])
                #expect(anchor["x"] as? Double == 12 && anchor["y"] as? Double == 13)
                #expect(dimension["block"] == nil)
            }
            #expect((witness["hiddenSourceObjects"] as? Int ?? 0) > 0)
            #expect((witness["renderCalls"] as? Int ?? 0) > 0)
            #expect((witness["inkPixels"] as? Int ?? 0) > 32, "the original dimension itself must draw nonblank pixels")
            let pngBase64 = try #require(witness["pngBase64"] as? String)
            let png = try #require(Data(base64Encoded: pngBase64))
            #expect(png.starts(with: [137,80,78,71,13,10,26,10]))
            witness.removeValue(forKey: "pngBase64")
            witness["sourceDXFSHA256"] = FloeDigest.sha256Hex(bytes)
            witness["pngSHA256"] = FloeDigest.sha256Hex(png)
            Attachment.record(Array(png), named: "e22-\(name).png")
            Attachment.record(String(decoding: try canonical(witness), as: UTF8.self), named: "e22-\(name).json")
            return (png, witness["textPixels"] as? Int ?? -1)
        }

        for (kind, source) in [("Linear", sample), ("Aligned", alignedSource(sample))] {
        let session = CadWebEngineSession(), reopened = CadWebEngineSession()
        try await session.start()
        do {
            _ = try await session.open(bytes: source, format: "dxf")
            // Hide only the source LINE in the actual renderer so its moved
            // pixels cannot masquerade as a changed dimension.
            _ = try await session.edit(#"{"operation":"batch","operations":[{"operation":"addLayer","name":"FLOE_QA_SOURCE_CONTROL"},{"operation":"setLayer","handle":"30","layer":"FLOE_QA_SOURCE_CONTROL"}]}"#)
            let original = try object(try await session.inspect(offset: 0, limit: 20))
            let dimensionRow = try row(original,"31")
            #expect(dimensionRow["operations"] as? [String] == ["updateDimension"])
            let image = try #require(dimensionRow["entity"] as? [String: Any])
            let subtype = try #require(image["Dimension"] as? [String: Any])
            #expect(subtype[kind] != nil)
            let beforeDXF = try await session.displayDXF()
            let before = try await renderWitness(beforeDXF, name: "\(kind)-before", length: 10, kind: kind)
            #expect(before.textPixels == 0, "new text ROI is empty in the nonblank original dimension image")
            _ = try await session.edit(#"{"operation":"batch","operations":[{"operation":"setLineEndpoints","handle":"30","start":[0,0,0],"end":[25,0,0]},{"operation":"updateDimension","handle":"31","text":"Length <> mm","textPosition":[12,13,0],"linePosition":[0,7,0],"textRotationDegrees":15}]}"#)
            let changed = try object(try await session.inspect(offset: 0, limit: 20))
            let display = try await session.displayDXF()
            try checkProjection(display, length: 25, kind: kind)
            let changedRender = try await renderWitness(display, name: "\(kind)-changed", length: 25, kind: kind)
            #expect(changedRender.png != before.png)
            #expect(changedRender.textPixels > 4, "actual dimension text must occupy its new world-space ROI")
            try await session.undo()
            let undone = try object(try await session.inspect(offset: 0, limit: 20))
            #expect(try canonical(row(undone,"30")) == canonical(row(original,"30")))
            #expect(try canonical(row(undone,"31")) == canonical(row(original,"31")))
            let undoRender = try await renderWitness(try await session.displayDXF(), name: "\(kind)-undone", length: 10, kind: kind)
            #expect(undoRender.textPixels == 0)
            try await session.redo()
            let saved = try await session.save()
            try checkProjection(saved, length: 25, kind: kind)
            await session.shutdown()
            try await reopened.start()
            _ = try await reopened.open(bytes: saved, format: "dxf")
            let restored = try object(try await reopened.inspect(offset: 0, limit: 20))
            #expect(try canonical(row(restored,"31")) == canonical(row(changed,"31")))
            try checkProjection(try await reopened.displayDXF(), length: 25, kind: kind)
            let reopenedRender = try await renderWitness(try await reopened.displayDXF(), name: "\(kind)-reopened", length: 25, kind: kind)
            #expect(reopenedRender.textPixels > 4)
            // A second geometry edit after reopen proves the native relation
            // still works; it is not a detached one-shot text replacement.
            _ = try await reopened.edit(#"{"operation":"setLineEndpoints","handle":"30","start":[0,0,0],"end":[30,0,0]}"#)
            try checkProjection(try await reopened.save(), length: 30, kind: kind)
        } catch {
            await session.shutdown(); await reopened.shutdown()
            throw error
        }
        await session.shutdown(); await reopened.shutdown()
        }
        _ = try? await renderWeb.callAsyncJavaScript("return await window.floeCadHostCall('shutdown', {});", arguments: [:], in: nil, contentWorld: .page)
    }

    /// E20: preserve unsupported mixed content and actual native DXF records,
    /// while exposing read-only reasons through the real App worker bridge.
    @Test func mixedDrawingReadonlyMetadataAndSameFormatPreservation() async throws {
        let packed = try #require(Data(base64Encoded: """
            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
            jKh8/0O8AlmIu5erby9L/V/uxrEHB9ool/8D
            """, options: .ignoreUnknownCharacters))
        var unpacked = [UInt8](repeating: 0, count: 48864)
        let decodedCount = packed.withUnsafeBytes { source in
            unpacked.withUnsafeMutableBytes { destination in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        #expect(decodedCount == unpacked.count)
        let sample = Data(unpacked)
        #expect(FloeDigest.sha256Hex(sample) == "14817e7bd178bd73ef0e0bc0d71af659530e66cf0744a87deb97a4a5a2a44355")
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func rows(_ info: [String: Any]) throws -> [[String: Any]] {
            try #require(info["entities"] as? [[String: Any]])
        }
        func protectedRecords(_ bytes: Data) -> [[[String]]] {
            let raw = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
            var records: [[[String]]] = [], current: [[String]] = []
            for index in stride(from: 0, to: raw.count - 1, by: 2) {
                let pair = [raw[index].trimmingCharacters(in: .whitespacesAndNewlines),
                            raw[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)]
                if pair[0] == "0", !current.isEmpty { records.append(current); current = [] }
                current.append(pair)
            }
            if !current.isEmpty { records.append(current) }
            return records.filter { record in
                ["SPLINE","HATCH","INSERT","BLOCK","ENDBLK"].contains(record.first?[1] ?? "")
            }
        }
        let session = CadWebEngineSession(), reopened = CadWebEngineSession()
        try await session.start()
        do {
            let opened = try object(try await session.open(bytes: sample, format: "dxf"))
            let originalRows = try rows(opened)
            #expect(originalRows.count == opened["entityCount"] as? Int)
            for type in ["Spline","Hatch","Insert"] {
                let matches = originalRows.filter { ($0["entity"] as? [String: Any])?[type] != nil }
                #expect(!matches.isEmpty)
                for row in matches {
                    #expect(row["editable"] as? Bool == false)
                    #expect(row["operations"] as? [String] == [])
                    #expect((row["readOnlyReason"] as? String)?.isEmpty == false)
                }
            }
            let readonly = originalRows.filter { $0["editable"] as? Bool == false }
            #expect(readonly.contains { $0["readOnlyReason"] as? String == "layoutOrBlock" }, "block-owned LINE stays read only")
            let before = protectedRecords(try await session.displayDXF())
            let xref = try #require(before.first { $0.first == ["0","BLOCK"] && $0.contains(["2","EXTERNAL_REFERENCE"]) })
            #expect(xref.contains(["70","4"]))
            #expect(xref.contains(["1","external-reference.dwg"]))
            #expect(before.contains { $0.first == ["0","BLOCK"] && $0.contains(["2","DRAWING_BLOCK"]) })
            let line = try #require(originalRows.first { $0["editable"] as? Bool == true && ($0["entity"] as? [String: Any])?["Line"] != nil })
            let handle = try #require(line["handle"] as? String)
            let edit = try JSONSerialization.data(withJSONObject: ["operation":"move","handle":handle,"delta":[1,2,0]])
            _ = try await session.edit(String(decoding: edit, as: UTF8.self))
            let after = try rows(object(try await session.inspect(offset: 0, limit: 100)))
            for original in readonly {
                let preserved = try #require(after.first { $0["handle"] as? String == original["handle"] as? String })
                #expect(try canonical(preserved) == canonical(original))
            }
            let moved = try #require(after.first { $0["handle"] as? String == handle })
            let body = try #require((moved["entity"] as? [String: Any])?["Line"] as? [String: Any])
            let start = try #require(body["start"] as? [String: Any])
            #expect(start["x"] as? Double == 1 && start["y"] as? Double == 2)
            #expect(protectedRecords(try await session.displayDXF()) == before)
            let saved = try await session.save()
            #expect(protectedRecords(saved) == before, "same-format save retains actual block/Xref/spline/hatch records")
            await session.shutdown()
            try await reopened.start()
            let restored = try object(try await reopened.open(bytes: saved, format: "dxf"))
            #expect(restored["format"] as? String == "dxf")
            #expect(restored["entityCount"] as? Int == opened["entityCount"] as? Int)
            let restoredRows = try rows(restored)
            for original in readonly {
                let preserved = try #require(restoredRows.first { $0["handle"] as? String == original["handle"] as? String })
                #expect(try canonical(preserved) == canonical(original))
            }
            #expect(protectedRecords(try await reopened.displayDXF()) == before)
        } catch {
            await session.shutdown(); await reopened.shutdown()
            throw error
        }
        await session.shutdown(); await reopened.shutdown()
    }

    @Test func queryRejectsDoubleEncodedRequest() async throws {
        let session = CadWebEngineSession()
        try await session.start()
        _ = try await session.open(bytes: try sampleDXF(), format: "dxf")
        await #expect(throws: (any Error).self) {
            _ = try await session.query("\"{\\\"operation\\\":\\\"layers\\\"}\"")
        }
        await session.shutdown()
    }

    /// A rejected engine promise currently loses its message at the WebKit
    /// boundary ("发生了JavaScript异常"). The host call must carry the real
    /// engine text so the model can repair the request instead of guessing.
    @Test func engineErrorsKeepTheirStructuredMessage() async throws {
        let session = CadWebEngineSession()
        try await session.start()
        do {
            _ = try await session.open(bytes: try sampleDXF(), format: "dxf")
            _ = try await session.query(#"{"operation":"measure","kind":"distance","handles":["1"]}"#)
            Issue.record("one handle must not satisfy a two-point/two-handle distance")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("two points or two handles"),
                    "engine message must survive the JS boundary, got: \(message)")
            #expect(!message.contains("JavaScript"),
                    "raw JavaScript exception leaked to the model: \(message)")
        }
        await session.shutdown()
    }
}
/// Real transaction serialization: two distinct grants at the same revision
/// must not both edit, and the same request id in flight must replay rather
/// than double-apply. These exercise the actual CadDocumentCenter gate against
/// the real engine + file CAS, not a string helper.
@Suite("CAD document transaction serialization", .serialized)
@MainActor
struct CadDocumentCenterConcurrencyTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let sample = try? Data(contentsOf: bundleRoot.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        try sample.write(to: root.appendingPathComponent("plan.dxf"))
        return root
    }

    private func access(_ root: URL) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                          ownerKind: "workspace", ownerID: nil)
    }

    private let addLineOperations =
        #"[{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}]"#

    @Test func distinctGrantsAtSameRevisionOnlyOneEdits() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant1 = await center.issueUserGrant(for: proposal)
        let grant2 = await center.issueUserGrant(for: proposal)
        #expect(grant1 != grant2)

        let successes = await withTaskGroup(of: Bool.self) { group in
            for (grant, request) in [(grant1, "req-a"), (grant2, "req-b")] {
                group.addTask {
                    do {
                        _ = try await center.apply(proposal: proposal, grantID: grant,
                                                   requestID: request, access: access)
                        return true
                    } catch { return false }
                }
            }
            var total = 0
            for await value in group where value { total += 1 }
            return total
        }
        #expect(successes == 1, "exactly one of two same-revision grants may edit")
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision > snapshot.revision)
        #expect(after.sha256 != snapshot.sha256)
    }

    @Test func sameRequestInFlightReplaysInsteadOfDoubleApplying() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let receipts = await withTaskGroup(of: CadDocumentReceipt?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await center.apply(proposal: proposal, grantID: grant,
                                            requestID: "same-request", access: access)
                }
            }
            var values: [CadDocumentReceipt] = []
            for await receipt in group { if let receipt { values.append(receipt) } }
            return values
        }
        #expect(receipts.count == 2, "both callers receive a result")
        #expect(receipts.filter { $0.replay }.count == 1, "the second call must be a replay")
        #expect(Set(receipts.map(\.revision)).count == 1)
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision == snapshot.revision + 1, "the document advanced exactly once")
    }

    /// The central live-draft guard: a dirty on-screen viewer blocks BOTH the
    /// confirmed UI apply and the tool save/apply path; the file is untouched
    /// and the draft stays in the viewer. A clean viewer no longer blocks, and
    /// the committed receipt is journaled for decision recovery.
    @Test func liveDirtyDraftBlocksApplyAndSave() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let documentURL = root.appendingPathComponent("plan.dxf")
        let before = try Data(contentsOf: documentURL)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let package = try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: before)
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        // A live dirty draft blocks the confirmed apply...
        session.coordinator?.dirty = true
        await #expect(throws: (any Error).self) {
            _ = try await center.apply(proposal: proposal, grantID: grant,
                                       requestID: "blocked-apply", access: access)
        }
        // ...and the tool save path, with the file byte-identical.
        await #expect(throws: (any Error).self) {
            _ = try await center.save(documentID: "plan.dxf", expectedSHA256: snapshot.sha256,
                                      requestID: "blocked-save", access: access)
        }
        #expect(FloeDigest.sha256Hex(try Data(contentsOf: documentURL)) == snapshot.sha256)

        // The same confirmed grant applies once the viewer is clean, and the
        // receipt is durably journaled for the decision outbox.
        session.coordinator?.dirty = false
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "applied", access: access)
        #expect(receipt.sha256 != snapshot.sha256)
        let journaled = await center.committedReceipt(proposalID: proposal.id, access: access)
        #expect(journaled?.sha256 == receipt.sha256)
        #expect(journaled?.revision == receipt.revision)
    }

    /// A manual edit landing during the engine transaction (simulated by the
    /// test seam right before the final commit boundary) aborts the commit,
    /// rolls the engine draft back, preserves the file and the user's draft,
    /// and restores viewer interaction. The proposal can then be retried.
    @Test func concurrentLiveEditAbortsCommitAndPreservesDraft() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let documentURL = root.appendingPathComponent("plan.dxf")
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let package = try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: try Data(contentsOf: documentURL))
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        // The user edits while the transaction is between edit and commit.
        await center.setTestHook({ await MainActor.run { [weak session] in
            session?.coordinator?.dirty = true
        } })
        await #expect(throws: (any Error).self) {
            _ = try await center.apply(proposal: proposal, grantID: grant,
                                       requestID: "interleaved", access: access)
        }
        await center.setTestHook(nil)
        // File untouched, interaction restored, and the engine draft rolled
        // back: the document still has its original entity count.
        #expect(FloeDigest.sha256Hex(try Data(contentsOf: documentURL)) == snapshot.sha256)
        #expect(session.web?.isUserInteractionEnabled == true)
        let afterRollback = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(afterRollback.revision == snapshot.revision)
        #expect(afterRollback.sha256 == snapshot.sha256)

        // Save/discard the manual edit, then the same proposal applies.
        session.coordinator?.dirty = false
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "retried", access: access)
        #expect(receipt.sha256 != snapshot.sha256)
    }

    /// The lease itself: dirty drafts refuse a lease, validation catches an
    /// edit that arrived after the lease, and ending the lease restores
    /// interaction.
    @Test func liveDraftLeaseSuspendsInteractionAndDetectsEdits() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try EngineeringPreviewPackage.single(
            name: "plan.dxf", bytes: try Data(contentsOf: root.appendingPathComponent("plan.dxf")))
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                           dark: false, locale: "en")
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        CadLiveDraftRegistry.shared.register(key: key, session: session)
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: session)
            session.tearDown()
        }

        let lease = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        #expect(session.web?.isUserInteractionEnabled == false)
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .clean)

        // An edit arriving after the lease invalidates it.
        session.coordinator?.dirty = true
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .dirty)
        CadLiveDraftRegistry.shared.endLease(lease)
        #expect(session.web?.isUserInteractionEnabled == true)

        // A dirty viewer cannot take a new lease at all.
        #expect(throws: (any Error).self) {
            _ = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        }
        session.coordinator?.dirty = false
    }

    /// The document-level lease survives a viewer replacement: a session that
    /// registers while a transaction is running starts suspended, and its dirty
    /// draft still aborts the commit instead of escaping through the old
    /// session reference.
    @Test func documentLeaseSuspendsReplacementViewer() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent("plan.dxf"))
        let key = CadLiveDraftRegistry.key(rootPath: root.path, relativePath: "plan.dxf")
        let first = EngineeringWebSession()
        _ = first.attach(package: try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: bytes),
                         error: Box<String?>(nil).binding, onReview: nil,
                         onSave: { _, _ in "sha" }, onDirty: nil, dark: false, locale: "en")
        CadLiveDraftRegistry.shared.register(key: key, session: first)
        defer { first.tearDown() }

        let lease = try CadLiveDraftRegistry.shared.beginLease(rootPath: root.path, relativePath: "plan.dxf")
        #expect(first.web?.isUserInteractionEnabled == false)

        // The viewer is replaced mid-transaction.
        CadLiveDraftRegistry.shared.unregister(key: key, session: first)
        let replacement = EngineeringWebSession()
        _ = replacement.attach(package: try EngineeringPreviewPackage.single(name: "plan.dxf", bytes: bytes),
                               error: Box<String?>(nil).binding, onReview: nil,
                               onSave: { _, _ in "sha" }, onDirty: nil, dark: false, locale: "en")
        defer {
            CadLiveDraftRegistry.shared.unregister(key: key, session: replacement)
            replacement.tearDown()
        }
        CadLiveDraftRegistry.shared.register(key: key, session: replacement)
        #expect(replacement.web?.isUserInteractionEnabled == false,
                "a replacement viewer must start suspended while the lease runs")

        // Its dirty draft is detected, not bypassed by the stale reference.
        replacement.coordinator?.dirty = true
        #expect(CadLiveDraftRegistry.shared.validateLease(lease) == .dirty)

        CadLiveDraftRegistry.shared.endLease(lease)
        #expect(replacement.web?.isUserInteractionEnabled == true)
    }

    /// A failed durable journal write never mutates the in-memory map.
    @Test func journalWriteFailureKeepsInMemoryStateUnchanged() async throws {
        let proposalID = UUID()
        let pending = CadDocumentReceipt(documentID: "plan.dxf", revision: 1,
                                         sha256: String(repeating: "a", count: 64),
                                         created: [], saved: false)
        let journal = CadAppliedReceiptJournal.shared
        journal.setTestWriteFailure(true)
        #expect(throws: (any Error).self) {
            try journal.prepare(proposalID: proposalID, expectedSHA256: pending.sha256,
                                pendingReceipt: pending)
        }
        #expect(journal.entry(proposalID: proposalID) == nil,
                "a failed write must not leave a phantom prepared entry")
        journal.setTestWriteFailure(false)
        try journal.prepare(proposalID: proposalID, expectedSHA256: pending.sha256,
                            pendingReceipt: pending)
        #expect(journal.entry(proposalID: proposalID)?.expectedSHA256 == pending.sha256)
    }

    /// Write-ahead recovery: an apply whose completion write was lost is
    /// reconstructed ONLY when the file currently has the prepared expected
    /// SHA; a different revision yields no applied receipt.
    @Test func preparedWriteAheadRecordReconcilesOnlyOnExactBytes() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)
        let intent = try DrawingAssistantDecisionStore.shared.record(
            conversationID: UUID(), proposalID: proposal.id, decision: "applied",
            revision: nil, sha256: nil, phase: .intent)
        let receipt = try await center.apply(proposal: proposal, grantID: grant,
                                             requestID: "commit", access: access)

        // Simulate the crash window: the prepared record exists, the completion
        // write never reached disk. A fresh center has no in-memory outcome and
        // must reconcile against the committed file SHA.
        let pending = CadDocumentReceipt(documentID: receipt.documentID,
                                         revision: receipt.revision,
                                         sha256: receipt.sha256, created: receipt.created,
                                         saved: false, note: "prepared write-ahead record")
        try CadAppliedReceiptJournal.shared.prepare(proposalID: proposal.id,
                                                    expectedSHA256: receipt.sha256,
                                                    pendingReceipt: pending)
        let restarted = CadDocumentCenter()
        guard let recovered = await restarted.committedReceipt(proposalID: proposal.id, access: access) else {
            Issue.record("the prepared record must reconcile against the committed bytes")
            return
        }
        #expect(recovered.saved == true)
        #expect(recovered.sha256 == receipt.sha256)
        #expect(recovered.revision == receipt.revision)
        let upgraded = try DrawingAssistantDecisionStore.shared.recoverCommit(
            id: intent.id, receiptRevision: recovered.revision, sha256: recovered.sha256)
        #expect(upgraded?.phase == .committed)

        // A prepared expected SHA that does not match the file is NOT applied.
        let bogus = CadDocumentReceipt(documentID: receipt.documentID, revision: receipt.revision + 5,
                                       sha256: String(repeating: "0", count: 64), created: [],
                                       saved: false, note: "prepared write-ahead record")
        try CadAppliedReceiptJournal.shared.prepare(proposalID: proposal.id,
                                                    expectedSHA256: bogus.sha256,
                                                    pendingReceipt: bogus)
        let stillRestarted = CadDocumentCenter()
        let unmatched = await stillRestarted.committedReceipt(proposalID: proposal.id, access: access)
        #expect(unmatched == nil, "a non-matching prepared SHA must never yield an applied receipt")
    }

    /// The real model turn that failed sent `move` with a 2-number delta
    /// (`[1,0]`), which the engine's `[f64; 3]` serde shape rejects. The tool
    /// normalizer pads z=0 and refuses malformed vectors before the worker, so
    /// the advertised examples and the engine contract now agree.
    @Test func toolNormalizesTwoNumberMoveDeltaAgainstRealEngine() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let entitiesJSON = try await center.query(
            documentID: "plan.dxf",
            requestJSON: #"{"operation":"entities","limit":50}"#, access: access)
        let object = try JSONSerialization.jsonObject(with: Data(entitiesJSON.utf8)) as? [String: Any]
        let rows = object?["entities"] as? [[String: Any]] ?? []
        guard let line = rows.first(where: { ($0["type"] as? String) == "Line" }),
              let handle = line["handle"] as? String else {
            Issue.record("sample drawing has no Line handle")
            return
        }
        let tool = CadDocumentTool(host: center)
        let context = ToolContext(runID: UUID(), toolCallID: "call-move", scope: .local,
                                  workspaceRootURL: root, cancellation: CancellationToken(),
                                  environmentID: nil, conversationID: UUID())
        let argsJSON = #"{"action":"propose","path":"plan.dxf","summary":"move line","operations":[{"operation":"move","handle":"\#(handle)","delta":[1,0]}]}"#
        let args = try JSONDecoder().decode(CadDocumentArguments.self, from: Data(argsJSON.utf8))
        try tool.validate(args)
        let output = try await tool.execute(args, context: context)
        // Primary-directed 2026-10-15 behaviour change: an ordinary CAD
        // propose no longer pauses the run for the user; it still writes
        // nothing and the normalized delta must reach the real engine.
        #expect(output.requiresUserAction == false,
                "a normalized 2-number delta must reach the real engine")
        // The tool records the proposal under the access it derived from the
        // context (chat ownership here), not the workspace helper's access.
        let toolAccess = CadDocumentTool.access(for: context)
        let proposals = try await center.pendingProposals(documentID: "plan.dxf", access: toolAccess)
        let proposal = try #require(proposals.first)
        #expect(proposal.operationsJSON.contains("\"delta\":[1,0,0]"))
        let changed = proposal.preview.counts["changed"] ?? 0
        let added = proposal.preview.counts["added"] ?? 0
        #expect(changed + added >= 1, "moving a real line must produce a preview change")
    }

    /// Earlier persisted decision lines have no `phase`; they are committed
    /// records, never silently dropped or misread as intents.
    @Test func legacyDecisionLineDecodesAsCommitted() throws {
        let data = Data(#"{"id":"x","conversationID":"00000000-0000-0000-0000-000000000001","proposalID":"00000000-0000-0000-0000-000000000002","decision":"applied","revision":3,"sha256":"ab","recordedAt":0,"delivered":false}"#.utf8)
        let decision = try JSONDecoder().decode(DrawingAssistantDecisionStore.Decision.self, from: data)
        #expect(decision.phase == .committed)
        #expect(decision.revision == 3)
    }
}

/// UI-to-runtime binding contract for the Canvas Drawing Assistant staged
/// document: the review sheet and the tool context resolve the SAME
/// CadDocumentAccess; proposals prepared through the tool path are
/// discoverable only by the bound sheet access, never by unrelated chats;
/// and a staged context authorizes exactly the staged path — quoting any
/// other path in the prompt grants nothing.
@Suite("Canvas drawing assistant staged binding", .serialized)
@MainActor
struct CanvasDrawingAssistantBindingTests {
    private let addLineOperations =
        #"[{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}]"#

    private func stagedWorkspace() throws -> (root: URL, stagedPath: String, canvasID: UUID) {
        let canvasID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("CanvasDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let sample = try? Data(contentsOf: bundleRoot.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        // Deterministic staged layout like the canvas registry:
        // <canvas>/<node>/name.dxf.
        let stagedPath = "\(canvasID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/plan.dxf"
        let destination = root.appendingPathComponent(stagedPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try sample.write(to: destination)
        return (root, stagedPath, canvasID)
    }

    /// The review sheet builds exactly this access from the capture
    /// (`documentAccess` in EngineeringReviewSheet); the tool builds it from
    /// the seeded ToolContext. They must be identical for proposals to match.
    private func sheetAccess(root: URL, canvasID: UUID) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                          ownerKind: "canvas", ownerID: canvasID)
    }

    private func toolContext(root: URL, stagedPath: String, canvasID: UUID) -> ToolContext {
        ToolContext(
            runID: UUID(),
            canvasStagedDocument: CanvasStagedDocumentAccess(
                canvasID: canvasID, draftRootPath: root.path,
                stagedRelativePath: stagedPath),
            cancellation: CancellationToken())
    }

    @Test("tool context and review sheet derive the identical staged access")
    func toolAndSheetAccessIdentical() throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = toolContext(root: root, stagedPath: stagedPath, canvasID: canvasID)
        #expect(CadDocumentTool.access(for: context) == sheetAccess(root: root, canvasID: canvasID))
        // A run WITHOUT the staged seed keeps the ordinary derivation and
        // can never alias the canvas identity.
        let ordinary = CadDocumentTool.access(for: ToolContext(
            runID: UUID(), workspaceRootURL: root,
            cancellation: CancellationToken(),
            conversationID: UUID()))
        #expect(ordinary.ownerKind == "chat")
        #expect(ordinary != sheetAccess(root: root, canvasID: canvasID))
    }

    @Test("a staged context authorizes exactly the staged path and nothing else")
    func stagedPathRestriction() throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = toolContext(root: root, stagedPath: stagedPath, canvasID: canvasID)
        try CadDocumentTool.authorizeDocumentPath(stagedPath, context: context)
        // The same staged file addressed by its canonical absolute path (the
        // real model turn that hit "Execution error: Unauthorized" used the
        // draft-root-prefixed path) is still exactly the one authorized file.
        let absolute = root.appendingPathComponent(stagedPath).standardizedFileURL.path
        try CadDocumentTool.authorizeDocumentPath(absolute, context: context)
        #expect(throws: FloeError.self) {
            try CadDocumentTool.authorizeDocumentPath("other.dxf", context: context)
        }
        // Any OTHER path under the same draft root is refused: the authorized
        // set must stay exactly this staged document.
        let sibling = root.appendingPathComponent("\(canvasID.uuidString.lowercased())/other.dxf").path
        #expect(throws: FloeError.self) {
            try CadDocumentTool.authorizeDocumentPath(sibling, context: context)
        }
        // A traversal that escapes the draft root is refused even when it
        // resolves to an existing file outside.
        let escape = root.appendingPathComponent("../../outside.dxf").path
        #expect(throws: FloeError.self) {
            try CadDocumentTool.authorizeDocumentPath(escape, context: context)
        }
        // No staged seed: no restriction (ordinary workspace rules apply),
        // and a nil path (capabilities-only upstream) is never an escape.
        let ordinary = ToolContext(runID: UUID(), cancellation: CancellationToken())
        try CadDocumentTool.authorizeDocumentPath("anything.dxf", context: ordinary)
        try CadDocumentTool.authorizeDocumentPath(nil, context: ordinary)
    }

    @Test("send-time binding: the durable assistant conversation resolves the exact staged identity the runtime uses")
    func sendBindingResolvesStagedIdentity() throws {
        let canvasID = UUID()
        let stagedPath = "\(canvasID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/plan.dxf"
        let conversationID = UUID()
        // What EngineeringReviewSheet.send() does once the user sends: bind
        // the assistant conversation to the staged document (canvas
        // namespace). No prompt text participates.
        try DrawingAssistantConversationStore.shared.bind(
            workspaceID: canvasID, relativePath: stagedPath, conversationID: conversationID)
        defer {
            // Unbind by rebinding to a fresh conversation is NOT how the
            // store works; the binding is task-scoped test data keyed by a
            // unique canvas UUID, which never collides with real bindings.
        }
        // What ConversationCenter.runService resolves for that run launch:
        let resolved = ConversationCenter.canvasStagedBinding(conversationID: conversationID)
        let expectedRoot = CanvasDrawingNodePlanner.canonicalDraftRoot()
        #expect(resolved != nil)
        #expect(resolved?.canvasID == canvasID)
        #expect(resolved?.stagedRelativePath == stagedPath)
        #expect(resolved?.draftRootPath == expectedRoot?.path)
        // The runtime tool context built from that seed derives exactly the
        // review sheet's access — proposals prepared on this run match the
        // sheet's pending list.
        guard let resolved else { return }
        let context = ToolContext(
            runID: UUID(), canvasStagedDocument: resolved,
            cancellation: CancellationToken())
        let sheetAccess = CadDocumentAccess(
            environmentID: nil, workspacePath: expectedRoot?.path,
            ownerKind: "canvas", ownerID: canvasID)
        #expect(CadDocumentTool.access(for: context) == sheetAccess)
        // A conversation without a binding gets NO staged authority.
        #expect(ConversationCenter.canvasStagedBinding(conversationID: UUID()) == nil)
    }

    @Test("runtime proposals are discoverable by the bound sheet access only")
    func proposalBindingContract() async throws {
        let (root, stagedPath, canvasID) = try stagedWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let center = CadDocumentCenter()
        let access = sheetAccess(root: root, canvasID: canvasID)

        // Runtime path: snapshot + propose through the tool-derived access.
        let toolAccess = CadDocumentTool.access(for: toolContext(
            root: root, stagedPath: stagedPath, canvasID: canvasID))
        let snapshot = try await center.snapshot(documentID: stagedPath, access: toolAccess)
        let proposal = try await center.prepareProposal(
            documentID: stagedPath, snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: toolAccess)
        try await center.storeProposal(proposal)

        // The SAME sheet access discovers the pending proposal...
        let sheetVisible = try await center.pendingProposals(documentID: stagedPath, access: access)
        #expect(sheetVisible.map(\.id) == [proposal.id])
        // ...including when derived from the tool context again.
        let viaTool = try await center.pendingProposals(documentID: stagedPath, access: toolAccess)
        #expect(viaTool.map(\.id) == [proposal.id])

        // Unrelated chats with the same root or another canvas see nothing
        // and cannot load the proposal.
        let strangers: [CadDocumentAccess] = [
            CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                              ownerKind: "chat", ownerID: UUID()),
            CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                              ownerKind: "canvas", ownerID: UUID()),
        ]
        for stranger in strangers {
            let visible = try await center.pendingProposals(documentID: stagedPath, access: stranger)
            #expect(visible.isEmpty)
            // Foreign access gets the same denial as an unknown proposal:
            // ids are not enumerable across owners.
            let loaded = try await center.loadProposal(id: proposal.id, access: stranger)
            #expect(loaded == nil)
        }
    }
}

/// Fail-closed authoritative reachability for creative-asset prune
/// protection: a corrupt/unreadable/newer-schema canvas project makes the
/// scan return `.unknown` (retain), never `.notReachable`, and a pending
/// reconciliation op retains the asset while bookkeeping is mid-flight.
@Suite("Canvas reachability fails closed", .serialized)
@MainActor
struct CanvasReachabilityFailClosedTests {
    private var canvasesDirectory: URL {
        get throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("Canvases", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    private func plantCanvasProjectFile(
        named fileID: UUID,
        project: CanvasProject
    ) throws -> URL {
        let url = try canvasesDirectory.appendingPathComponent("\(fileID.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder).write(
            to: url, options: .atomic)
        return url
    }

    @Test("a corrupt canvas project makes reachability unknown, never notReachable")
    func corruptProjectFailsClosed() throws {
        let directory = try canvasesDirectory
        let corruptID = UUID()
        let corruptURL = directory.appendingPathComponent("\(corruptID.uuidString).json")
        try Data("{ not a canvas project".utf8).write(to: corruptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        // Even an asset no project references is retained: the scan cannot
        // prove unreferencedness past a corrupt file.
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .unknown)
    }

    @Test("a valid project referencing an asset reports reachable; unrelated assets are notReachable")
    func validProjectReachability() throws {
        let canvasID = UUID()
        let assetID = UUID()
        let node = CanvasNode(
            id: UUID(), kind: .image, text: "img",
            position: .init(x: 0, y: 0), size: .init(width: 10, height: 10),
            asset: CanvasAssetReference(
                id: assetID, contentHash: String(repeating: "a", count: 64),
                localRelativePath: "Materials/a.png", mimeType: "image/png",
                byteCount: 10))
        let document = CanvasDocument(name: "D", nodes: [node])
        let project = CanvasProject(
            id: canvasID, name: "C", documents: [document],
            selectedDocumentID: document.id)
        let url = try plantCanvasProjectFile(named: canvasID, project: project)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WorkspaceCanvasRegistry.reachability(of: assetID) == .reachable)
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .notReachable)
    }

    @Test("a pending reconciliation op retains the asset while bookkeeping is mid-flight")
    func pendingOpRetains() throws {
        let assetID = UUID()
        let journal = try canvasesDirectory
            .appendingPathComponent("asset-reconciliation-\(UUID().uuidString).json")
        let record = CanvasAssetReconciliation.Record(ops: [
            .init(id: "op-1", assetID: assetID, delta: 1)
        ])
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        defer { try? FileManager.default.removeItem(at: journal) }
        #expect(WorkspaceCanvasRegistry.reachability(of: assetID) == .reachable)
    }

    @Test("an undecodable reconciliation journal fails closed to unknown, never notReachable")
    func undecodableJournalFailsClosed() throws {
        let journal = try canvasesDirectory
            .appendingPathComponent("asset-reconciliation-\(UUID().uuidString).json")
        try Data("{ not a reconciliation record".utf8).write(to: journal, options: .atomic)
        defer { try? FileManager.default.removeItem(at: journal) }
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .unknown)
    }

    @Test("reachability defers to unknown while a canvas publication is in flight")
    func inFlightPublicationDefersScan() async throws {
        let canvasID = UUID()
        let document = CanvasDocument(name: "D", nodes: [])
        let project = CanvasProject(
            id: canvasID, name: "C", documents: [document],
            selectedDocumentID: document.id)
        let url = try plantCanvasProjectFile(named: canvasID, project: project)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WorkspaceCanvasRegistry.reachability(of: UUID()) == .notReachable)

        // A tight CAS loop keeps a publication in flight nearly 100% of the
        // time (the flag spans the whole decode/encode/write); the scan must
        // observe .unknown at least once instead of pruning past a
        // reference-adding publish.
        let stop = Date().addingTimeInterval(10)
        var revision = Int64(1)
        let writer = Task.detached(priority: .userInitiated) {
            while Date() < stop {
                revision += 1
                var next = project
                next.revision = revision
                _ = try? CanvasProjectFileWriter.shared.compareAndSwap(
                    next, at: url, expectedRevision: revision - 1)
            }
        }
        var observedUnknown = false
        while Date() < stop, !observedUnknown {
            if WorkspaceCanvasRegistry.reachability(of: UUID()) == .unknown {
                observedUnknown = true
            }
        }
        writer.cancel()
        #expect(observedUnknown, "the scan must defer while a publication is in flight")
    }
}

/// The staged Canvas Drawing Assistant first send failed with the runtime
/// error "Storage corrupted: Conversation has no canonical workspace":
/// EngineeringReviewSheet creates the assistant conversation before the run,
/// and RunLaunchStore is fail-closed for an existing conversation without a
/// conversation_workspace_ownership row. These tests reproduce that exact
/// failure against a real database and pin the heal path the sheet now uses
/// (existing workspace services; a private-task workspace for staged drafts,
/// never a project workspace), including retry without a duplicate
/// conversation.
@Suite("FloeApp.DrawingAssistant review launch", .serialized)
@MainActor
struct DrawingAssistantReviewLaunchWorkspaceTests {
    private func makeDatabase() throws -> (DatabaseManager, URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-review-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: sandbox.appendingPathComponent("floe.sqlite"))
        return (database, sandbox)
    }

    private func launchRequest(conversationID: UUID, workspaceID: UUID?) -> RunLaunchRequest {
        RunLaunchRequest(
            conversationID: conversationID,
            runID: UUID(),
            goal: "检查这张图纸",
            workspaceID: workspaceID,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(),
            messageRole: "user")
    }

    private func saveConversation(_ store: SQLiteConversationStore) async throws -> ConversationRecord {
        let conversation = ConversationRecord(
            id: UUID(), title: "图纸助手", createdAt: Date(), updatedAt: Date())
        try await store.saveConversation(conversation)
        return conversation
    }

    @Test("A staged review conversation gets its own private-task workspace and the retry launches")
    func stagedReviewConversationHealsAndLaunches() async throws {
        let (database, sandbox) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let launches = SQLiteRunLaunchStore(database: database)
        let conversation = try await saveConversation(conversations)
        let ownerBefore = try await workspaces.workspaceID(conversationID: conversation.id)
        #expect(ownerBefore == nil)

        // The exact failure the primary CUA observed on send.
        var reported: FloeError?
        do {
            _ = try await launches.prepare(launchRequest(
                conversationID: conversation.id, workspaceID: nil))
        } catch let error as FloeError {
            reported = error
        }
        #expect(reported == .storageCorrupted("Conversation has no canonical workspace"))

        // The heal the review sheet applies before launching.
        let workspaceID = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: nil,
            title: "图纸助手",
            store: workspaces)
        let maybeRecord = try await workspaces.workspace(id: workspaceID)
        let record = try #require(maybeRecord)
        #expect(record.kind == .privateTask)
        #expect(record.internalRelativePath == "PrivateTasks/\(conversation.id.uuidString)")

        // Retry without creating a second conversation: the durable identity
        // is reused and the run now commits.
        let prepared = try await launches.prepare(launchRequest(
            conversationID: conversation.id, workspaceID: nil))
        #expect(prepared.createdConversation == false)
        #expect(prepared.conversation.id == conversation.id)
        #expect(prepared.workspace.id == workspaceID)

        // Idempotent: a later send cannot re-own or duplicate the workspace.
        let countBefore = try await workspaces.workspaces().count
        let again = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: nil,
            title: "图纸助手",
            store: workspaces)
        #expect(again == workspaceID)
        let countAfter = try await workspaces.workspaces().count
        #expect(countAfter == countBefore)
    }

    @Test("A workspace review conversation links to the workspace it was opened from")
    func workspaceReviewConversationLinksToWorkspace() async throws {
        let (database, sandbox) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let launches = SQLiteRunLaunchStore(database: database)
        let project = WorkspaceRecord(
            name: "批量选择测试", rootBookmark: Data(), kind: .project)
        try await workspaces.saveWorkspace(project)
        let conversation = try await saveConversation(conversations)

        // Same fail-closed path, now with a requested workspace.
        var reported: FloeError?
        do {
            _ = try await launches.prepare(launchRequest(
                conversationID: conversation.id, workspaceID: project.id))
        } catch let error as FloeError {
            reported = error
        }
        #expect(reported == .storageCorrupted("Conversation has no canonical workspace"))

        let owner = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: project.id,
            title: "图纸助手",
            store: workspaces)
        #expect(owner == project.id)
        let prepared = try await launches.prepare(launchRequest(
            conversationID: conversation.id, workspaceID: project.id))
        #expect(prepared.workspace.id == project.id)
        #expect(prepared.createdConversation == false)

        // Existing ownership is never silently replaced by a different
        // requested workspace: the same refusal the launch store would give.
        let stranger = WorkspaceRecord(name: "Other", rootBookmark: Data(), kind: .project)
        try await workspaces.saveWorkspace(stranger)
        await #expect(throws: (any Error).self) {
            _ = try await WorkspaceCenter.ensureReviewConversationWorkspace(
                conversationID: conversation.id,
                workspaceID: stranger.id,
                title: "图纸助手",
                store: workspaces)
        }
        let ownerAfter = try await workspaces.workspaceID(conversationID: conversation.id)
        #expect(ownerAfter == project.id)
    }
}

/// Mutable box so tests can share a Binding target without inout captures.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
