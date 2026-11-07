// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bounded native research documents. Typed owners validate source/result
/// identity and transition chains before either writing or installing a result.
public enum ResearchArchive {
    public enum Family:String,Codable,Sendable { case manufacturingCell, engineeringAnalysis, virtualMachine }
    private struct Envelope<Input:Codable,Output:Codable>:Codable {
        var formatVersion:Int
        var family:Family
        var input:Input
        var output:Output
        var inputSHA256:String
        var outputSHA256:String
    }
    public static let byteLimit = 64_000_000
    public static func save<Input:Codable,Output:Codable>(input:Input,output:Output,family:Family,to url:URL,
                                                        validate:(Input,Output)throws->Void) throws {
        try validate(input,output)
        let envelope = Envelope(formatVersion:1,family:family,input:input,output:output,
                                inputSHA256:try digest(input),outputSHA256:try digest(output))
        let data = try ManufacturingStudy.encoder.encode(envelope)
        guard data.count <= byteLimit else { throw ManufacturingError.archive("research document byte budget") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    public static func open<Input:Codable,Output:Codable>(_ url:URL,input:Input.Type,output:Output.Type,family:Family,
                                                        validate:(Input,Output)throws->Void) throws -> (Input,Output) {
        try open(data:read(url),input:input,output:output,family:family,validate:validate)
    }
    /// Validates the same envelope from an already bounded, stable source
    /// snapshot. Callers retain their own file identity and ownership fences.
    public static func open<Input:Codable,Output:Codable>(data:Data,input:Input.Type,output:Output.Type,family:Family,
                                                        validate:(Input,Output)throws->Void) throws -> (Input,Output) {
        guard data.count <= byteLimit else { throw ManufacturingError.archive("research document byte budget") }
        let envelope = try JSONDecoder().decode(Envelope<Input,Output>.self,from:data)
        guard envelope.formatVersion == 1, envelope.family == family,
              envelope.inputSHA256 == (try digest(envelope.input)),
              envelope.outputSHA256 == (try digest(envelope.output)) else {
            throw ManufacturingError.archive("research document family/version/digest mismatch")
        }
        try validate(envelope.input,envelope.output)
        return (envelope.input,envelope.output)
    }
    public static func saveInput<Input:Encodable>(_ input:Input,to url:URL) throws {
        let data = try ManufacturingStudy.encoder.encode(input)
        guard data.count <= byteLimit else { throw ManufacturingError.archive("research input byte budget") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    public static func openInput<Input:Decodable>(_ url:URL,as type:Input.Type) throws -> Input {
        try JSONDecoder().decode(type,from:read(url))
    }
    public static func digest<Value:Encodable>(_ value:Value) throws -> String {
        ManufacturingStudy.digest(try ManufacturingStudy.encoder.encode(value))
    }
    private static func read(_ url:URL) throws -> Data {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= byteLimit else {
            throw ManufacturingError.archive("research document file budget")
        }
        let data = try Data(contentsOf:url)
        guard data.count <= byteLimit else { throw ManufacturingError.archive("research document grew beyond budget") }
        return data
    }
}
