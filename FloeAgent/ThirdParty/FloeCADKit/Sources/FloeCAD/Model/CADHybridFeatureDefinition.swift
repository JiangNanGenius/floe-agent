// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import simd

/// A digest-bound copy, independent of the visible source body's later edits.
/// Float buffers and placement are preserved verbatim. Precise inputs remain
/// precise in the document; only the explicitly requested derived result is mesh.
nonisolated struct CADHybridMeshSource: Codable, Equatable, Sendable {
    let sourceBodyID: BodyID
    let name: String
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let texcoords: [SIMD2<Float>]?
    let placement: Transform3D
    let inputExactness: String
    let sha256: String
    var render: RenderMesh { .init(positions:positions,normals:normals,indices:indices,texcoords:texcoords) }
    init(capturing body: Body) throws {
        sourceBodyID=body.id; name=body.name; positions=body.render.positions
        normals=body.render.normals; indices=body.render.indices; texcoords=body.render.texcoords
        placement=body.transform; inputExactness=body.brep == nil ? "mesh" : "solid"
        sha256=try Self.hash(render:body.render,placement:body.transform,exactness:inputExactness)
        try validate()
    }
    func validate(_ cancelled: () -> Bool = { false }) throws {
        try CADPolygonMeshDefinition.validatePlacement(placement)
        guard !name.isEmpty,name.utf8.count<=4096,["mesh","solid"].contains(inputExactness), !positions.isEmpty,
              positions.count <= 1_500_000, normals.count == positions.count,
              !indices.isEmpty, indices.count % 3 == 0, indices.count / 3 <= 500_000,
              texcoords == nil || texcoords?.count == positions.count else {
            throw CADHybridFailure.invalid("Use a valid source with at most 500,000 triangles.")
        }
        for i in positions.indices {
            if cancelled() { throw CADHybridFailure.cancelled }
            let p=positions[i], n=normals[i]
            guard [p.x,p.y,p.z,n.x,n.y,n.z].allSatisfy(\.isFinite),
                  max(abs(p.x),max(abs(p.y),abs(p.z))) <= 1e6 else {
                throw CADHybridFailure.invalid("The source contains invalid coordinates or normals.")
            }
            if let uv=texcoords?[i], !uv.x.isFinite || !uv.y.isFinite {
                throw CADHybridFailure.invalid("The source contains invalid texture coordinates.")
            }
        }
        for index in indices {
            if cancelled() { throw CADHybridFailure.cancelled }
            guard Int(index)<positions.count else { throw CADHybridFailure.invalid("The source references a missing vertex.") }
        }
        guard sha256 == (try Self.hash(render:render,placement:placement,exactness:inputExactness)) else {
            throw CADHybridFailure.invalid("The immutable source failed its integrity check.")
        }
    }
    private static func hash(render:RenderMesh,placement:Transform3D,exactness:String) throws -> String {
        var digest=CADHybridSemanticDigest(domain:"floe.cad.hybrid-source.ieee754le.v1")
        try digest.appendGeometry(render,placement:placement,exactness:exactness)
        return digest.finish()
    }
    static func validateStoredJSONObject(_ raw:Any) throws {
        let value=try CADHybridStoredJSON.object(raw,keys:["sourceBodyID","name","positions","normals","indices","texcoords","placement","inputExactness","sha256"])
        try CADHybridStoredJSON.bodyID(value["sourceBodyID"] as Any)
        _=try CADHybridStoredJSON.object(value["placement"] as Any,keys:["translation","rotation","scale"])
    }
}

nonisolated struct CADHybridOperation: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case hole, cut, boss, union, subtract, intersect }
    enum Tool: Codable, Equatable, Sendable {
        /// Centred tools in world millimetres. Cylinder height follows axis.
        case cylinder(radius:Double,height:Double,center:SIMD3<Double>,axis:SIMD3<Double>,segments:Int)
        case box(size:SIMD3<Double>,center:SIMD3<Double>)
        /// A frozen tessellation of another mesh OR an exact closed solid.
        case body(CADHybridMeshSource)
    }
    var id=UUID()
    var kind:Kind
    var tool:Tool
    var booleanCode:Int { switch kind { case .boss,.union:return 0; case .hole,.cut,.subtract:return 1; case .intersect:return 2 } }
    func validate(_ cancelled: () -> Bool = { false }) throws {
        func finite(_ v:SIMD3<Double>) -> Bool { [v.x,v.y,v.z].allSatisfy { $0.isFinite && abs($0)<=1e6 } }
        switch tool {
        case let .cylinder(radius,height,center,axis,segments):
            guard radius.isFinite, height.isFinite, radius>=0.001, height>=0.001,
                  radius<=100_000,height<=100_000,finite(center),finite(axis),simd_length(axis)>1e-9,
                  (12...256).contains(segments) else { throw CADHybridFailure.invalid("Use a positive radius and depth, a valid axis and 12–256 segments.") }
        case let .box(size,center):
            guard finite(size),finite(center),min(size.x,min(size.y,size.z))>=0.001 else { throw CADHybridFailure.invalid("Use positive box dimensions and a finite centre.") }
        case let .body(source): try source.validate(cancelled)
        }
    }
}

