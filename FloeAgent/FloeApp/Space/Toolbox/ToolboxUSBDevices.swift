// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxUSB

nonisolated enum ToolboxUSBFailure: Error, LocalizedError, Equatable, Sendable {
    case notIncluded, unconfigured, invalidPackage(String)
    case chooseDevice, changedDevice, unreadableDevice, limit, unsupported
    case invalidSettings, busy, closed, invalidReply, system(Int32), failed
    var errorDescription: String? {
        switch self {
        case .notIncluded: IDELanguageRunText.t("此版本未包含 USB 驱动。", "This version does not include a USB driver.")
        case .unconfigured: IDELanguageRunText.t("此版本尚未配置 USB 设备。", "USB devices are not configured in this version.")
        case .invalidPackage: IDELanguageRunText.t("USB 驱动文件无法使用。", "The USB driver files are unavailable.")
        case .chooseDevice: IDELanguageRunText.t("请先查找并选择 USB 设备。", "Find and select a USB device first.")
        case .changedDevice: IDELanguageRunText.t("设备选择已失效，请重新查找并选择。", "The device selection is no longer valid. Find and select it again.")
        case .unreadableDevice: IDELanguageRunText.t("未能读取设备信息，请重新查找。", "Unable to read the device information. Find it again.")
        case .limit: IDELanguageRunText.t("USB 操作超出处理范围。", "The USB operation exceeds its limits.")
        case .unsupported: IDELanguageRunText.t("当前系统或设备不支持此 USB 连接。", "This USB connection is not supported by the system or device.")
        case .invalidSettings: IDELanguageRunText.t("请检查波特率和串口设置。", "Check the baud rate and serial settings.")
        case .busy: IDELanguageRunText.t("USB 设备正在使用，请先断开其他连接。", "The USB device is busy. Close the other connection first.")
        case .closed: IDELanguageRunText.t("USB 连接已结束，请重新连接。", "The USB connection ended. Reconnect to continue.")
        case .invalidReply: IDELanguageRunText.t("USB 驱动返回的数据无法验证。", "The USB driver reply could not be verified.")
        case .system: IDELanguageRunText.t("系统返回了 USB 错误，请查看详情。", "The system returned a USB error. See details.")
        case .failed: IDELanguageRunText.t("USB 连接未完成，请重试。", "The USB connection did not complete. Try again.")
        }
    }
    var details: String? {
        switch self {
        case .notIncluded: "Driver package: notIncluded"
        case .unconfigured: "Driver package: unconfigured"
        case .invalidPackage(let reason): String(reason.prefix(512))
        case .system(let code): "IOKit: 0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
        default: nil
        }
    }
    static func from(_ error: Error) -> Self {
        if let value = error as? Self { return value }
        if let value = error as? USBRegistryError {
            return switch value {
            case .packageNotIncluded: .notIncluded
            case .packageUnconfigured: .unconfigured
            case .invalidPackage: .invalidPackage("Driver package validation failed")
            case .identityUnavailable: .unreadableDevice
            case .staleSelection: .changedDevice
            case .limit: .limit
            case .unsupported: .unsupported
            case .io(let code): .system(code)
            }
        }
        if let value = error as? USBClientError {
            return switch value {
            case .unavailable: .unsupported
            case .invalidPacket: .invalidReply
            case .detached: .changedDevice
            case .busy: .busy
            case .limit: .limit
            case .io(let code): .system(code)
            }
        }
        if let value = error as? ToolboxError, case .unsupported = value { return .unsupported }
        return .failed // Never display arbitrary error text or captured bytes.
    }
}

nonisolated protocol ToolboxUSBSource: Sendable {
    func discover() async throws -> USBRegistryDiscovery
    func connect(selection: USBRegistrySelection, settings: USBSerialSettings) async throws -> USBSerialConnection
}
nonisolated struct NativeToolboxUSBSource: ToolboxUSBSource {
    let host: USBRegistryHost
    func discover() async throws -> USBRegistryDiscovery { try await host.discover() }
    func connect(selection: USBRegistrySelection, settings: USBSerialSettings) async throws -> USBSerialConnection {
        try await host.connect(selection: selection, settings: settings)
    }
}

