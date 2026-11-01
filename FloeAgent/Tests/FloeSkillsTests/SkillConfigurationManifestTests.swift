import Foundation
import Testing
@testable import FloeSkills

@Suite("Skill configuration manifest")
struct SkillConfigurationManifestTests {
    private func manifestJSON(_ configuration: [String: Any]? = nil) -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": "alpha",
            "version": "1.0.0",
            "capabilities": ["credentials"],
            "tools": [],
            "platforms": ["ios"],
            "scriptRuntime": "none"
        ]
        if let configuration {
            object["configuration"] = configuration
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> SkillManifest {
        try JSONDecoder().decode(SkillManifest.self, from: data)
    }

    private func writePackage(
        base: URL,
        capabilities: [String] = ["credentials"],
        configuration: [String: Any]
    ) throws -> URL {
        let root = base.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: alpha
        description: A configuration test skill.
        ---

        Use the declared configuration.
        """
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": "alpha",
            "version": "1.0.0",
            "capabilities": capabilities,
            "tools": [],
            "platforms": ["ios"],
            "scriptRuntime": "none",
            "configuration": configuration
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("floe.json"))
        return root
    }

    @Test("Legacy manifests decode with no configuration and keep their shape")
    func legacyManifest() throws {
        let manifest = try decode(manifestJSON())
        #expect(manifest.configuration == nil)
        let encoded = try JSONEncoder().encode(manifest)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("configuration"))
    }

    @Test("Typed declarations decode bilingual text and secret env mappings")
    func typedDeclarations() throws {
        let manifest = try decode(manifestJSON([
            "fields": [
                [
                    "key": "apiBase",
                    "title": ["en": "API base", "zh-Hans": "API 地址"],
                    "description": ["en": "Endpoint", "zh-Hans": "服务地址"],
                    "kind": "variable",
                    "valueType": "url",
                    "required": true
                ],
                [
                    "key": "apiKey",
                    "title": "API key",
                    "kind": "secret",
                    "required": true,
                    "credentialKinds": ["providerAPIKey", "genericToken"]
                ],
                [
                    "key": "bridge",
                    "kind": "connection",
                    "connectionKind": "ios-bridge",
                    "required": true
                ]
            ],
            "environment": [
                ["name": "API_BASE", "field": "apiBase"],
                ["name": "API_KEY", "field": "apiKey"]
            ]
        ]))
        let configuration = try #require(manifest.configuration)
        #expect(configuration.fields.count == 3)
        #expect(configuration.fields[0].title?.value(preferredLanguages: ["zh-Hans"]) == "API 地址")
        #expect(configuration.fields[0].title?.value(preferredLanguages: ["en"]) == "API base")
        #expect(configuration.fields[0].title?.value(preferredLanguages: ["fr"]) == "API base")
        #expect(configuration.fields[1].sensitive)
        #expect(configuration.fields[1].credentialKinds == ["providerAPIKey", "genericToken"])
        #expect(configuration.fields[1].title?.value(preferredLanguages: ["zh-Hans"]) == "API key")
        #expect(configuration.fields[2].kind == .connection)
        #expect(configuration.fields[2].connectionKind == "ios-bridge")
        #expect(configuration.environment.map(\.name) == ["API_BASE", "API_KEY"])
        try configuration.validate()
    }

    @Test("Unsafe or contradictory declarations fail closed")
    func invalidDeclarations() {
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "same", kind: .variable),
                SkillConfigurationField(key: "SAME", kind: .variable)
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "password", kind: .variable, sensitive: true)
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "token", kind: .secret, sensitive: false)
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "token", kind: .secret, defaultValue: "value")
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "bridge", kind: .connection)
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(
                    key: "bridge",
                    kind: .connection,
                    connectionKind: "ios-bridge"
                )
            ], environment: [
                SkillEnvironmentVariable(name: "BRIDGE", field: "bridge")
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "endpoint", kind: .variable)
            ], environment: [
                SkillEnvironmentVariable(name: "PATH", field: "endpoint")
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(key: "endpoint", kind: .variable)
            ], environment: [
                SkillEnvironmentVariable(name: "not-an-env", field: "endpoint")
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(
                    key: "key",
                    kind: .variable,
                    allowedValues: ["a", "b"]
                )
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(
                    key: "key",
                    kind: .variable,
                    credentialKinds: ["genericToken"]
                )
            ]).validate()
        }
        #expect(throws: SkillValidationError.self) {
            try SkillConfigurationRequirements(fields: [
                SkillConfigurationField(
                    key: "key",
                    kind: .secret,
                    credentialKinds: ["genericToken", "genericToken"]
                )
            ]).validate()
        }
    }

    @Test("Package validation requires the credentials capability for secrets")
    func packageValidationCapability() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillConfigManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let configuration: [String: Any] = [
            "fields": [
                [
                    "key": "apiKey",
                    "kind": "secret",
                    "required": true
                ]
            ]
        ]
        let withoutCapability = try writePackage(
            base: base.appendingPathComponent("a"),
            capabilities: ["workspace.read"],
            configuration: configuration
        )
        #expect(throws: SkillValidationError.self) {
            _ = try SkillPackageValidator().validate(packageAt: withoutCapability)
        }

        let withCapability = try writePackage(
            base: base.appendingPathComponent("b"),
            capabilities: ["workspace.read", "credentials"],
            configuration: configuration
        )
        let package = try SkillPackageValidator().validate(packageAt: withCapability)
        #expect(package.manifest.configuration?.fields.count == 1)
        #expect(package.declaredCapabilities.contains(.credentials))
    }

    @Test("Device automation capabilities are explicit and fail closed")
    func deviceCapabilities() throws {
        #expect(SkillCapability(rawValue: "device.observe") == .deviceObserve)
        #expect(SkillCapability(rawValue: "device.interact") == .deviceInteract)
        #expect(SkillCapability(rawValue: "device.shell") == nil)
        #expect(SkillCapability.deviceObserve.rawValue == "device.observe")
        #expect(SkillCapability.deviceInteract.rawValue == "device.interact")
        let manifest = try decode(manifestJSON())
        #expect(manifest.capabilities == ["credentials"])
    }
}
