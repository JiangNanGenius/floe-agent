// Standalone macOS regression tests for production identity selection and
// BridgeService's actual pairing load. This executable uses injected in-memory
// Keychain operations and temporary directories only: it never opens the real
// Keychain or launches/connects to a Bridge service.
import CryptoKit
import Foundation
import Security

private struct RaceTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw RaceTestFailure(description: message) }
}

private func expectFailure(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw RaceTestFailure(description: message)
}

/// Forces both callers to observe absence before either can attempt an add.
/// The in-memory add has SecItemAdd's create-only success/duplicate semantics.
private final class RacingKeychain: @unchecked Sendable {
    private let condition = NSCondition()
    private var initialReaders = 0
    private var value: Data?
    private(set) var successfulAdds = 0
    private(set) var duplicates = 0

    func read() -> KeychainIdentityRead {
        condition.lock()
        defer { condition.unlock() }
        if initialReaders < 2 {
            initialReaders += 1
            if initialReaders == 2 { condition.broadcast() }
            let deadline = Date().addingTimeInterval(5)
            while initialReaders < 2 {
                guard condition.wait(until: deadline) else { return .failed(errSecInternalError) }
            }
            return .absent
        }
        return value.map(KeychainIdentityRead.found) ?? .absent
    }

    func add(_ data: Data) -> OSStatus {
        condition.lock()
        defer { condition.unlock() }
        if value != nil {
            duplicates += 1
            return errSecDuplicateItem
        }
        value = data
        successfulAdds += 1
        return errSecSuccess
    }

    func snapshot() -> (Data?, Int, Int) {
        condition.lock()
        defer { condition.unlock() }
        return (value, successfulAdds, duplicates)
    }
}

private final class ScriptedKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [KeychainIdentityRead]
    private let addStatus: OSStatus
    private var adds = 0

    init(_ reads: [KeychainIdentityRead], addStatus: OSStatus) {
        self.reads = reads
        self.addStatus = addStatus
    }

    func read() -> KeychainIdentityRead {
        lock.lock()
        defer { lock.unlock() }
        return reads.isEmpty ? .failed(errSecInternalError) : reads.removeFirst()
    }

    func add(_ data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        adds += 1
        return addStatus
    }

    var addCount: Int { lock.withLock { adds } }
}

private final class RaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    private var errors: [String] = []
    func add(_ result: Result<Data, Error>) {
        lock.withLock {
            switch result {
            case .success(let value): values.append(value)
            case .failure(let error): errors.append(String(describing: error))
            }
        }
    }
    func snapshot() -> ([Data], [String]) { lock.withLock { (values, errors) } }
}

private struct LegacyPair: Encodable {
    let key: Data
    let name: String
    let acceptedAt: Date
    let verification: String?
    let nonce: String?
}

