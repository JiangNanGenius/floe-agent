import Foundation
import PDFKit
import FloeCore
import FloeTools
import FloeSecurity

/// Credentials stay inside the approved executor; only the new file path and
/// verification result leave it. No plaintext argument or old-name alias.
struct PDFUnlockTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var inputPath: String
        var outputPath: String
        var passwordRef: String
    }
    static let name = "document.pdf.unlock"
    static let toolDescription = "Create a new unlocked PDF using a saved credential reference. Requires approval, correct PDF password and modification permission; signed PDFs are refused. Never overwrites any file. The password is resolved only inside the executor and never returned. Inspect/edit the verified new copy afterwards."
    static let parametersJSON = #"{"type":"object","properties":{"inputPath":{"type":"string"},"outputPath":{"type":"string"},"passwordRef":{"type":"string","description":"Saved ⟨credential:UUID⟩ reference, never a plaintext password"}},"required":["inputPath","outputPath","passwordRef"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .accessesCredentials]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    private let resolver: @MainActor @Sendable (UUID) async throws -> Data

    init(resolver: @escaping @MainActor @Sendable (UUID) async throws -> Data) { self.resolver = resolver }

    func validate(_ args: Arguments) throws {
        try PDFToolSupport.validatePath(args.inputPath)
        try PDFToolSupport.validatePath(args.outputPath)
        guard args.inputPath != args.outputPath, SecretIngressScanner.credentialID(from: args.passwordRef) != nil else {
            throw FloeError.validationFailed("PDF unlock requires a new output and a saved credential reference")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        guard context.approvalGrantID != nil, let id = SecretIngressScanner.credentialID(from: args.passwordRef) else { throw FloeError.unauthorized }
        let input = try PDFToolSupport.read(args.inputPath, context: context)
        let secret = try await resolver(id)
        guard let password = String(data: secret, encoding: .utf8), !password.isEmpty, password.utf8.count <= 200 else {
            throw FloeError.validationFailed("PDF password credential is invalid")
        }
        try context.cancellation.throwIfCancelled()
        let output = try await Task.detached { try FloePDFiumBridge.unlock(input, password: password) }.value
        try context.cancellation.throwIfCancelled()
        guard let pageCount = try PDFKitGate.run({ () throws -> Int? in
            guard let reopened = PDFDocument(data: output), !reopened.isLocked, reopened.pageCount > 0 else { return nil }
            return reopened.pageCount
        }) else { throw FloeError.storageCorrupted("Decrypted PDF failed to reopen") }
        try PDFToolSupport.write(output, to: args.outputPath, context: context)
        return PDFToolSupport.output("Saved verified unlocked copy: \(args.outputPath); pages=\(pageCount); originalPreserved=true; secretReturned=false", status: 0)
    }
}
