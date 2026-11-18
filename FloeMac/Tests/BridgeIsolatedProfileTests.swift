// Synthetic-only fixture. Never opens the user's Bridge or Keychain.
import CryptoKit
import Darwin
import Foundation
import Security

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw Failure(message: message) }
}
private func mustFail(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message: message)
}

private final class SyntheticKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private let initial: KeychainIdentityRead?
    init(_ initial: KeychainIdentityRead? = nil) { self.initial = initial }
    func read() -> KeychainIdentityRead {
        lock.lock(); defer { lock.unlock() }
        if let initial { return initial }
        if let bytes { return .found(bytes) }
        return .absent
    }
    func add(_ data: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard bytes == nil else { return errSecDuplicateItem }
        bytes = data; return errSecSuccess
    }
}
private struct SyntheticPair: Encodable {
    let key: Data
    let name: String
    let acceptedAt: Date
    let verification: String?
    let nonce: String?
}
private final class SyntheticCreateRace: @unchecked Sendable {
    private let lock = NSLock()
    private let winner = Data(repeating: 0x23, count: 32)
    private var inserted = false
    func read() -> KeychainIdentityRead {
        lock.lock(); defer { lock.unlock() }
        return inserted ? .found(winner) : .absent
    }
    func add(_ ignored: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        inserted = true
        return errSecDuplicateItem
    }
    var winningPublicKey: Data {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: winner).publicKey.rawRepresentation
    }
}