@main
private enum IdentityStorageRaceTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeMacIdentityStorageRace-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        try concurrentAbsentCreation(root.appendingPathComponent("concurrent", isDirectory: true))
        try duplicateAndFailureHandling(root.appendingPathComponent("errors", isDirectory: true))
        try await pairingLoadAfterReplacement(root.appendingPathComponent("pairings", isDirectory: true))
        print("IdentityStorageRaceTests passed")
    }

    private static let signing = SigningInformation(identifier: "fixture", teamIdentifier: "TESTTEAM",
                                                     flags: 0, adHoc: false)

    private static func concurrentAbsentCreation(_ root: URL) throws {
        let store = RacingKeychain()
        let results = RaceResults()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                let resolved = try BridgeIdentity.resolveProduction(
                    createIfAbsent: true, signing: signing, storageRoot: root,
                    readIdentity: { store.read() }, addIdentity: { store.add($0) })
                results.add(.success(resolved.signingKey.rawRepresentation))
            } catch {
                results.add(.failure(error))
            }
        }
        let (values, errors) = results.snapshot()
        let (winner, adds, duplicates) = store.snapshot()
        try check(errors.isEmpty, "concurrent identity creation failed: \(errors)")
        try check(values.count == 2 && values[0] == values[1], "concurrent callers selected different identities")
        try check(values.first == winner && adds == 1 && duplicates == 1,
                  "create-only add did not preserve the single winning identity")
    }

    private static func duplicateAndFailureHandling(_ root: URL) throws {
        let original = Curve25519.Signing.PrivateKey().rawRepresentation
        let duplicate = ScriptedKeychain([.absent, .found(original)], addStatus: errSecDuplicateItem)
        let recovered = try BridgeIdentity.resolveProduction(
            createIfAbsent: true, signing: signing, storageRoot: root,
            readIdentity: { duplicate.read() }, addIdentity: { duplicate.add($0) })
        try check(recovered.signingKey.rawRepresentation == original && duplicate.addCount == 1,
                  "duplicate did not re-read the original identity")

        let failureCases: [([KeychainIdentityRead], OSStatus)] = [
            ([.absent], errSecAuthFailed),
            ([.absent, .absent], errSecDuplicateItem),
            ([.absent, .denied(errSecInteractionNotAllowed)], errSecDuplicateItem),
            ([.absent, .failed(errSecAuthFailed)], errSecDuplicateItem),
            ([.absent, .found(Data(repeating: 0, count: 3))], errSecDuplicateItem),
            ([.absent, .found(original)], errSecSuccess), // successful add must re-read the same bytes it wrote
            ([.denied(errSecInteractionNotAllowed)], errSecSuccess),
            ([.failed(errSecAuthFailed)], errSecSuccess)
        ]
        for (reads, status) in failureCases {
            let store = ScriptedKeychain(reads, addStatus: status)
            try expectFailure("Keychain failure or inconsistent re-read was accepted") {
                _ = try BridgeIdentity.resolveProduction(
                    createIfAbsent: true, signing: signing, storageRoot: root,
                    readIdentity: { store.read() }, addIdentity: { store.add($0) })
            }
        }
        let readFailure = ScriptedKeychain([.denied(errSecAuthFailed)], addStatus: errSecSuccess)
        try expectFailure("denied read unexpectedly created an identity") {
            _ = try BridgeIdentity.resolveProduction(
                createIfAbsent: true, signing: signing, storageRoot: root,
                readIdentity: { readFailure.read() }, addIdentity: { readFailure.add($0) })
        }
        try check(readFailure.addCount == 0, "identity add followed a denied read")
    }

    private static func pairingLoadAfterReplacement(_ root: URL) async throws {
        let paths = try BridgePaths(home: root)
        let file = paths.root.appendingPathComponent("State/paired-clients.json")
        let clientKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let id = SHA256.hash(data: clientKey).map { String(format: "%02x", $0) }.joined()
        let valid = try JSONEncoder().encode([id: LegacyPair(key: clientKey, name: "fixture",
            acceptedAt: Date(timeIntervalSince1970: 1_600_000_000), verification: nil, nonce: nil)])
        try valid.write(to: file, options: [.atomic])
        try check(try BridgeIdentity.pairCount(storageRoot: root) == 1, "fixture preflight failed")
        let missingIdentity = ScriptedKeychain([.absent], addStatus: errSecSuccess)
        try expectFailure("existing pairing allowed a replacement identity") {
            _ = try BridgeIdentity.resolveProduction(
                createIfAbsent: true, signing: signing, storageRoot: root,
                readIdentity: { missingIdentity.read() }, addIdentity: { missingIdentity.add($0) })
        }
        try check(missingIdentity.addCount == 0, "existing pairing did not prevent identity creation")
        try check(try Data(contentsOf: file) == valid, "identity refusal modified the pairing store")
        let validService = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey())
        let validPairs = await validService.pairedClients()
        try check(validPairs.count == 1 && validPairs.first?.0 == id, "service did not load the valid pairing")
        let corrupt = Data("{invalid-after-preflight".utf8)
        try corrupt.write(to: file, options: [.atomic])
        try expectFailure("actual service accepted a pairing store damaged after preflight") {
            _ = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey())
        }
        try check(try Data(contentsOf: file) == corrupt, "service modified the damaged pairing store")
        try valid.write(to: file, options: [.atomic])
        try check(try BridgeIdentity.pairCount(storageRoot: root) == 1, "second fixture preflight failed")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try expectFailure("actual service accepted an unreadable pairing entry after preflight") {
            _ = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey())
        }
        var isDirectory: ObjCBool = false
        try check(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue, "service modified the unreadable pairing entry")
        try FileManager.default.removeItem(at: file)
        let service = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey())
        let pairs = await service.pairedClients()
        try check(pairs.isEmpty, "missing pairing store was not treated as empty")
        try check(!FileManager.default.fileExists(atPath: file.path), "loading missing store created a file")

        // A valid store can also change between preflight and actual loading.
        // Capture the preflight identity, atomically replace with a different
        // valid store, and require the real service consumer to fail closed.
        try valid.write(to: file, options: [.atomic])
        let existingSnapshot = try BridgeService.pairStoreSnapshot(at: file)
        let unchanged = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey(),
                                          expectedPairStore: existingSnapshot.identity)
        let unchangedPairs = await unchanged.pairedClients()
        try check(unchangedPairs.count == 1, "unchanged pairing snapshot failed to load")
        let newKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let newID = SHA256.hash(data: newKey).map { String(format: "%02x", $0) }.joined()
        let replacement = try JSONEncoder().encode([newID: LegacyPair(key: newKey, name: "replacement",
            acceptedAt: Date(timeIntervalSince1970: 1_600_000_001), verification: nil, nonce: nil)])
        try replacement.write(to: file, options: [.atomic])
        try expectFailure("service accepted a valid pairing store replaced after preflight") {
            _ = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey(),
                                  expectedPairStore: existingSnapshot.identity)
        }
        try check(try Data(contentsOf: file) == replacement, "service modified the replacement pairing store")

        // Missing at preflight is a distinct identity; a store appearing later
        // must not be silently treated as the original empty snapshot.
        try FileManager.default.removeItem(at: file)
        let missingSnapshot = try BridgeService.pairStoreSnapshot(at: file)
        let unchangedMissing = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey(),
                                                 expectedPairStore: missingSnapshot.identity)
        let unchangedMissingPairs = await unchangedMissing.pairedClients()
        try check(unchangedMissingPairs.isEmpty, "unchanged missing snapshot failed to load")
        try valid.write(to: file, options: [.atomic])
        try expectFailure("service accepted a pairing store created after an absent preflight") {
            _ = try BridgeService(paths: paths, signingKey: Curve25519.Signing.PrivateKey(),
                                  expectedPairStore: missingSnapshot.identity)
        }
        try check(try Data(contentsOf: file) == valid, "service modified the newly appeared pairing store")
    }
}
