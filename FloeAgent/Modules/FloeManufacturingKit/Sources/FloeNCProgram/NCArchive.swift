// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public struct NCRoundTripReport: Codable, Sendable {
    public let passed: Bool
    public let motions,events,sampledPoints: Int
    public let canonicalSHA256: String
    public let maximumSampleDeviationMM: Double
}
public enum NCVerification {
    public static func roundTrip(_ program:NCProgram,cancellation:NCCancellation? = nil) throws -> NCRoundTripReport {
        let source=NCCodec.encode(program)
        let reopened=try NCCodec.decode(source,configuration:program.configuration,cancellation:cancellation)
        func semantic(_ p:NCProgram) throws -> Data {
            let motions=p.motions.map { NCMotion(line:0,start:$0.start,end:$0.end,curve:$0.curve,rapid:$0.rapid,process:$0.process) }
            let events=p.events.map { NCEvent(line:0,kind:$0.kind,value:$0.value,process:$0.process) }
            struct Semantic:Encodable { let motions:[NCMotion];let events:[NCEvent];let finalPosition:NCPosition;let finalProcess:NCProcessState }
            return try NCArchive.encoder.encode(Semantic(motions:motions,events:events,finalPosition:p.finalPosition,finalProcess:p.finalProcess))
        }
        func equivalent(_ a:Any,_ b:Any) -> Bool {
            if let x=a as? [String:Any],let y=b as? [String:Any] { return Set(x.keys) == Set(y.keys) && x.allSatisfy { key,value in equivalent(value,y[key]!) } }
            if let x=a as? [Any],let y=b as? [Any] { return x.count == y.count && zip(x,y).allSatisfy { equivalent($0,$1) } }
            if let x=a as? NSNumber,let y=b as? NSNumber { return abs(x.doubleValue-y.doubleValue) <= max(1e-9,abs(x.doubleValue)*4e-15) }
            if let x=a as? String,let y=b as? String { return x == y }
            return a is NSNull && b is NSNull
        }
        guard try equivalent(JSONSerialization.jsonObject(with:semantic(program)),JSONSerialization.jsonObject(with:semantic(reopened))) else { throw NCError("Canonical encoding changed analytic geometry, axes or process state") }
        let a=try NCGeometry.sample(program,cancellation:cancellation),b=try NCGeometry.sample(reopened,cancellation:cancellation)
        var maximum=0.0,count=0
        guard a.count == b.count else { throw NCError("Round-trip path count mismatch") }
        for (x,y) in zip(a,b) {
            guard x.samples.count == y.samples.count else { throw NCError("Round-trip sampling count mismatch") }
            for (p,q) in zip(x.samples,y.samples) { maximum=max(maximum,(p.point-q.point).length);count += 1 }
        }
        guard maximum <= 1e-7 else { throw NCError("Round-trip curve deviation exceeds 0.0000001 mm") }
        return .init(passed:true,motions:program.motions.count,events:program.events.count,sampledPoints:count,
                     canonicalSHA256:NCArchive.digest(Data(source.utf8)),maximumSampleDeviationMM:maximum)
    }
}

public enum NCArchive {
    public static var encoder:JSONEncoder { let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];return e }
    private struct Payload:Codable { let source:String;let configuration:NCConfiguration }
    private struct Envelope:Codable { let version:Int;let sha256:String;let payload:Data }
    public static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func save(source:String,configuration:NCConfiguration,to url:URL) throws {
        _ = try NCCodec.decode(source,configuration:configuration)
        let payload=try encoder.encode(Payload(source:source,configuration:configuration))
        let data=try encoder.encode(Envelope(version:1,sha256:digest(payload),payload:payload))
        guard data.count <= 24_000_000 else { throw NCError("NC archive byte budget exceeded") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    public static func open(_ url:URL) throws -> (source:String,program:NCProgram) {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size <= 24_000_000 else { throw NCError("NC archive byte budget exceeded") }
        let data=try Data(contentsOf:url)
        guard data.count <= 24_000_000 else { throw NCError("NC archive grew beyond byte budget") }
        let envelope=try JSONDecoder().decode(Envelope.self,from:data)
        guard envelope.version == 1,digest(envelope.payload) == envelope.sha256 else { throw NCError("NC archive version or source digest mismatch") }
        let payload=try JSONDecoder().decode(Payload.self,from:envelope.payload)
        return (payload.source,try NCCodec.decode(payload.source,configuration:payload.configuration))
    }
}
