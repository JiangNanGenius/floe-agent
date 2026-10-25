// FloeSkillsTests — strict managed runtime-component descriptor v1 + static ELF gate.
//
// Locks the frozen contract the app-side component center consumes:
//   * exact seven-key schema, fixed constants, strict patterns, cross-field
//     artifact path, exact integer sizes, lowercase 64-hex digests;
//   * unknown/missing/foreign fields (URL/repository/command/approval/
//     environment overrides can never exist) fail closed;
//   * numeric segments are ASCII digits only (Unicode numerals rejected);
//   * the ELF gate accepts only ELF64 LE RISC-V ET_EXEC with a bounded
//     program-header table and NO PT_INTERP — never a general executable bypass.
//
// The positive fixture is the byte-exact published descriptor (its content is
// public; no private material is embedded).

import Foundation
import Testing
@testable import FloeSkills

// MARK: - Fixtures

/// The byte-exact frozen descriptor (published at the Hub repository).
private let frozenDescriptorBytes = Data("""
    {"artifact":{"path":"engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable","sha256":"af8795bf9636e763541c58ef90ee889941e468f453ec6580c32a89a5a758b87b","size":5579704},"captureContract":{"sha256":"baf2453164be6162703af9d671be16da152fa874db53ce95ad5b3516d40de4a3","version":1},"componentID":"impeccable-engine","componentVersion":"0.1.17+floe.1.0.0","minimumAppVersion":"1.7.59","schemaVersion":1,"target":{"arch":"riscv64","format":"elf64-little-riscv-exec-static","os":"linux","triple":"riscv64gc-unknown-linux-musl"}}
    """.utf8)

private let frozenDescriptorSHA256 = "cec4a7fade52f6383f74bc9e15972b911552b2672eada138d890e353899be50a"

private let frozenArtifactSHA256 = "af8795bf9636e763541c58ef90ee889941e468f453ec6580c32a89a5a758b87b"
private let frozenContractSHA256 = "baf2453164be6162703af9d671be16da152fa874db53ce95ad5b3516d40de4a3"

/// Builds a mutable descriptor dictionary with coherent defaults; tests tweak
/// one field at a time.
private func makeDescriptorDictionary(
    schemaVersion: Any = 1,
    componentID: Any = "impeccable-engine",
    componentVersion: Any = "0.1.17+floe.1.0.0",
    minimumAppVersion: Any = "1.7.59",
    target: Any = [
        "os": "linux", "arch": "riscv64",
        "triple": "riscv64gc-unknown-linux-musl",
        "format": "elf64-little-riscv-exec-static"
    ],
    artifact: Any = [
        "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
        "size": 5579704,
        "sha256": frozenArtifactSHA256
    ],
    captureContract: Any = ["version": 1, "sha256": frozenContractSHA256],
    extraTopLevel: [String: Any] = [:]
) -> [String: Any] {
    var object: [String: Any] = [
        "schemaVersion": schemaVersion,
        "componentID": componentID,
        "componentVersion": componentVersion,
        "minimumAppVersion": minimumAppVersion,
        "target": target,
        "artifact": artifact,
        "captureContract": captureContract
    ]
    for (key, value) in extraTopLevel { object[key] = value }
    return object
}

private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Builds a synthetic ELF64 with the given shape for the structural gate.
private func makeELF64(
    eiClass: UInt8 = 2,
    eiData: UInt8 = 1,
    eiVersion: UInt8 = 1,
    eType: UInt16 = 2,
    eMachine: UInt16 = 243,
    eVersion: UInt32 = 1,
    phoff: UInt64 = 64,
    phentsize: UInt16 = 56,
    phnum: UInt16 = 1,
    programHeaders: [(type: UInt32, offset: UInt64)] = [(1, 64)]
) -> Data {
    var bytes = Data(count: 64)
    bytes[0] = 0x7F; bytes[1] = UInt8(ascii: "E"); bytes[2] = UInt8(ascii: "L"); bytes[3] = UInt8(ascii: "F")
    bytes[4] = eiClass; bytes[5] = eiData; bytes[6] = eiVersion
    func put16(_ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF); bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    func put32(_ offset: Int, _ value: UInt32) {
        put16(offset, UInt16(value & 0xFFFF)); put16(offset + 2, UInt16((value >> 16) & 0xFFFF))
    }
    func put64(_ offset: Int, _ value: UInt64) {
        put32(offset, UInt32(value & 0xFFFFFFFF)); put32(offset + 4, UInt32((value >> 32) & 0xFFFFFFFF))
    }
    put16(16, eType); put16(18, eMachine); put32(20, eVersion)
    put64(32, phoff); put16(54, phentsize); put16(56, phnum)
    let total = Int(phoff) + Int(phnum) * Int(phentsize)
    if bytes.count < total { bytes.append(Data(count: total - bytes.count)) }
    for (index, header) in programHeaders.enumerated() {
        let offset = Int(phoff) + index * Int(phentsize)
        put32(offset, header.type)
    }
    return bytes
}

