import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import FloeCore
@testable import FloeProviders
#if canImport(FloeApp)
@testable import FloeApp
#else
@testable import MediaImageGeometry
#endif

@Suite("Media masked provider canvas geometry", .serialized)
struct MediaProviderImageGeometryTests {
    private func route(_ id: String = "gpt-image-2.5-sunburst", kind: ProviderKind = .openAI,
                       base: String = "https://image-fixture.invalid/v1") -> (ProviderProfile, ModelProfile) {
        let provider = ProviderProfile(kind: kind, wireProtocol: .openAIChatCompletions, baseURL: URL(string: base)!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: id, displayName: "Geometry fixture", limits: .init(contextTokens: 8192, maxOutputTokens: 1024), capabilities: [.imageEditing])
        return (provider, model)
    }
    private func plan(_ w: Int, _ h: Int, id: String = "gpt-image-2.5-sunburst") throws -> MediaProviderImageGeometry.Plan {
        let r = route(id); return try MediaProviderImageGeometry.plan(width: w, height: h, provider: r.0, model: r.1)
    }
    private func image(_ w: Int, _ h: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
        var bytes = [UInt8](); bytes.reserveCapacity(w * h * 4)
        for y in 0..<h { for x in 0..<w { let p = pixel(x, y); bytes.append(contentsOf: [p.0,p.1,p.2,p.3]) } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try MediaProviderImageGeometry.encode(cg)
    }
    private func pixels(_ data: Data) throws -> (Int, Int, [UInt8]) {
        let cg = try MediaProviderImageGeometry.decode(data)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy); context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); return true
        }
        #expect(ok); return (cg.width, cg.height, bytes)
    }
    private func sample(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
        let (w, h, bytes) = try pixels(data); #expect(x >= 0 && x < w && y >= 0 && y < h)
        return Array(bytes[((y * w + x) * 4)..<((y * w + x) * 4 + 4)])
    }
    private func input(_ w: Int, _ h: Int) throws -> MediaProviderImageGeometry.Input {
        let source = try image(w, h) { x, y in
            if (x - w/2)*(x - w/2) + (y - h/2)*(y - h/2) < min(w,h)*min(w,h)/16 { return (0,255,0,255) }
            return (x < w/2 ? 255 : 0, 0, y < h/2 ? 255 : 0, 255)
        }
        let mask = try image(w, h) { _,_ in (0,0,0,0) }
        return .init(sourcePNG: source, maskPNG: mask, width: w, height: h)
    }

    @Test("Exact arbitrary ratios use a real native size, not an injected square")
    func exactRatioAndEncoding() throws {
        for (w,h) in [(320,160),(170,130),(90,160),(400,300)] {
            let p = try plan(w,h)
            #expect(p.canvas.width * h == p.canvas.height * w)
            #expect(p.canvas.width % 16 == 0 && p.canvas.height % 16 == 0)
            #expect(p.canvas.width * p.canvas.height >= 655_360)
            #expect(p.canvas.width <= 1536 && p.canvas.height <= 1536)
            #expect(p.selection.aspectRatio == nil)
            #expect(p.selection.nativeSizeOverride == p.canvas.wire)
            #expect(p.content.minX >= -0.00001 && p.content.minY >= -0.00001)
        }
    }
    @Test("Fixed-ratio GPT models pad the whole target, including panoramas")
    func fixedRatioPadsInsteadOfCropping() throws {
        let p = try plan(400,100,id:"gpt-image-1.5")
        #expect(p.canvas == .init(width:1536,height:1024))
        #expect(p.content.width == 1536 && p.content.height == 384)
        #expect(p.content.minY == 320)
        #expect(p.content.width / 400 == p.content.height / 100)
        let r = route("gpt-image-1.5")
        #expect(ImageGenerationPresetResolver.parameterContract(provider:r.0,model:r.1,operation:.inpaint).verifiedModel == false)
        #expect(MediaProviderImageGeometry.accepts(provider:r.0,model:r.1))
    }
    @Test("Unrepresentable exact ratios use a recorded uniform pad mapping")
    func irregularIntegerAspect() throws {
        let p = try plan(997,499)
        #expect(p.content.width / 997 == p.content.height / 499)
        #expect(p.content.width <= Double(p.canvas.width) && p.content.height <= Double(p.canvas.height))
        #expect(p.selection.nativeSizeOverride != "1024x1024")
    }
    @Test("Landscape/portrait round trips preserve a circle and all four corners")
    func actualPixelRoundTrip() throws {
        for (w,h) in [(400,100),(100,400)] {
            let i = try input(w,h), p = try plan(w,h,id:"gpt-image-1.5")
            let prepared = try MediaProviderImageGeometry.prepare(i,plan:p)
            let restored = try MediaProviderImageGeometry.restore(prepared.sourcePNG,plan:p)
            let (rw,rh,bytes) = try pixels(restored); #expect(rw == w && rh == h)
            for (x,y) in [(4,4),(w-5,4),(4,h-5),(w-5,h-5)] {
                let actual = try sample(restored,x:x,y:y), expected = try sample(i.sourcePNG,x:x,y:y)
                #expect(zip(actual,expected).allSatisfy { abs(Int($0.0)-Int($0.1)) <= 2 })
            }
            var xs=[Int](),ys=[Int]()
            for y in 0..<h { for x in 0..<w { let k=(y*w+x)*4;if bytes[k+1]>220 && bytes[k]<30 && bytes[k+2]<30 {xs.append(x);ys.append(y)} } }
            #expect(!xs.isEmpty);#expect(abs((xs.max()!-xs.min()!)-(ys.max()!-ys.min()!)) <= 1)
        }
    }
    @Test("Soft-only wire coverage becomes alpha0; holes and padding stay protected")
    func softMaskHoleAndPadding() throws {
        let source = try image(400,100) { _,_ in (0,0,0,0) }
        let mask = try image(400,100) { x,y in
            let selected = (30..<90).contains(x) && (20..<70).contains(y)
            let hole = (50..<65).contains(x) && (35..<50).contains(y)
            let a: UInt8 = selected && !hole ? 127 : 255; return (a,a,a,a)
        }
        let p = try plan(400,100,id:"gpt-image-1.5")
        let ready = try MediaProviderImageGeometry.prepare(.init(sourcePNG:source,maskPNG:mask,width:400,height:100),plan:p)
        #expect(ready.maskPNG.count < 4*1024*1024)
        let (w,h,b)=try pixels(ready.maskPNG);#expect(w==p.canvas.width && h==p.canvas.height)
        #expect(stride(from:3,to:b.count,by:4).allSatisfy { b[$0]==0 || b[$0]==255 })
        func alpha(_ x:Int,_ y:Int)throws->UInt8 {try sample(ready.maskPNG,x:Int(p.content.minX+Double(x)*p.scale),y:Int(p.content.minY+Double(y)*p.scale))[3]}
        #expect(try alpha(40,30)==0);#expect(try alpha(57,42)==255);#expect(try alpha(10,10)==255)
        #expect(try sample(ready.maskPNG,x:10,y:10)==[255,255,255,255])
        #expect(try sample(ready.sourcePNG,x:10,y:10)[3]==0)
    }
    @Test("Rounded reference dimensions never replace the real canvas ratio")
    func roundedReference() throws {
        let source=try image(1536,512){_,_ in(120,20,20,255)},mask=try image(1536,512){_,_ in(0,0,0,0)}
        let p=try plan(5000,1667)
        let ready=try MediaProviderImageGeometry.prepare(.init(sourcePNG:source,maskPNG:mask,width:5000,height:1667),plan:p)
        let result=try MediaProviderImageGeometry.restore(ready.sourcePNG,plan:p)
        let cg=try MediaProviderImageGeometry.decode(result);#expect(cg.width==5000 && cg.height==1667)
        #expect(p.content.width/5000==p.content.height/1667)
    }
    @Test("Wrong-shape provider output is rejected without changing reference bytes")
    func wrongOutputShape() throws {
        let i=try input(320,160),p=try plan(320,160),snapshot=i.sourcePNG
        let square=try image(256,256){_,_ in(1,1,1,255)}
        #expect(throws:(any Error).self){try MediaProviderImageGeometry.restore(square,plan:p)}
        #expect(i.sourcePNG==snapshot)
    }
    @Test("Only one output-pixel shape rounding is accepted")
    func outputRoundingFence() throws {
        let p=try plan(320,160)
        let nearby=try image(p.canvas.width,p.canvas.height+1){_,_ in(255,0,0,255)}
        let result=try MediaProviderImageGeometry.restore(nearby,plan:p)
        #expect(try MediaProviderImageGeometry.decode(result).width==320)
        let wrong=try image(p.canvas.width,p.canvas.height+2){_,_ in(255,0,0,255)}
        #expect(throws:(any Error).self){try MediaProviderImageGeometry.restore(wrong,plan:p)}
    }
    @Test("Reference, mask, real-canvas and selection mismatches fail before a request")
    func invalidInputs() throws {
        let i=try input(320,160),p=try plan(320,160),wrongMask=try image(80,80){_,_ in(0,0,0,0)}
        #expect(throws:(any Error).self){try MediaProviderImageGeometry.prepare(.init(sourcePNG:i.sourcePNG,maskPNG:wrongMask,width:320,height:160),plan:p)}
        #expect(throws:(any Error).self){try MediaProviderImageGeometry.prepare(.init(sourcePNG:i.sourcePNG,maskPNG:i.maskPNG,width:321,height:160),plan:p)}
        let opaque=try image(320,160){_,_ in(255,255,255,255)}
        #expect(throws:(any Error).self){try MediaProviderImageGeometry.prepare(.init(sourcePNG:i.sourcePNG,maskPNG:opaque,width:320,height:160),plan:p)}
        #expect(throws:(any Error).self){try plan(16384,100)}
        #expect(throws:(any Error).self){try plan(8192,1)}
    }
    @Test("Advertised inpaint without a mask encoder is excluded only from this operation")
    func routeWireCapability() {
        let open=route();#expect(MediaProviderImageGeometry.accepts(provider:open.0,model:open.1))
        let ark=route("doubao-seedream-5.0-pro",kind:.volcengineArk)
        #expect(ImageProviderAdapterFactory().adapter(for:ark.0)?.supports(.inpaint,for:ark.0)==true)
        #expect(!MediaProviderImageGeometry.accepts(provider:ark.0,model:ark.1))
        #expect(ImageProviderAdapterFactory().adapter(for:ark.0)?.supports(.generate,for:ark.0)==true)
        let unknown=route("user-unknown-image-id");#expect(!MediaProviderImageGeometry.accepts(provider:unknown.0,model:unknown.1))
        #expect(ImageProviderAdapterFactory().adapter(for:unknown.0)?.supports(.edit,for:unknown.0)==true)
    }
    @Test("Cancelled owned pixel preparation returns cancellation, not output")
    @MainActor func cancellation() async throws {
        let i=try input(400,100),r=route(),transform=MediaProviderImageGeometry.transform(i)
        let task=Task {try await transform.prepare(r.0,r.1)};task.cancel()
        await #expect(throws:CancellationError.self){try await task.value}
        let sibling=Task {42};#expect(await sibling.value==42)
    }
    @Test("Actual OpenAI multipart carries native size and the same padded PNGs")
    @MainActor func realMultipartWire() async throws {
        let input = try input(400,100), r = route("gpt-image-1.5")
        let prepared = try await MediaProviderImageGeometry.transform(input).prepare(r.0,r.1)
        let reply = try JSONSerialization.data(withJSONObject: ["data":[["b64_json":prepared.sourceImages[0].base64EncodedString()]]])
        GeometryWireProtocol.prepare(status:200,body:reply)
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[GeometryWireProtocol.self]
        let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
        let adapter=OpenAIImageAdapter(session:session)
        let result=try await adapter.perform(.init(operation:.inpaint,prompt:"Geometry fixture",sourceImages:prepared.sourceImages,mask:prepared.mask,
            selection:prepared.selection,modelRemoteID:r.1.remoteModelID),provider:r.0,credentials:.init())
        let requests=GeometryWireProtocol.requests();#expect(requests.count==1)
        let request=try #require(requests.first),body=try #require(request.httpBody)
        #expect(request.url?.path=="/v1/images/edits")
        #expect(request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data; boundary=")==true)
        #expect(body.range(of:Data("name=\"size\"\r\n\r\n1536x1024\r\n".utf8)) != nil)
        #expect(body.range(of:prepared.sourceImages[0]) != nil)
        #expect(body.range(of:try #require(prepared.mask)) != nil)
        #expect(body.range(of:Data("name=\"mask\"; filename=\"mask\"\r\nContent-Type: image/png\r\n".utf8)) != nil)
        let restored=try await prepared.restoreImages(result.images)
        let image=try MediaProviderImageGeometry.decode(try #require(restored.first));#expect(image.width==400 && image.height==100)
        #expect(prepared.metadata["editGeometry.target"]=="400x100")
    }
    @Test("Actual encoder refusals retain the existing narrow paid-route fallback classification")
    func realWireRefusalClassification() async throws {
        let r=route(),i=try input(64,64),p=try plan(64,64),prepared=try MediaProviderImageGeometry.prepare(i,plan:p)
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[GeometryWireProtocol.self]
        let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
        let adapter=OpenAIImageAdapter(session:session)
        for status in [401,404,429,403,500] {
            GeometryWireProtocol.prepare(status:status,body:Data("{\"error\":{\"message\":\"offline fixture\"}}".utf8))
            do {
                _=try await adapter.perform(.init(operation:.inpaint,prompt:"Geometry refusal fixture",sourceImages:[prepared.sourcePNG],mask:prepared.maskPNG,
                    selection:p.selection,modelRemoteID:r.1.remoteModelID),provider:r.0,credentials:.init())
                Issue.record("Expected provider refusal")
            } catch let error as RemoteImageError {#expect(error.allowsRouteFallback == [401,404,429].contains(status))}
            #expect(GeometryWireProtocol.requests().count==1)
        }
        #expect(!ImageRouteFallbackPolicy.allowsFallback(explicitSelection:true,autonomous:true,initialProvider:r.0,candidateProvider:r.0))
        #expect(!ImageRouteFallbackPolicy.allowsFallback(explicitSelection:false,autonomous:false,initialProvider:r.0,candidateProvider:r.0))
        #expect(ImageRouteFallbackPolicy.allowsFallback(explicitSelection:false,autonomous:true,initialProvider:r.0,candidateProvider:r.0))
        let foreign=route();#expect(!ImageRouteFallbackPolicy.allowsFallback(explicitSelection:false,autonomous:true,initialProvider:r.0,candidateProvider:foreign.0))
    }

}

/// Intercepts only this synthetic host; no real API, DNS, credentials or paid request.
private final class GeometryWireProtocol: URLProtocol, @unchecked Sendable {
    private static let lock=NSLock()
    nonisolated(unsafe) private static var status=500
    nonisolated(unsafe) private static var body=Data()
    nonisolated(unsafe) private static var recorded=[URLRequest]()
    static func prepare(status:Int,body:Data){lock.lock();defer{lock.unlock()};Self.status=status;Self.body=body;recorded=[]}
    static func requests()->[URLRequest]{lock.lock();defer{lock.unlock()};return recorded}
    override class func canInit(with request:URLRequest)->Bool{request.url?.host=="image-fixture.invalid"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        var request=request
        if request.httpBody==nil,let stream=request.httpBodyStream{
            stream.open();defer{stream.close()};var bytes=Data(),buffer=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable{let count=stream.read(&buffer,maxLength:buffer.count);guard count>0 else{break};bytes.append(buffer,count:count);guard bytes.count<=32*1024*1024 else{client?.urlProtocol(self,didFailWithError:URLError(.dataLengthExceedsMaximum));return}}
            request.httpBody=bytes
        }
        Self.lock.lock();Self.recorded.append(request);let status=Self.status,body=Self.body;Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
