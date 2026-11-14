// ARM64MachineConfig.swift — caller-supplied, validated machine shape.
//
// The config is deliberately a plain value: the app service owns ONE resident
// ARM64 machine, so CPU/RAM are one global preference applied here, never
// per-project settings. Boot assets must arrive caller-authorized and
// pre-verified (the registry image gate is the later cutover point); the
// adapter re-hashes the bytes before create so a swapped file fails before
// the engine ever sees it. The private writable disk is the caller's own
// sandbox copy — never a bundle path, never a shared/base image.
//
// ABI discipline: this layer builds `floe_ae_config_v3` for
// FLOE_AE_ABI_VERSION == 3. Version 3 keeps the version-2 device contract
// byte-for-byte and appends the opt-in online memory section: when
// `onlineMemoryEnabled` is true the engine boots with <=256 MiB visible RAM
// and the guest virtio-mem driver plugs the managed region up to `ramMiB`,
// allowing live memory budget changes without a restart. When false the
// version-2 single-mapping behavior is preserved exactly. The runtime check
// below refuses to build for any other engine ABI, so a staged struct is
// never reinterpreted as a newer layout.

import Foundation
import CryptoKit
import FloeARM64Engine

/// One verified boot asset (firmware is mandatory; kernel/initrd are an
/// optional pair — initrd without kernel is rejected by both this layer and
/// the engine).
public struct ARM64VerifiedBootAsset: Sendable, Equatable {
    public var path: String
    /// SHA-256 of the exact bytes the caller authorized (registry image
    /// manifest digest format).
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// One contained host 9P share (host directory resolved and pinned at
/// create/attach; read-only flag is whole-tree). Guest uid/gid are synthetic
/// ownership presented to the guest only — they are never forwarded to a
/// host chown (guest chown is refused EPERM by the engine).
public struct ARM64ShareConfig: Sendable, Equatable {
    public var hostPath: String
    /// 9P2000.L mount tag, 1...127 bytes, unique within the config; for
    /// attach it must equal the slot's fixed tag.
    public var mountTag: String
    public var readOnly: Bool
    public var guestUID: UInt32
    public var guestGID: UInt32

    public init(
        hostPath: String,
        mountTag: String,
        readOnly: Bool,
        guestUID: UInt32 = 0,
        guestGID: UInt32 = 0
    ) {
        self.hostPath = hostPath
        self.mountTag = mountTag
        self.readOnly = readOnly
        self.guestUID = guestUID
        self.guestGID = guestGID
    }
}

/// One host-loopback port forward. Listeners always bind host loopback only;
/// guest side is 10.0.2.15.
public struct ARM64NetForwardRule: Sendable, Equatable {
    public var isUDP: Bool
    public var hostPort: UInt32
    public var guestPort: UInt32

