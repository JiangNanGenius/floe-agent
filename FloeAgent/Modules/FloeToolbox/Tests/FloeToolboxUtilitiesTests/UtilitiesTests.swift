import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxUtilities

@Test func checksumsStreamRealBytesAndMatchKnownVectors() async throws {
    let expected: [ToolboxChecksumAlgorithm:String] = [.sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        .sha512:"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        .sha1:"a9993e364706816aba3e25717850c26c9cd0d89d",.md5:"900150983cd24fb0d6963f7d28e17f72",.crc32:"352441c2"]
    for (algorithm,hex) in expected {
        let result = try await ToolboxFileChecksum.calculate(algorithm,expectedByteCount:3,read:{ offset,maximum in
            Data(Data("abc".utf8).dropFirst(Int(offset)).prefix(maximum))
        })
        #expect(result.hexadecimal == hex && result.byteCount == 3)
        #expect(result.matches(hex.uppercased()))
        #expect(!result.matches("not a hash"))
    }
}
@Test func checksumRejectsReaderOverflowSourceChangeAndCancellation() async throws {
    await #expect(throws:ToolboxError.self) { try await ToolboxFileChecksum.calculate(.sha256,maximumBytes:8,read:{ _,_ in Data(repeating:0,count:10) }) }
    await #expect(throws:ToolboxError.revisionConflict) { try await ToolboxFileChecksum.calculate(.sha256,expectedByteCount:1,read:{ _,_ in Data() }) }
    let task = Task { try await ToolboxFileChecksum.calculate(.sha256,read:{ _,_ in try await Task.sleep(for:.seconds(5)); return Data() }) }
    task.cancel(); await #expect(throws:CancellationError.self) { try await task.value }
}
@Test func jsonRoundtripBoundsAndStringsContainingBrackets() throws {
    let source = #"{"中文":[1,true,null],"quoted":"[ { \\\" } ]"}"#
    let pretty = try ToolboxJSON.format(source)
    #expect(pretty.contains("\n"))
    #expect(try ToolboxJSON.format(pretty,style:.sorted) == ToolboxJSON.format(source,style:.sorted))
    #expect(try ToolboxJSON.format("null",style:.compact) == "null")
    #expect(throws:ToolboxError.self) { try ToolboxJSON.format(String(repeating:"[",count:1000)+String(repeating:"]",count:1000)) }
    #expect(throws:ToolboxError.self) { try ToolboxJSON.format("{invalid}") }
}
@Test func unicodeEncodingRoundtripAndInvalidPayloads() throws {
    let value = "中文 / a+b?x=1&y=2 🧭"
    #expect(try ToolboxTextEncoding.base64Decode(ToolboxTextEncoding.base64Encode(value)) == value)
    let escaped = try ToolboxTextEncoding.urlEncode(value)
    #expect(!escaped.contains("/") && !escaped.contains("+") && escaped.contains("%"))
    #expect(try ToolboxTextEncoding.urlDecode(escaped) == value)
    #expect(throws:ToolboxError.self) { try ToolboxTextEncoding.base64Decode("invalid!!") }
    #expect(throws:ToolboxError.self) { try ToolboxTextEncoding.base64Decode("/w==") }
    #expect(throws:ToolboxError.self) { try ToolboxTextEncoding.urlDecode("%FF%Z1") }
}
@Test func nativeQRImageRoundtripAndImageBounds() throws {
    let value = "https://example.test/工具箱"
    let image = try ToolboxQR.png(text:value,correction:.high)
    #expect(image.starts(with:[137,80,78,71]))
    #expect(try ToolboxQR.read(imageData:image).contains(value))
    #expect(throws:ToolboxError.self) { try ToolboxQR.png(text:"",scale:0) }
    #expect(throws:ToolboxError.self) { try ToolboxQR.read(imageData:Data([0,1])) }
}