/// RAM-only native selection. Nothing here is decoded from tool arguments,
/// capture records or settings. The existing task/lease policy still applies.
nonisolated struct ToolboxUSBOpenRequest: Sendable {
    let source: any ToolboxUSBSource
    let selection: USBRegistrySelection
    let device: USBRegistryDevice
    let settings: USBSerialSettings
    let title: String
    let isCurrent: @MainActor @Sendable () -> Bool
    @MainActor func validate() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw ToolboxUSBFailure.changedDevice }
    }
    @MainActor func open() async throws -> USBSerialConnection {
        try validate()
        let connection = try await source.connect(selection: selection, settings: settings)
        do { try validate(); return connection }
        catch { await connection.close(); throw error }
    }
    var captureDescription: String {
        // Registry IDs are deliberately not persisted as reconnect targets.
        let parity = switch settings.parity { case .none: "N"; case .odd: "O"; case .even: "E"; case .mark: "M"; case .space: "S" }
        return "USB · \(settings.baud) baud · \(settings.dataBits)\(parity)\(settings.stopBits)"
    }
}

/// Owned by ToolboxCenter. A view reconstruction neither starts another scan
/// nor replaces the selected native host. Actual navigation calls reset().
@MainActor final class ToolboxUSBDevices: ObservableObject {
    enum State { case ready, searching, result(USBRegistryDiscovery), failed(ToolboxUSBFailure) }
    @Published private(set) var state: State = .ready
    @Published private(set) var selectedID: UInt64?
    private var source: (any ToolboxUSBSource)?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let inspect: @MainActor () -> USBDriverPackageInspection
    private let makeSource: @MainActor (USBDriverPackageInspection) throws -> any ToolboxUSBSource

    init(inspect: @escaping @MainActor () -> USBDriverPackageInspection = {
        USBDriverPackage.inspect(in: Bundle.main.bundleURL)
    }, makeSource: @escaping @MainActor (USBDriverPackageInspection) throws -> any ToolboxUSBSource = {
        NativeToolboxUSBSource(host: try USBRegistryHost(package: $0))
    }) {
        self.inspect = inspect; self.makeSource = makeSource
        reset()
    }
    var devices: [USBRegistryDevice] { if case .result(let result) = state { result.devices } else { [] } }
    var selectedDevice: USBRegistryDevice? { devices.first { $0.id == selectedID } }
    var searching: Bool { if case .searching = state { true } else { false } }
    var canDiscover: Bool { source != nil && !searching }
    var canConnect: Bool { selectedDevice != nil && !searching }

    func reset() {
        generation = UUID(); operation?.cancel(); operation = nil
        source = nil; selectedID = nil
        let package = inspect() // Local bundle metadata only, never a USB query.
        do {
            switch package {
            case .notIncluded: throw ToolboxUSBFailure.notIncluded
            case .unconfigured: throw ToolboxUSBFailure.unconfigured
            case .invalid(let reason): throw ToolboxUSBFailure.invalidPackage(reason)
            case .bundledUnverified: break
            }
            source = try makeSource(package); state = .ready
        } catch { state = .failed(.from(error)) }
    }
    @discardableResult func refresh() -> Task<Void, Never> {
        reset()
        guard let source else { return Task {} }
        let stamp = generation
        state = .searching
        let task = Task { [weak self] in
            do {
                let result = try await source.discover()
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.state = .result(result)
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.state = .failed(.from(error))
            }
            guard let self, self.generation == stamp else { return }
            self.operation = nil
        }
        operation = task; return task
    }
    func select(_ id: UInt64?) {
        guard !searching else { return }
        let accepted = devices.first(where: { $0.id == id })?.id
        guard selectedID != accepted else { return }
        generation = UUID(); selectedID = accepted
    }
    func request(settings: USBSerialSettings) throws -> ToolboxUSBOpenRequest {
        guard let source, case .result(let snapshot) = state,
              let device = selectedDevice else { throw ToolboxUSBFailure.chooseDevice }
        let selection = try snapshot.select(registryEntryID: device.id), stamp = generation
        let ordinal = (devices.firstIndex(where: { $0.id == device.id }) ?? 0) + 1
        return .init(source: source, selection: selection, device: device, settings: settings,
            title: IDELanguageRunText.t("USB 串口 ", "USB serial device ") + String(ordinal),
            isCurrent: { [weak self] in self?.generation == stamp && self?.selectedID == device.id })
    }
}
#endif