    public init(isUDP: Bool, hostPort: UInt32, guestPort: UInt32) {
        self.isUDP = isUDP
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

/// Immutable possible machine topology + device config for one create call.
public struct ARM64MachineConfig: Sendable, Equatable {
    /// Engine ABI the staged config targets; pinned to the header constant.
    public static var engineABIVersion: UInt32 { UInt32(FLOE_AE_ABI_VERSION) }

    public var firmware: ARM64VerifiedBootAsset
    public var kernel: ARM64VerifiedBootAsset?
    public var initrd: ARM64VerifiedBootAsset?
    public var commandLine: String?
    /// Caller-owned private writable disk image (regular file). Required.
    public var privateWritableDiskPath: String
    /// Guest RAM, 16...1024 MiB (engine bounds). With `onlineMemoryEnabled`
    /// this is the total live budget: the engine boots with <=256 MiB visible
    /// and the guest driver plugs the managed region up to this value, and it
    /// can be changed while the machine runs.
    public var ramMiB: Int
    /// ABI v3 online memory (virtio-mem). True: live memory budget changes
    /// without restart. False: exact version-2 single-mapping behavior.
    /// Defaults to false so legacy/native callers (and images whose initrd
    /// lacks the module) keep the fixed-RAM path; the resident factory opts
    /// in explicitly per image capability.
    public var onlineMemoryEnabled: Bool
    public var gpuEnabled: Bool
    /// A resident Linux environment can use its CPU when its optional renderer is unavailable.
    /// Callers that require GPU execution keep the default strict behavior.
    public var gpuAllowsCPUFallback: Bool
    public var gpuBudgetMiB: Int
    public var gpuAppGroupIdentifier: String?
    /// Immutable possible vCPU count, 1...FLOE_AE_MAX_VCPUS. The engine may
    /// run harts concurrently within this topology; it is never mutated
    /// online (a shape change is a full stop → create cycle).
    public var possibleVCPUs: Int
    /// Extra virtio-consoles beyond the PL011 (channel 0), 0...MAX_CONSOLES.
    public var virtioConsoles: Int
    public var networkEnabled: Bool
    /// Optional dotted-quad resolver override; nil asks the engine to probe
    /// the host resolver honestly (it never fabricates a public DNS).
    public var dnsServerIPv4: String?
    public var shares: [ARM64ShareConfig]
    public var forwards: [ARM64NetForwardRule]
    /// Console input ring capacity; 0 = engine default 64 KiB. Otherwise
    /// 256...1 MiB.
    public var inputCapacity: Int
    /// Console output ring capacity; 0 = engine default 1 MiB. Otherwise
    /// 4 KiB...16 MiB.
    public var outputCapacity: Int

    public init(
        firmware: ARM64VerifiedBootAsset,
        kernel: ARM64VerifiedBootAsset? = nil,
        initrd: ARM64VerifiedBootAsset? = nil,
        commandLine: String? = nil,
        privateWritableDiskPath: String,
        ramMiB: Int,
        possibleVCPUs: Int,
        onlineMemoryEnabled: Bool = false,
        gpuEnabled: Bool = false,
        gpuAllowsCPUFallback: Bool = false,
        gpuBudgetMiB: Int = 1024,
        gpuAppGroupIdentifier: String? = nil,
        virtioConsoles: Int = 0,
        networkEnabled: Bool = false,
        dnsServerIPv4: String? = nil,
        shares: [ARM64ShareConfig] = [],
        forwards: [ARM64NetForwardRule] = [],
        inputCapacity: Int = 0,
        outputCapacity: Int = 0
    ) {
        self.firmware = firmware
        self.kernel = kernel
        self.initrd = initrd
        self.commandLine = commandLine
        self.privateWritableDiskPath = privateWritableDiskPath
        self.ramMiB = ramMiB
        self.possibleVCPUs = possibleVCPUs
        self.onlineMemoryEnabled = onlineMemoryEnabled
        self.gpuEnabled = gpuEnabled
        self.gpuAllowsCPUFallback = gpuAllowsCPUFallback
        self.gpuBudgetMiB = gpuBudgetMiB
        self.gpuAppGroupIdentifier = gpuAppGroupIdentifier
        self.virtioConsoles = virtioConsoles
        self.networkEnabled = networkEnabled
        self.dnsServerIPv4 = dnsServerIPv4
        self.shares = shares
        self.forwards = forwards
        self.inputCapacity = inputCapacity
        self.outputCapacity = outputCapacity
    }

    /// Fail-closed local validation. Everything here is re-checked by the
    /// engine; catching caller errors before create keeps the one-live-machine
    /// slot free for an immediate retry.
    public func validated() throws -> ARM64MachineConfig {
        guard Self.engineABIVersion == 3 else {
            throw ARM64MachineError.invalidConfiguration(
                "engine ABI version is \(Self.engineABIVersion); this adapter pins ABI 3 and never reinterprets a newer config layout"
            )
        }
        guard possibleVCPUs >= 1 && possibleVCPUs <= Int(FLOE_AE_MAX_VCPUS) else {
            throw ARM64MachineError.invalidConfiguration(
                "possibleVCPUs must be 1...\(FLOE_AE_MAX_VCPUS), got \(possibleVCPUs)"
            )
        }
        guard ramMiB >= 16 && ramMiB <= 1024 else {
            throw ARM64MachineError.invalidConfiguration("ramMiB must be 16...1024, got \(ramMiB)")
        }
        guard !onlineMemoryEnabled || ramMiB >= 256 else {
            throw ARM64MachineError.invalidConfiguration("online memory requires at least 256 MiB")
        }
        guard (1...2048).contains(gpuBudgetMiB) else {
            throw ARM64MachineError.invalidConfiguration("GPU budget must be 1...2048 MiB")
        }
        if let group = gpuAppGroupIdentifier,
           (!group.hasPrefix("group.") || group.utf8.contains(0)) {
            throw ARM64MachineError.invalidConfiguration("invalid GPU App Group identifier")
        }
        guard initrd == nil || kernel != nil else {
            throw ARM64MachineError.invalidConfiguration("initrd requires a kernel path")
        }
        guard !privateWritableDiskPath.isEmpty else {
            throw ARM64MachineError.invalidConfiguration("private writable disk path is required")
        }
        guard virtioConsoles >= 0 && virtioConsoles <= Int(FLOE_AE_MAX_CONSOLES) else {
            throw ARM64MachineError.invalidConfiguration(
                "virtioConsoles must be 0...\(FLOE_AE_MAX_CONSOLES), got \(virtioConsoles)"
            )
        }
        guard shares.count <= Int(FLOE_AE_MAX_SHARES) else {
            throw ARM64MachineError.invalidConfiguration("shares exceed \(FLOE_AE_MAX_SHARES)")
        }
        guard forwards.count <= Int(FLOE_AE_MAX_NET_FORWARDS) else {
            throw ARM64MachineError.invalidConfiguration("forwards exceed \(FLOE_AE_MAX_NET_FORWARDS)")
        }
        if let commandLine, commandLine.utf8.count > 4096 {
            throw ARM64MachineError.invalidConfiguration("command line exceeds 4096 bytes")
        }
        if inputCapacity != 0 && (inputCapacity < 256 || inputCapacity > 1_048_576) {
            throw ARM64MachineError.invalidConfiguration("inputCapacity must be 0 or 256...1MiB")
        }
        if outputCapacity != 0 && (outputCapacity < 4096 || outputCapacity > 16_777_216) {
            throw ARM64MachineError.invalidConfiguration("outputCapacity must be 0 or 4KiB...16MiB")
        }
        var seenTags = Set<String>()
        for share in shares {
            let tagBytes = share.mountTag.utf8.count
            guard tagBytes >= 1 && tagBytes <= 127 else {
                throw ARM64MachineError.invalidConfiguration("mount tag '\(share.mountTag)' must be 1...127 bytes")
            }
            guard seenTags.insert(share.mountTag).inserted else {
                throw ARM64MachineError.invalidConfiguration("duplicate mount tag '\(share.mountTag)'")
            }
        }
        var seenForwards = Set<String>()
        for forward in forwards {
            guard forward.hostPort >= 1 && forward.hostPort <= 65535,
                  forward.guestPort >= 1 && forward.guestPort <= 65535 else {
                throw ARM64MachineError.invalidConfiguration("forward ports must be 1...65535")
            }
            let key = "\(forward.isUDP ? "u" : "t"):\(forward.hostPort)"
            guard seenForwards.insert(key).inserted else {
                throw ARM64MachineError.invalidConfiguration("duplicate forward \(key)")
            }
        }
        if let dnsServerIPv4 {
            let octets = dnsServerIPv4.split(separator: ".").compactMap { UInt32($0) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else {
                throw ARM64MachineError.invalidConfiguration("dnsServerIPv4 must be a dotted quad")
            }
        }
        if (dnsServerIPv4 != nil) && !networkEnabled {
            throw ARM64MachineError.invalidConfiguration("a resolver override requires network_enabled at create")
        }
        if !forwards.isEmpty && !networkEnabled {
            throw ARM64MachineError.invalidConfiguration("port forwards require network_enabled at create")
        }
        return self
    }

    /// Re-hashes every configured asset against the caller-authorized digest.
    /// Throws `assetDigestMismatch` before create; used on the worker so a
    /// swapped file never reaches the engine.
    func verifyAssetDigests() throws {
        for asset in [firmware, kernel, initrd].compactMap({ $0 }) {
            guard let actual = SHA256Hex.ofFile(atPath: asset.path),
                  actual == asset.sha256.lowercased() else {
                throw ARM64MachineError.assetDigestMismatch(
                    "asset at \(asset.path) does not match the caller-authorized SHA-256"
                )
            }
        }
    }
}

/// Minimal SHA-256 hex helper kept inside the component so it stays
/// dependency-free for both host and later app integration.
enum SHA256Hex {
    static func ofFile(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return ofData(data)
    }

    static func ofData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Staged C config: deep-copies every string and every sub-array into C
/// memory owned by this value, so `floe_ae_create` receives pointers that
/// live for the whole call on every path (the engine deep-copies again
/// internally; staging keeps Swift-side ownership explicit and leak-free).
///
/// The staged struct is always `floe_ae_config_v3`: the version-2 prefix is
/// filled exactly as before and the appended memory section is zeroed unless
/// `onlineMemoryEnabled`, in which case `memory.enabled` opts the engine into
/// the virtio-mem managed region (boot RAM + live-pluggable remainder).
final class ARM64StagedConfig: @unchecked Sendable {
    private var cStrings: [UnsafeMutablePointer<CChar>] = []
    private var shareArray: UnsafeMutablePointer<floe_ae_share_config>?
    private var shareCount = 0
    private var forwardArray: UnsafeMutablePointer<floe_ae_net_forward>?
    private var forwardCount = 0
    private(set) var cConfig = floe_ae_config_v3()

    init(_ config: ARM64MachineConfig) {
        memset(&cConfig, 0, MemoryLayout<floe_ae_config_v3>.size)
        cConfig.v2.machine.abi_version = UInt32(FLOE_AE_ABI_VERSION)
        // The engine validates machine.struct_size against the base struct,
        // the version-2 layout, and (for abi_version == 3) the full v3
        // layout; advertise the v3 size here. A future ABI bump changes this
        // staging code deliberately, never by reinterpretation.
        cConfig.v2.machine.struct_size = UInt32(MemoryLayout<floe_ae_config_v3>.size)
        cConfig.v2.machine.ram_mib = UInt32(config.ramMiB)
        cConfig.v2.machine.requested_vcpus = UInt32(config.possibleVCPUs)
        cConfig.v2.machine.firmware_path = stage(config.firmware.path)
        cConfig.v2.machine.kernel_path = config.kernel.map { stage($0.path) }
        cConfig.v2.machine.initrd_path = config.initrd.map { stage($0.path) }
        cConfig.v2.machine.command_line = config.commandLine.map { stage($0) }
        cConfig.v2.machine.private_writable_disk_path = stage(config.privateWritableDiskPath)
        cConfig.v2.machine.input_capacity = UInt32(config.inputCapacity)
        cConfig.v2.machine.output_capacity = UInt32(config.outputCapacity)

        cConfig.v2.devices.struct_size = UInt32(MemoryLayout<floe_ae_devices_config>.size)
        cConfig.v2.devices.network_enabled = config.networkEnabled ? 1 : 0
        cConfig.v2.devices.virtio_consoles = UInt32(config.virtioConsoles)
        cConfig.v2.devices.share_count = UInt32(config.shares.count)
        cConfig.v2.devices.forward_count = UInt32(config.forwards.count)
        cConfig.v2.devices.dns_server = config.dnsServerIPv4.map { stage($0) }

        cConfig.memory.struct_size = UInt32(MemoryLayout<floe_ae_memory_config>.size)
        cConfig.memory.enabled = config.onlineMemoryEnabled ? 1 : 0
        cConfig.memory.boot_ram_mib = 0   /* engine default: min(ramMiB, 256) */
        cConfig.gpu.struct_size = UInt32(MemoryLayout<floe_ae_gpu_config>.size)
        cConfig.gpu.enabled = config.gpuEnabled ? 1 : 0
        if config.gpuEnabled && config.gpuAllowsCPUFallback {
            cConfig.gpu.reserved.0 = UInt64(FLOE_AE_GPU_ALLOW_CPU_FALLBACK)
        }
        cConfig.gpu.budget_bytes = UInt64(config.gpuBudgetMiB) * 1_048_576
        cConfig.gpu.app_group_identifier = config.gpuAppGroupIdentifier.map { stage($0) }

        if !config.shares.isEmpty {
            shareCount = config.shares.count
            shareArray = allocate(count: shareCount) { pointer, index in
                var staged = floe_ae_share_config()
                memset(&staged, 0, MemoryLayout<floe_ae_share_config>.size)
                staged.struct_size = UInt32(MemoryLayout<floe_ae_share_config>.size)
                staged.host_path = self.stage(config.shares[index].hostPath)
                staged.mount_tag = self.stage(config.shares[index].mountTag)
                staged.read_only = config.shares[index].readOnly ? 1 : 0
                staged.guest_uid = config.shares[index].guestUID
                staged.guest_gid = config.shares[index].guestGID
                pointer[index] = staged
            }
            cConfig.v2.devices.shares = UnsafePointer(shareArray)
        }
        if !config.forwards.isEmpty {
            forwardCount = config.forwards.count
            forwardArray = allocate(count: forwardCount) { pointer, index in
                var staged = floe_ae_net_forward()
                memset(&staged, 0, MemoryLayout<floe_ae_net_forward>.size)
                staged.struct_size = UInt32(MemoryLayout<floe_ae_net_forward>.size)
                staged.is_udp = config.forwards[index].isUDP ? 1 : 0
                staged.host_port = config.forwards[index].hostPort
                staged.guest_port = config.forwards[index].guestPort
                pointer[index] = staged
            }
            cConfig.v2.devices.forwards = UnsafePointer(forwardArray)
        }
    }

    private func allocate<T>(
        count: Int,
        _ body: (UnsafeMutablePointer<T>, Int) -> Void
    ) -> UnsafeMutablePointer<T> {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        for index in 0..<count { body(pointer, index) }
        return pointer
    }

    private func stage(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        cStrings.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        shareArray?.deallocate()
        forwardArray?.deallocate()
        for pointer in cStrings { free(pointer) }
    }
}