// MARK: - Decode: frozen positive

/// Explicit suite identity for deterministic App-host test selection.
@Suite struct SkillRuntimeDependencyTests {
    @Test func frozenDescriptorDecodesExactly() throws {
        let descriptor = try SkillRuntimeDependency.decode(frozenDescriptorBytes)
        #expect(descriptor.schemaVersion == 1)
        #expect(descriptor.componentID == "impeccable-engine")
        #expect(descriptor.componentVersion == "0.1.17+floe.1.0.0")
        #expect(descriptor.minimumAppVersion == "1.7.59")
        #expect(descriptor.target.os == "linux")
        #expect(descriptor.target.arch == "riscv64")
        #expect(descriptor.target.triple == "riscv64gc-unknown-linux-musl")
        #expect(descriptor.target.format == "elf64-little-riscv-exec-static")
        #expect(descriptor.artifact.path == "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable")
        #expect(descriptor.artifact.size == 5_579_704)
        #expect(descriptor.artifact.sha256 == frozenArtifactSHA256)
        #expect(descriptor.captureContract.version == 1)
        #expect(descriptor.captureContract.sha256 == frozenContractSHA256)
        #expect(SkillRuntimeDependency.isCaptureContractVersionSupported(descriptor.captureContract.version))
    }

    @Test func frozenDescriptorDigestMatchesPublication() {
        #expect(FloeDigest.sha256Hex(frozenDescriptorBytes) == frozenDescriptorSHA256)
        #expect(SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(frozenDescriptorSHA256))
    }

    // MARK: - Decode: structural negatives