@main private enum BridgeIsolatedProfileTests {
    static let signing = SigningInformation(identifier: "synthetic", teamIdentifier: "TEST", flags: 0, adHoc: false)
    static func main() throws {
        if CommandLine.arguments == [CommandLine.arguments[0], "--expect-floe-signature"] {
            let signing = try BridgeIdentity.verifiedIsolatedServiceSigning()
            try check(signing.identifier == "org.floeagent.mac.bridgecomponent" && !signing.adHoc,
                      "validated signature does not describe the release helper")
            print("Floe Developer ID helper accepted")
            return
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--expect-rejected-signature"] {
            do {
                _ = try BridgeIdentity.verifiedIsolatedServiceSigning()
            } catch BridgeIdentityError.untrustedIsolatedService {
                print("untrusted helper rejected")
                return
            }
            throw Failure(message: "untrusted helper accepted")
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--legacy-writer" {
            let path = URL(fileURLWithPath: CommandLine.arguments[2])
            FileHandle.standardOutput.write(Data([1]))
            guard try FileHandle.standardInput.read(upToCount: 1)?.count == 1 else { throw Failure(message: "writer input") }
            try Data("legacy late write".utf8).write(to: path, options: .atomic)
            return
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("floe-isolated-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = try BridgePaths(home: base)
        let oldPair = legacy.root.appendingPathComponent("State/paired-clients.json")
        try Data("old data".utf8).write(to: oldPair)
        let profile = try BridgeIsolatedProfile(home: base)
        try check(profile.endpoint.port == 43872 && profile.endpoint.port != 43871, "isolated endpoint")
        try check(BridgeIsolatedProfile.identityService != "org.floeagent.bridge.server", "identity namespace")
        let paths = try BridgePaths(isolated: profile)
        try check(paths.namespace == .isolated && paths.root.path != legacy.root.path, "storage namespace")
        try check(try Data(contentsOf: oldPair) == Data("old data".utf8), "legacy modified during setup")

        let keychain = SyntheticKeychain()
        let first = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
            signing: signing, readIdentity: { keychain.read() }, addIdentity: { keychain.add($0) })
        let reopened = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
            signing: signing, readIdentity: { keychain.read() }, addIdentity: { keychain.add($0) })
        try check(first.publicKey == reopened.publicKey && first.source.contains("bridge-isolated"), "identity not stable")
        try mustFail("legacy path accepted") {
            _ = try BridgeIdentity.resolveIsolatedProduction(paths: legacy, createIfAbsent: true,
                signing: signing, readIdentity: { .absent }, addIdentity: { _ in errSecSuccess })
        }
        try mustFail("denied identity silently replaced") {
            _ = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
                signing: signing, readIdentity: { .denied(errSecAuthFailed) }, addIdentity: { _ in errSecSuccess })
        }
        try mustFail("invalid identity accepted") {
            _ = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
                signing: signing, readIdentity: { .found(Data(repeating: 1, count: 3)) }, addIdentity: { _ in errSecSuccess })
        }
        let race = SyntheticCreateRace()
        let raced = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
            signing: signing, readIdentity: { race.read() }, addIdentity: { race.add($0) })
        try check(raced.publicKey == race.winningPublicKey, "duplicate add replaced concurrent winner")
        try mustFail("unsigned identity creation accepted") {
            _ = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
                signing: SigningInformation(identifier: "ad-hoc", teamIdentifier: "", flags: 2, adHoc: true),
                readIdentity: { .absent }, addIdentity: { _ in errSecSuccess })
        }

        let writer = Process(), input = Pipe(), output = Pipe()
        writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        writer.arguments = ["--legacy-writer", oldPair.path]
        writer.standardInput = input; writer.standardOutput = output
        try writer.run()
        try check(try output.fileHandleForReading.read(upToCount: 1)?.count == 1, "legacy writer start")
        input.fileHandleForWriting.write(Data([1])); try input.fileHandleForWriting.close()
        writer.waitUntilExit()
        try check(writer.terminationStatus == 0, "legacy writer failed")
        try check(try Data(contentsOf: oldPair) == Data("legacy late write".utf8), "legacy write did not happen")
        try check(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("State/paired-clients.json").path), "legacy contaminated isolated state")
        let afterLate = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
            signing: signing, readIdentity: { keychain.read() }, addIdentity: { keychain.add($0) })
        try check(afterLate.publicKey == first.publicKey, "late legacy writer changed isolated identity")
        let isolatedPair = paths.root.appendingPathComponent("State/paired-clients.json")
        let pair = SyntheticPair(key: Data(repeating: 7, count: 32), name: "synthetic", acceptedAt: Date(), verification: nil, nonce: nil)
        try JSONEncoder().encode(["synthetic": pair]).write(to: isolatedPair, options: .atomic)
        let missingKeychain = SyntheticKeychain()
        try mustFail("missing isolated key with existing pairs created a replacement") {
            _ = try BridgeIdentity.resolveIsolatedProduction(paths: paths, createIfAbsent: true,
                signing: signing, readIdentity: { missingKeychain.read() }, addIdentity: { missingKeychain.add($0) })
        }
        if case .absent = missingKeychain.read() {} else { throw Failure(message: "key created despite existing pairs") }

        let symlinkHome = base.appendingPathComponent("symlink-home", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkHome, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlinkHome.appendingPathComponent("Library"), withDestinationURL: legacy.root)
        try mustFail("symlink ancestor accepted") { _ = try BridgePaths(isolated: BridgeIsolatedProfile(home: symlinkHome)) }
        let insecureHome = base.appendingPathComponent("insecure-home", isDirectory: true)
        let insecureNamespace = insecureHome.appendingPathComponent("Library/Application Support/Floe Mac/Isolated Bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: insecureNamespace, withIntermediateDirectories: true)
        guard chmod(insecureNamespace.path, 0o777) == 0 else { throw Failure(message: "chmod fixture") }
        try mustFail("public isolated namespace accepted") { _ = try BridgePaths(isolated: BridgeIsolatedProfile(home: insecureHome)) }
        var mode = stat()
        guard lstat(insecureNamespace.path, &mode) == 0 else { throw Failure(message: "inspect fixture") }
        try check((mode.st_mode & 0o777) == 0o777, "insecure namespace was modified")
        print("isolated profile synthetic checks passed")
    }
}