nonisolated struct CADHybridFeatureDefinition: Codable, Equatable, Sendable {
    static let supportedVersion=1
    static let algorithmV1="manifold-3.5.4-v1"
    var version=Self.supportedVersion
    var algorithm=Self.algorithmV1
    var source:CADHybridMeshSource
    var operations:[CADHybridOperation]
    /// New cut faces have no authored UVs. Opt-in is captured with the history;
    /// the untouched source still retains its complete UV/material records.
    var discardOutputUV=false
    func validate(_ cancelled: () -> Bool = { false }) throws {
        guard version==Self.supportedVersion,algorithm==Self.algorithmV1 else { throw CADHybridFailure.unsupported("This hybrid history requires a newer editor.") }
        guard !operations.isEmpty,operations.count<=32,Set(operations.map(\.id)).count==operations.count else { throw CADHybridFailure.invalid("Use one to 32 independently identified features.") }
        try source.validate(cancelled)
        guard source.texcoords == nil || discardOutputUV else { throw CADHybridFailure.unsupported("Hybrid cuts create new faces. Explicitly allow an untextured derived result; the original textures are kept.") }
        for operation in operations {
            try operation.validate(cancelled)
            if case let .body(tool)=operation.tool,tool.texcoords != nil,!discardOutputUV {
                throw CADHybridFailure.unsupported("The derived result needs explicit UV-loss acknowledgement.")
            }
        }
    }
    var digest:String {
        do {
            var digest=CADHybridSemanticDigest(domain:"floe.cad.hybrid-definition.ieee754le.v1")
            digest.append(version);digest.append(algorithm)
            try digest.appendSource(source)
            digest.append(operations.count)
            for operation in operations {
                digest.append(operation.id.uuidString);digest.append(operation.kind.rawValue)
                switch operation.tool {
                case let .cylinder(radius,height,center,axis,segments):
                    digest.append("cylinder");try digest.append(radius);try digest.append(height)
                    try digest.append(center);try digest.append(axis);digest.append(segments)
                case let .box(size,center):
                    digest.append("box");try digest.append(size);try digest.append(center)
                case let .body(tool):
                    digest.append("body");try digest.appendSource(tool)
                }
            }
            digest.append(discardOutputUV)
            return digest.finish()
        } catch { return "invalid" }
    }
    static func validateStoredJSONObject(_ raw:Any) throws {
        let value=try CADHybridStoredJSON.object(raw,keys:["version","algorithm","source","operations","discardOutputUV"])
        try CADHybridMeshSource.validateStoredJSONObject(value["source"] as Any)
        guard let operations=value["operations"] as? [Any],operations.count<=32 else {throw CADHybridFailure.invalid("Invalid stored hybrid operations.")}
        for rawOperation in operations {
            let operation=try CADHybridStoredJSON.object(rawOperation,keys:["id","kind","tool"])
            guard let tool=operation["tool"] as? [String:Any],tool.count==1,let entry=tool.first else {throw CADHybridFailure.unsupported("Unknown hybrid tool representation.")}
            switch entry.key {
            case "cylinder":_=try CADHybridStoredJSON.object(entry.value,keys:["radius","height","center","axis","segments"])
            case "box":_=try CADHybridStoredJSON.object(entry.value,keys:["size","center"])
            case "body":
                let payload=try CADHybridStoredJSON.object(entry.value,keys:["_0"])
                try CADHybridMeshSource.validateStoredJSONObject(payload["_0"] as Any)
            default:throw CADHybridFailure.unsupported("Unknown stored hybrid tool.")
            }
        }
        let data=try JSONSerialization.data(withJSONObject:raw)
        try JSONDecoder().decode(Self.self,from:data).validate()
    }
}