    @Test func topLevelArrayFailsClosed() {
        #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted forbidden key '\(key)'") {
            _ = try SkillRuntimeDependency.decode(Data("[1,2,3]".utf8))
        }
    }

    @Test func oversizedDescriptorFailsClosed() {
        var bytes = frozenDescriptorBytes
        bytes.append(Data(count: SkillRuntimeDependency.maximumDescriptorBytes))
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(bytes)
        }
    }

    @Test func unknownTopLevelFieldsFailClosed() throws {
        let object = makeDescriptorDictionary(extraTopLevel: ["url": "https://evil.example/x"])
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
    }

    @Test func overrideLikeFieldsCanNeverExist() throws {
        // URL / repository / command / approval / environment overrides are not
        // part of the schema: exact-key enforcement rejects every one of them.
        for key in ["url", "repository", "repo", "command", "installCommand", "approval", "approved",
                    "environment", "environmentID", "grant", "permissions"] {
            let object = makeDescriptorDictionary(extraTopLevel: [key: "x"])
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
    }

    @Test func missingTopLevelFieldsFailClosed() throws {
        var object = makeDescriptorDictionary()
        object["captureContract"] = nil
        #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted componentVersion '\(invalid)'") {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
    }

    @Test func wrongSchemaVersionFailsClosed() throws {
        let object = makeDescriptorDictionary(schemaVersion: 2)
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
    }

    @Test func unknownComponentFailsClosed() throws {
        let object = makeDescriptorDictionary(componentID: "other-engine")
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        #expect(throws: SkillRuntimeDependencyError.unsupportedComponent("other-engine")) {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
    }

    // MARK: - Decode: version patterns

    @Test func componentVersionPatterns() throws {
        for valid in ["0.1.17+floe.1.0.0", "1.0.0+floe.0.0.1", "10.20.30+floe.40.50.60"] {
            let object = makeDescriptorDictionary(componentVersion: valid)
            let descriptor = try SkillRuntimeDependency.decode(try encode(object))
            #expect(descriptor.componentVersion == valid)
        }
        for invalid in ["0.1.17", "0.1.17+floe.1.0", "0.1.17+floe.1.0.0.0", "01.1.17+floe.1.0.0",
                        "0.1.17+floe.01.0.0", "0.1. 17+floe.1.0.0", "0.1.17+floe.1.0.a", ""] {
            let object = makeDescriptorDictionary(componentVersion: invalid)
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
    }

    @Test func nonASCIIComponentVersionFailsClosed() throws {
        // Unicode-Indic digit U+0667 looks like 7 but is not an ASCII digit.
        let object = makeDescriptorDictionary(componentVersion: "0.1.1٧+floe.1.0.0")
        #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted minimumAppVersion '\(invalid)'") {
            _ = try SkillRuntimeDependency.decode(try encode(object))
        }
    }

    @Test func minimumAppVersionMustBeNumericTriple() throws {
        for invalid in ["1.7", "1.7.59.1", "v1.7.59", "1.07.59", "1.7.x"] {
            let object = makeDescriptorDictionary(minimumAppVersion: invalid)
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
    }

    // MARK: - Decode: target / artifact / contract

    @Test func targetConstantsAreFixed() throws {
        for target in [
            ["os": "macos", "arch": "riscv64", "triple": "riscv64gc-unknown-linux-musl", "format": "elf64-little-riscv-exec-static"],
            ["os": "linux", "arch": "arm64", "triple": "riscv64gc-unknown-linux-musl", "format": "elf64-little-riscv-exec-static"],
            ["os": "linux", "arch": "riscv64", "triple": "aarch64-linux-gnu", "format": "elf64-little-riscv-exec-static"],
            ["os": "linux", "arch": "riscv64", "triple": "riscv64gc-unknown-linux-musl", "format": "elf64-little-arm"]
        ] {
            let object = makeDescriptorDictionary(target: target)
            #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted artifact path '\(path)'") {
                _ = try SkillRuntimeDependency.decode(try encode(object))
            }
        }
        // Unknown nested key is rejected too.
        let extra = makeDescriptorDictionary(target: [
            "os": "linux", "arch": "riscv64", "triple": "riscv64gc-unknown-linux-musl",
            "format": "elf64-little-riscv-exec-static", "cc": "riscv64-linux-musl-gcc"
        ])
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(extra))
        }
    }

    @Test func artifactPathCrossFieldDriftFailsClosed() throws {
        for path in [
            "engines/impeccable/dist/impeccable-0.1.18+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
            "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/aarch64-linux-gnu/floe-impeccable",
            "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable2",
            "engines/impeccable/dist/floe-impeccable",
            "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/../floe-impeccable",
            "/engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
            "engines\\impeccable\\dist\\impeccable-0.1.17+floe.1.0.0\\riscv64gc-unknown-linux-musl\\floe-impeccable"
        ] {
            let object = makeDescriptorDictionary(artifact: [
                "path": path, "size": 5579704, "sha256": frozenArtifactSHA256
            ])
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
        // Path length bound.
        let long = makeDescriptorDictionary(artifact: [
            "path": String(repeating: "a", count: 300), "size": 5579704, "sha256": frozenArtifactSHA256
        ])
        #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted size \(size)") {
            _ = try SkillRuntimeDependency.decode(try encode(long))
        }
    }

    @Test func artifactSizeMustBeExactIntegerInRange() throws {
        for size in [0, -1, SkillRuntimeDependency.maximumArtifactBytes + 1] {
            let object = makeDescriptorDictionary(artifact: [
                "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
                "size": size, "sha256": frozenArtifactSHA256
            ])
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
        // Non-integral JSON number is not an exact integer size.
        let fractional = makeDescriptorDictionary(artifact: [
            "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
            "size": 5.5, "sha256": frozenArtifactSHA256
        ])
        #expect(throws: SkillRuntimeDependencyError.self, "unexpectedly accepted sha256 '\(sha.prefix(16))…'") {
            _ = try SkillRuntimeDependency.decode(try encode(fractional))
        }
        // Booleans are not integers.
        let boolean = makeDescriptorDictionary(artifact: [
            "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
            "size": true, "sha256": frozenArtifactSHA256
        ])
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(boolean))
        }
        // Range edges decode.
        for edge in [1, SkillRuntimeDependency.maximumArtifactBytes] {
            let object = makeDescriptorDictionary(artifact: [
                "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
                "size": edge, "sha256": frozenArtifactSHA256
            ])
            let descriptor = try SkillRuntimeDependency.decode(try encode(object))
            #expect(descriptor.artifact.size == edge)
        }
    }

    @Test func digestsMustBeLowercase64Hex() throws {
        for sha in [frozenArtifactSHA256.uppercased(), String(frozenArtifactSHA256.dropFirst()),
                    String(frozenArtifactSHA256 + "0"), String(repeating: "g", count: 64)] {
            let object = makeDescriptorDictionary(artifact: [
                "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
                "size": 5579704, "sha256": sha
            ])
            #expect(throws: SkillRuntimeDependencyError.self) {
                _ = try SkillRuntimeDependency.decode(try encode(object))
        }
        }
        let badContract = makeDescriptorDictionary(captureContract: ["version": 1, "sha256": frozenContractSHA256.uppercased()])
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(badContract))
        }
    }

    @Test func captureContractVersionGate() throws {
        let zero = makeDescriptorDictionary(captureContract: ["version": 0, "sha256": frozenContractSHA256])
        #expect(throws: SkillRuntimeDependencyError.self) {
            _ = try SkillRuntimeDependency.decode(try encode(zero))
        }
        // A future positive version parses per schema; the CENTER rejects
        // unsupported versions before download/probe (see FloeApp tests).
        let future = makeDescriptorDictionary(captureContract: ["version": 2, "sha256": frozenContractSHA256])
        let descriptor = try SkillRuntimeDependency.decode(try encode(future))
        #expect(descriptor.captureContract.version == 2)
        #expect(!SkillRuntimeDependency.isCaptureContractVersionSupported(2))
    }

    // MARK: - Helpers

    @Test func appVersionCompatibility() {
        #expect(SkillRuntimeDependency.isCompatible(minimumAppVersion: "1.7.59", appVersion: "1.7.59"))
        #expect(SkillRuntimeDependency.isCompatible(minimumAppVersion: "1.7.59", appVersion: "1.8.0"))
        #expect(!SkillRuntimeDependency.isCompatible(minimumAppVersion: "1.7.59", appVersion: "1.7.58"))
        #expect(!SkillRuntimeDependency.isCompatible(minimumAppVersion: "1.7.59", appVersion: "0.0.0"))
        #expect(!SkillRuntimeDependency.isCompatible(minimumAppVersion: "1.7.59", appVersion: "1.7"))
    }

    @Test func expectedHelpersAreExact() {
        #expect(SkillRuntimeDependency.expectedArtifactPath(
            componentVersion: "0.1.17+floe.1.0.0", triple: "riscv64gc-unknown-linux-musl"
        ) == "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable")
        #expect(SkillRuntimeDependency.expectedProbeStdout(componentVersion: "0.1.17+floe.1.0.0")
                == "impeccable-engine 0.1.17+floe.1.0.0\n")
    }

    // MARK: - ELF gate

    @Test func elfAcceptsStaticRISCVExec() throws {
        let bytes = makeELF64()
        try SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)
    }

    @Test func elfRejectsNonExecTypes() {
        for type: UInt16 in [1, 3] { // ET_REL, ET_DYN
            let bytes = makeELF64(eType: type)
            #expect(throws: SkillRuntimeDependencyError.self) {
                try SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)
            }
        }
    }

    @Test func elfRejectsForeignMachines() {
        for machine: UInt16 in [0x28, 62, 183] { // ARM, x86-64, AArch64
            let bytes = makeELF64(eMachine: machine)
            #expect(throws: SkillRuntimeDependencyError.self) {
                try SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)
            }
        }
    }

    @Test func elfRejectsInterpreter() {
        let bytes = makeELF64(phnum: 2, programHeaders: [(1, 64), (3, 64 + 56)])
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)
        }
    }

    @Test func elfRejectsMalformedHeaders() {
        // Truncated.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(Data(count: 32))
        }
        // Bad magic.
        var badMagic = makeELF64(); badMagic[0] = 0x00
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(badMagic)
        }
        // ELF32 class.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(eiClass: 1))
        }
        // Big-endian data encoding.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(eiData: 2))
        }
        // Wrong e_ident version.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(eiVersion: 2))
        }
        // e_version mismatch.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(eVersion: 2))
        }
        // Program-header entry size must be 56.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(phentsize: 64))
        }
        // phnum bounds.
        for phnum: UInt16 in [0, 257] {
            #expect(throws: SkillRuntimeDependencyError.self) {
                try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(phnum: phnum))
            }
        }
        // Program-header table outside the file.
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(phoff: 4096))
        }
        #expect(throws: SkillRuntimeDependencyError.self) {
            try SkillRuntimeDependency.verifyStaticRISCVExecELF(makeELF64(phnum: 3, programHeaders: [(1, 64)]))
        }
    }
}
