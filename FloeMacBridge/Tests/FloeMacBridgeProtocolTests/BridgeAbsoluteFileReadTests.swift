import Foundation
import Testing
@testable import FloeMacBridgeProtocol

@Suite("Absolute Mac file read wire contract")
struct BridgeAbsoluteFileReadTests {
    private func invalid(_ body: () throws -> Void) {
        do { try body(); Issue.record("Malformed absolute-file payload was accepted") }
        catch BridgeFailure.invalidResponse { }
        catch { Issue.record("Wrong response classification: \(error)") }
    }

    private func payload(data: Data, offset: Int64, total: Int64,
                         identity: String = String(repeating: "a", count: 64),
                         sha256: String? = nil) -> [String: BridgeValue] {
        var value: [String: BridgeValue] = [
            "data": .string(data.base64EncodedString()),
            "offset": .integer(offset),
            "totalBytes": .integer(total),
            "identity": .string(identity),
        ]
        if let sha256 { value["sha256"] = .string(sha256) }
        return value
    }

    @Test func absolutePathSyntaxIsDataOnlyAndBounded() {
        #expect(BridgeAbsoluteFileRead.validPath("/Users/fixture/报告 1.png"))
        #expect(BridgeAbsoluteFileRead.validPath("/tmp/file.txt"))
        #expect(!BridgeAbsoluteFileRead.validPath("relative/file.txt"))
        #expect(!BridgeAbsoluteFileRead.validPath("//server/share/file.txt"))
        #expect(!BridgeAbsoluteFileRead.validPath("~/Desktop/file.txt"))
        #expect(!BridgeAbsoluteFileRead.validPath(""))
        #expect(!BridgeAbsoluteFileRead.validPath("/tmp/a\0b"))
        #expect(!BridgeAbsoluteFileRead.validPath("/" + String(repeating: "a", count: 4_096)))
    }

    @Test func identityChangesWithEveryVersionField() {
        let base = BridgeAbsoluteFileRead.identity(
            device: 1, inode: 2, size: 3, modifiedSeconds: 4,
            modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7)
        #expect(base.count == 64)
        #expect(base != BridgeAbsoluteFileRead.identity(
            device: 1, inode: 2, size: 4, modifiedSeconds: 4,
            modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7))
        #expect(base != BridgeAbsoluteFileRead.identity(
            device: 1, inode: 2, size: 3, modifiedSeconds: 9,
            modifiedNanoseconds: 5, changedSeconds: 6, changedNanoseconds: 7))
        // A same-size rewrite that restores mtime still changes ctime.
        #expect(base != BridgeAbsoluteFileRead.identity(
            device: 1, inode: 2, size: 3, modifiedSeconds: 4,
            modifiedNanoseconds: 5, changedSeconds: 9, changedNanoseconds: 7))
    }

    @Test func canonicalSecretExclusionsMatchWorkspaceRules() {
        for path in [
            "/Users/fixture/.ssh/id_ed25519",
            "/Users/fixture/.aws/credentials",
            "/Users/fixture/.gnupg/private-keys-v1.d/x.key",
            "/Users/fixture/project/.env.local",
            "/Users/fixture/project/.env",
            "/Users/fixture/project/id_rsa.pub",
            "/Users/fixture/project/.netrc",
            "/Users/fixture/project/client.pem",
            "/Users/fixture/project/store.p12",
            "/Users/fixture/project/.git/config",
            "/Users/fixture/project/.git/credentials",
        ] {
            #expect(BridgeAbsoluteFileRead.isSecretPath(path), "\(path) must be excluded")
        }
        for path in [
            "/Users/fixture/Pictures/报告 1.png",
            "/tmp/build/output.txt",
            "/Users/fixture/project/environment.swift",
            "/Users/fixture/project/.gitignore",
            "/Users/fixture/project/git/config",
        ] {
            #expect(!BridgeAbsoluteFileRead.isSecretPath(path), "\(path) must stay readable")
        }
    }

    @Test func validChunkAndOptionalReceiptRoundTrip() throws {
        let bytes = Data("absolute mac bytes 图片".utf8)
        let identity = String(repeating: "b", count: 64)
        let digest = String(repeating: "c", count: 64)
        let chunk = try BridgeAbsoluteFileRead.validateChunk(
            payload(data: bytes, offset: Int64(bytes.count), total: Int64(bytes.count) + 5,
                    identity: identity, sha256: digest),
            requestedOffset: 0, requestedLimit: 64)
        #expect(chunk.data == bytes)
        #expect(chunk.offset == Int64(bytes.count))
        #expect(chunk.totalBytes == Int64(bytes.count) + 5)
        #expect(chunk.identity == identity)
        #expect(chunk.sha256 == digest)

        let eof = try BridgeAbsoluteFileRead.validateChunk(
            payload(data: Data(), offset: 0, total: 0),
            requestedOffset: 0, requestedLimit: 1)
        #expect(eof.data.isEmpty && eof.offset == 0 && eof.totalBytes == 0)
    }

    @Test func invalidChunkFieldsNeverBecomeBytes() {
        let data = Data("abc".utf8)
        // Wrong returned position.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 4, total: 3), requestedOffset: 0, requestedLimit: 8)
        }
        // The response cannot extend beyond its own total.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 3, total: 2), requestedOffset: 0, requestedLimit: 8)
        }
        // Multi-chunk readers reject replacement before trusting bytes.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 3, total: 3,
                        identity: String(repeating: "d", count: 64)),
                requestedOffset: 0, requestedLimit: 8,
                expectedIdentity: String(repeating: "a", count: 64))
        }
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 3, total: 4), requestedOffset: 0, requestedLimit: 8,
                expectedTotal: 3)
        }
        // Empty is only valid at EOF.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: Data(), offset: 0, total: 3), requestedOffset: 0, requestedLimit: 8)
        }
        // Oversized and malformed payloads.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 3, total: 3), requestedOffset: 0, requestedLimit: 2)
        }
        invalid {
            var value = payload(data: data, offset: 3, total: 3)
            value["identity"] = .string("not-a-digest")
            _ = try BridgeAbsoluteFileRead.validateChunk(value, requestedOffset: 0, requestedLimit: 8)
        }
        invalid {
            var value = payload(data: data, offset: 3, total: 3)
            value["sha256"] = .string("not-a-digest")
            _ = try BridgeAbsoluteFileRead.validateChunk(value, requestedOffset: 0, requestedLimit: 8)
        }
        // Non-base64 data.
        invalid {
            var value = payload(data: data, offset: 3, total: 3)
            value["data"] = .string("!!!")
            _ = try BridgeAbsoluteFileRead.validateChunk(value, requestedOffset: 0, requestedLimit: 8)
        }
        // A zero/negative limit is not a read request.
        invalid {
            _ = try BridgeAbsoluteFileRead.validateChunk(
                payload(data: data, offset: 3, total: 3), requestedOffset: 0, requestedLimit: 0)
        }
    }
}