/// A semantic digest must survive JSONEncoder -> Foundation JSON -> JSONDecoder.
/// Those codecs may turn IEEE -0 into +0. Hash finite numeric VALUES in a fixed
/// little-endian order instead of their JSON spelling. Only zero's sign is
/// normalized; every nonzero float/double bit, index, optional-presence marker,
/// count and definition field remains bound. Original buffers are never edited.
private nonisolated struct CADHybridSemanticDigest {
    private var hasher=SHA256()
    private var bytes=Data()
    init(domain:String) { bytes.reserveCapacity(16_384);append(domain) }
    mutating func append(_ value:Bool) { bytes.append(value ? 1:0);flushIfNeeded() }
    mutating func append(_ value:Int) { append(UInt64(bitPattern:Int64(value))) }
    mutating func append(_ value:String) {
        append(UInt64(value.utf8.count));bytes.append(contentsOf:value.utf8);flushIfNeeded()
    }
    private mutating func append(_ value:UInt32) {
        var little=value.littleEndian
        withUnsafeBytes(of:&little) { bytes.append(contentsOf:$0) };flushIfNeeded()
    }
    private mutating func append(_ value:UInt64) {
        var little=value.littleEndian
        withUnsafeBytes(of:&little) { bytes.append(contentsOf:$0) };flushIfNeeded()
    }
    private mutating func append(_ value:Float) throws {
        guard value.isFinite else { throw CADHybridFailure.invalid("The source contains non-finite numeric data.") }
        append(value == 0 ? UInt32(0):value.bitPattern)
    }
    mutating func append(_ value:Double) throws {
        guard value.isFinite else { throw CADHybridFailure.invalid("The source contains non-finite numeric data.") }
        append(value == 0 ? UInt64(0):value.bitPattern)
    }
    mutating func append(_ value:SIMD3<Double>) throws {
        try append(value.x);try append(value.y);try append(value.z)
    }
    mutating func appendGeometry(_ render:RenderMesh,placement:Transform3D,exactness:String) throws {
        append(render.positions.count)
        for point in render.positions { try append(point.x);try append(point.y);try append(point.z) }
        append(render.normals.count)
        for normal in render.normals { try append(normal.x);try append(normal.y);try append(normal.z) }
        append(render.indices.count)
        for index in render.indices { append(index) }
        append(render.texcoords != nil)
        if let texcoords=render.texcoords {
            append(texcoords.count)
            for point in texcoords { try append(point.x);try append(point.y) }
        }
        try append(placement.translation)
        let rotation=placement.rotation.vector
        try append(rotation.x);try append(rotation.y);try append(rotation.z);try append(rotation.w)
        try append(placement.scale);append(exactness)
    }
    mutating func appendSource(_ source:CADHybridMeshSource) throws {
        append(source.sourceBodyID.raw.uuidString);append(source.name);append(source.sha256)
        // Include actual buffers as well as their stored digest. A modified
        // value cannot hit a cached evaluation by retaining an older SHA.
        try appendGeometry(source.render,placement:source.placement,exactness:source.inputExactness)
    }
    private mutating func flushIfNeeded() {
        if bytes.count>=16_384 { hasher.update(data:bytes);bytes.removeAll(keepingCapacity:true) }
    }
    mutating func finish() -> String {
        if !bytes.isEmpty { hasher.update(data:bytes) }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}

/// Recursive unknown-key protection is separate from Codable: Codable may
/// ignore future fields, while a writable package must preserve their meaning.
nonisolated enum CADHybridStoredJSON {
    static func object(_ raw:Any,keys:Set<String>) throws -> [String:Any] {
        guard let value=raw as? [String:Any],Set(value.keys).isSubset(of:keys) else {
            throw CADHybridFailure.unsupported("This stored geometry record contains unknown fields.")
        };return value
    }
    static func bodyID(_ raw:Any) throws { _=try object(raw,keys:["raw"]) }
}

nonisolated enum CADHybridFailure:Error,LocalizedError,Sendable {
    case invalid(String),unsupported(String),kernel(String),cancelled,timedOut
    var errorDescription:String? {
        switch self {
        case let .invalid(s),let .unsupported(s),let .kernel(s):return s
        case .cancelled:return "The operation was cancelled. The original model was kept."
        case .timedOut:return "The operation reached its time limit. The original model was kept."
        }
    }
    var code:String { switch self { case .invalid:return "invalid_hybrid_request";case .unsupported:return "hybrid_scope_unavailable";case .kernel:return "hybrid_kernel_refused";case .cancelled:return "cancelled";case .timedOut:return "timeout" } }
}
