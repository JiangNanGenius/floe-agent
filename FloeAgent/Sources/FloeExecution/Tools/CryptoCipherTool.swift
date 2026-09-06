// FloeExecution — crypto.cipher agent tool.
//
// Auditable encryption and signing on top of crypto.hash. Keys live in the
// device Keychain under names; raw key material never leaves the vault, so a
// conversation cannot exfiltrate it. AES-256-GCM for confidentiality,
// Ed25519 for signatures.

import Foundation
import Crypto
import FloeCore
import FloeSecurity
import FloeTools
import FloeWorkspace

#if canImport(Security)
import Security
#endif

/// Minimal secret-store surface so tests can inject an in-memory fake
/// instead of touching the real Keychain.
public protocol CryptoCipherKeyStore: Sendable {
    func store(account: String, secret: Data) throws
    func read(account: String) throws -> Data
    func delete(account: String) throws
}

extension KeychainStore: CryptoCipherKeyStore {}

/// Encrypts/decrypts and signs/verifies with Keychain-held named keys.
public struct CryptoCipherTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        /// Key name for every action except listKeys.
        public var name: String?
        /// aes256 (default) or ed25519, for generateKey.
        public var kind: String?
        public var text: String?
        public var path: String?
        /// Workspace file for encrypt/decrypt output; text output otherwise.
        public var outputPath: String?
        /// Hex signature, for verify.
        public var signature: String?

        public init(
            action: String,
            name: String? = nil,
            kind: String? = nil,
            text: String? = nil,
            path: String? = nil,
            outputPath: String? = nil,
            signature: String? = nil
        ) {
            self.action = action
            self.name = name
            self.kind = kind
            self.text = text
            self.path = path
            self.outputPath = outputPath
            self.signature = signature
        }
    }

    public static let name = "crypto.cipher"
    public static let toolDescription =
        "Encrypt, decrypt, sign and verify with named keys held in the device Keychain (raw keys are never returned). generateKey (kind aes256 default, or ed25519), deleteKey, listKeys. encrypt/decrypt use AES-256-GCM: input text or a workspace file; output is base64 or a workspace file via outputPath. sign produces an Ed25519 hex signature; verify reports valid=true/false. Key names are lowercase [a-z0-9-]."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["generateKey", "deleteKey", "listKeys", "encrypt", "decrypt", "sign", "verify"]},
        "name": {"type": "string", "description": "Key name: 1-64 chars of [a-z0-9-]"},
        "kind": {"type": "string", "enum": ["aes256", "ed25519"], "description": "Key kind for generateKey (default aes256)"},
        "text": {"type": "string", "description": "UTF-8 input (max 1 MiB); exactly one of text or path"},
        "path": {"type": "string", "description": "Workspace-relative input file; exactly one of text or path"},
        "outputPath": {"type": "string", "description": "Workspace-relative output file for encrypt/decrypt; base64 text output when omitted"},
        "signature": {"type": "string", "description": "Hex Ed25519 signature (verify)"}
      },
      "required": ["action"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.accessesCredentials]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public static let keychainService = "org.floeagent.ios.cipher"
    private static let aesKindByte: UInt8 = 0x01
    private static let ed25519KindByte: UInt8 = 0x02

    private let keychain: any CryptoCipherKeyStore

    public init(keychain: any CryptoCipherKeyStore = KeychainStore(service: Self.keychainService, synchronizable: false)) {
        self.keychain = keychain
    }

    public func validate(_ args: Arguments) throws {
        let actions = ["generateKey", "deleteKey", "listKeys", "encrypt", "decrypt", "sign", "verify"]
        guard actions.contains(args.action) else {
            throw FloeError.validationFailed("action must be one of \(actions.joined(separator: ", "))")
        }
        if args.action != "listKeys" {
            guard let name = args.name, name.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
                throw FloeError.validationFailed("name must be 1-64 chars of lowercase [a-z0-9-]")
            }
        }
        if args.action == "generateKey", let kind = args.kind, kind != "aes256", kind != "ed25519" {
            throw FloeError.validationFailed("kind must be aes256 or ed25519")
        }
        if ["encrypt", "decrypt", "sign", "verify"].contains(args.action) {
            switch (args.text, args.path) {
            case (.some, .some), (nil, nil):
                throw FloeError.validationFailed("Provide exactly one of text or path")
            default:
                break
            }
            if let text = args.text, text.utf8.count > 1_048_576 {
                throw FloeError.validationFailed("text exceeds the 1 MiB limit")
            }
            if let path = args.path {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                      !trimmed.split(separator: "/").contains("..") else {
                    throw FloeError.validationFailed("path must be workspace-relative")
                }
            }
        }
        if let outputPath = args.outputPath {
            let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("outputPath must be workspace-relative")
            }
        }
        if args.action == "verify",
           args.signature?.range(of: #"^[0-9a-fA-F]{128}$"#, options: .regularExpression) == nil {
            throw FloeError.validationFailed("verify requires a 128-hex-character Ed25519 signature")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            switch args.action {
            case "generateKey": return try generateKey(args)
            case "deleteKey": return try deleteKey(args)
            case "listKeys": return try listKeys()
            case "encrypt": return try encrypt(args, context: context)
            case "decrypt": return try decrypt(args, context: context)
            case "sign": return try sign(args, context: context)
            default: return try verify(args, context: context)
            }
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    // MARK: - Key management

    private func generateKey(_ args: Arguments) throws -> ToolExecutionOutput {
        let name = args.name!
        let kind = args.kind ?? "aes256"
        if (try? keychain.read(account: name)) != nil {
            throw FloeError.validationFailed("Key already exists: \(name); delete it first to rotate")
        }
        let material: Data
        if kind == "ed25519" {
            let key = Curve25519.Signing.PrivateKey()
            material = Data([Self.ed25519KindByte]) + key.rawRepresentation
        } else {
            let key = SymmetricKey(size: .bits256)
            material = Data([Self.aesKindByte]) + key.withUnsafeBytes { Data($0) }
        }
        try keychain.store(account: name, secret: material)
        return Self.output("status=ok action=generateKey name=\(name) kind=\(kind) keyMaterial=notReturned", exitStatus: 0)
    }

    private func deleteKey(_ args: Arguments) throws -> ToolExecutionOutput {
        let name = args.name!
        guard (try? keychain.read(account: name)) != nil else {
            throw FloeError.validationFailed("No such key: \(name)")
        }
        try keychain.delete(account: name)
        return Self.output("status=ok action=deleteKey name=\(name)", exitStatus: 0)
    }

    private func listKeys() throws -> ToolExecutionOutput {
        let names = Self.accountNames(service: Self.keychainService)
        var lines = ["status=ok action=listKeys count=\(names.count)"]
        for name in names {
            var kind = "unknown"
            if let material = try? keychain.read(account: name), let first = material.first {
                kind = first == Self.aesKindByte ? "aes256" : first == Self.ed25519KindByte ? "ed25519" : "unknown"
            }
            lines.append("\(name)\t\(kind)")
        }
        return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
    }

    // MARK: - Payload IO

    private func inputData(_ args: Arguments, context: ToolContext) throws -> (Data, String) {
        if let text = args.text {
            return (Data(text.utf8), "text")
        }
        let path = args.path!
        guard let root = context.workspaceRootURL else {
            throw FloeError.invalidConfiguration("No task workspace is available")
        }
        try context.authorizeWorkspacePath(path)
        let guarder = WorkspacePathGuard(rootURL: root)
        let url = try guarder.resolve(path)
        try guarder.assertReadableSize(url)
        return (try Data(contentsOf: url, options: [.mappedIfSafe]), "path=\(path)")
    }

    private func outputResult(
        _ data: Data,
        textEncoding: (Data) -> String,
        args: Arguments,
        context: ToolContext,
        verb: String
    ) throws -> ToolExecutionOutput {
        if let outputPath = args.outputPath {
            guard let root = context.workspaceRootURL else {
                throw FloeError.invalidConfiguration("No task workspace is available")
            }
            try context.authorizeWorkspacePath(outputPath)
            let guarder = WorkspacePathGuard(rootURL: root)
            let url = try guarder.resolve(outputPath)
            try guarder.assertWritable(url)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.validationFailed("Output already exists: \(outputPath)")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return Self.output("status=ok action=\(verb) output=\(outputPath) bytes=\(data.count)", exitStatus: 0)
        }
        return Self.output("status=ok action=\(verb) result=\(textEncoding(data))", exitStatus: 0)
    }

    // MARK: - AES-GCM

    private func symmetricKey(named name: String) throws -> SymmetricKey {
        let material = try keychain.read(account: name)
        guard material.first == Self.aesKindByte, material.count == 33 else {
            throw FloeError.validationFailed("Key \(name) is not an aes256 key")
        }
        return SymmetricKey(data: material.dropFirst())
    }

    private func encrypt(_ args: Arguments, context: ToolContext) throws -> ToolExecutionOutput {
        let (plaintext, _) = try inputData(args, context: context)
        let box = try AES.GCM.seal(plaintext, using: try symmetricKey(named: args.name!))
        guard let combined = box.combined else {
            throw FloeError.internalError("Encryption produced no combined representation")
        }
        return try outputResult(combined, textEncoding: { $0.base64EncodedString() }, args: args, context: context, verb: "encrypt")
    }

    private func decrypt(_ args: Arguments, context: ToolContext) throws -> ToolExecutionOutput {
        let (payload, _) = try inputData(args, context: context)
        let sealed: Data
        if let text = args.text, let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            sealed = decoded
        } else {
            sealed = payload
        }
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(box, using: try symmetricKey(named: args.name!))
        return try outputResult(
            plaintext,
            textEncoding: { String(decoding: $0, as: UTF8.self) },
            args: args,
            context: context,
            verb: "decrypt"
        )
    }

    // MARK: - Ed25519

    private func signingKey(named name: String) throws -> Curve25519.Signing.PrivateKey {
        let material = try keychain.read(account: name)
        guard material.first == Self.ed25519KindByte, material.count == 33 else {
            throw FloeError.validationFailed("Key \(name) is not an ed25519 key")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: material.dropFirst())
    }

    private func sign(_ args: Arguments, context: ToolContext) throws -> ToolExecutionOutput {
        let (payload, _) = try inputData(args, context: context)
        let signature = try signingKey(named: args.name!).signature(for: payload)
        let hex = signature.map { String(format: "%02x", $0) }.joined()
        return Self.output("status=ok action=sign name=\(args.name!) signature=\(hex)", exitStatus: 0)
    }

    private func verify(_ args: Arguments, context: ToolContext) throws -> ToolExecutionOutput {
        let (payload, _) = try inputData(args, context: context)
        let signatureBytes = stride(from: 0, to: args.signature!.count, by: 2).map { index -> UInt8 in
            let start = args.signature!.index(args.signature!.startIndex, offsetBy: index)
            let end = args.signature!.index(start, offsetBy: 2)
            return UInt8(args.signature![start..<end], radix: 16) ?? 0
        }
        let valid = try signingKey(named: args.name!).publicKey.isValidSignature(
            Data(signatureBytes), for: payload
        )
        return Self.output("status=ok action=verify name=\(args.name!) valid=\(valid)", exitStatus: 0)
    }

    // MARK: - Keychain listing

    private static func accountNames(service: String) -> [String] {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        #else
        return KeychainStubListing.accountNames(service: service)
        #endif
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

#if !canImport(Security)
/// Linux-test listing over the same in-memory stub KeychainStore uses.
private enum KeychainStubListing {
    static func accountNames(service: String) -> [String] { [] }
}
#endif
