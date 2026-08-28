// FloeSkills — skill.create agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Lets the agent author a declarative Floe skill from a name, a short
/// description, and an instruction body (the SKILL.md content). The actual
/// package assembly, validation, persistence and permission grants run in the
/// injected pipeline — the tool never trusts model output to self-install.
public struct SkillCreateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var name: String
        public var description: String
        public var instructions: String
        public var pythonScripts: [SkillBundledPythonScript]?
        public var pythonPackages: [SkillPythonPackageRequirement]?

        public init(
            name: String,
            description: String,
            instructions: String,
            pythonScripts: [SkillBundledPythonScript]? = nil,
            pythonPackages: [SkillPythonPackageRequirement]? = nil
        ) {
            self.name = name
            self.description = description
            self.instructions = instructions
            self.pythonScripts = pythonScripts
            self.pythonPackages = pythonPackages
        }
    }

    public static let name = "skill.create"
    public static let toolDescription =
        "Create a reusable Floe skill from instructions and optional audited pure-Python scripts. Python scripts must accept changing task data through inputJSON rather than rewriting their source. Optional dependencies must be exact PyPI name==version pure-Python wheels with a narrow purpose and capability list. Floe audits scripts and wheels once during installation; later execution of the exact installed script and package set can run without repeated approval, while changed code or broader side effects return to normal approval."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Skill name (letters/numbers; becomes a lowercase identifier)"},
        "description": {"type": "string", "description": "One-line description of when to use this skill"},
        "instructions": {"type": "string", "description": "The skill body (Markdown): steps, conventions, or reference knowledge to reuse"},
        "pythonScripts": {
          "type": "array", "maxItems": 8,
          "description": "Optional UTF-8 pure-Python scripts bundled under scripts/. Use inputJSON for task-specific data.",
          "items": {
            "type": "object",
            "properties": {
              "relativePath": {"type": "string", "description": "Relative path below scripts/, ending in .py"},
              "source": {"type": "string", "description": "Audited Python source, at most 64 KiB"}
            },
            "required": ["relativePath", "source"], "additionalProperties": false
          }
        },
        "pythonPackages": {
          "type": "array", "maxItems": 16,
          "description": "Optional exact, pure-Python PyPI dependencies audited during installation.",
          "items": {
            "type": "object",
            "properties": {
              "spec": {"type": "string", "description": "Exact PyPI name==version"},
              "purpose": {"type": "string", "description": "Why the installed skill needs it"},
              "capabilities": {"type": "array", "maxItems": 16, "items": {"type": "string"}}
            },
            "required": ["spec", "purpose", "capabilities"], "additionalProperties": false
          }
        }
      },
      "required": ["name", "description", "instructions"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxNameBytes = 128
    static let maxDescriptionBytes = 512
    static let maxInstructionsBytes = 256 * 1024
    static let maxScriptBytes = 64 * 1024

    private let creator: any SkillCreating

    public init(creator: any SkillCreating) {
        self.creator = creator
    }

    public func validate(_ args: Arguments) throws {
        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= Self.maxNameBytes else {
            throw FloeError.validationFailed("name must be non-empty and at most \(Self.maxNameBytes) bytes")
        }
        guard !args.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.description.utf8.count <= Self.maxDescriptionBytes else {
            throw FloeError.validationFailed("description must be non-empty and at most \(Self.maxDescriptionBytes) bytes")
        }
        guard !args.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.instructions.utf8.count <= Self.maxInstructionsBytes else {
            throw FloeError.validationFailed("instructions must be non-empty and at most \(Self.maxInstructionsBytes) bytes")
        }
        let scripts = args.pythonScripts ?? []
        let packages = args.pythonPackages ?? []
        guard scripts.count <= 8, packages.count <= 16 else {
            throw FloeError.validationFailed("A skill may bundle at most 8 scripts and 16 packages")
        }
        if !packages.isEmpty, scripts.isEmpty {
            throw FloeError.validationFailed("pythonPackages require at least one bundled Python script")
        }
        var paths = Set<String>()
        for script in scripts {
            let path = script.relativePath
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/").contains(".."),
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "py",
                  paths.insert(path.lowercased()).inserted,
                  !script.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  script.source.utf8.count <= Self.maxScriptBytes else {
                throw FloeError.validationFailed("Python script paths must be unique safe .py paths and source must be 1-65536 bytes")
            }
        }
        for package in packages {
            try ManagedPythonPackageSpecParser.validate(package.spec)
            guard package.spec.components(separatedBy: "==").count == 2,
                  !package.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  package.purpose.utf8.count <= 1_024,
                  !package.capabilities.isEmpty,
                  package.capabilities.count <= 16 else {
                throw FloeError.validationFailed("Skill packages require exact name==version, purpose and 1-16 capabilities")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let skill = try await creator.create(SkillCreationRequest(
                name: args.name,
                description: args.description,
                instructions: args.instructions,
                pythonScripts: args.pythonScripts ?? [],
                pythonPackages: args.pythonPackages ?? []
            ))
            let text = "status=created id=\(skill.id) name=\(skill.name) version=\(skill.version)"
            return Self.output(text, exitStatus: 0)
        } catch {
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
