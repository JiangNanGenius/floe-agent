// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeToolboxCore
import FloeToolboxUSB

struct ToolboxUSBSetupView: View {
    @ObservedObject var devices: ToolboxUSBDevices
    @Binding var setup: ToolboxConnectionSetup
    let busy: Bool
    let find: () -> Void
    var body: some View {
        Group {
            status.accessibilityIdentifier("toolbox.usb.status")
            Button(IDELanguageRunText.t("查找 USB 设备", "Find USB devices"), action: find)
                .disabled(busy || !devices.canDiscover)
                .accessibilityIdentifier("toolbox.usb.find")
            if devices.searching { ProgressView() }
            if !devices.devices.isEmpty {
                Picker(IDELanguageRunText.t("设备", "Device"), selection: Binding(get: { devices.selectedID }, set: devices.select)) {
                    Text(IDELanguageRunText.t("请选择", "Choose")).tag(UInt64?.none)
                    ForEach(Array(devices.devices.enumerated()), id: \.element.id) { index, device in
                        Text(IDELanguageRunText.t("USB 串口 ", "USB serial device ") + String(index + 1)).tag(Optional(device.id))
                    }
                }.disabled(busy).accessibilityIdentifier("toolbox.usb.device")
            }
            TextField(IDELanguageRunText.t("波特率", "Baud rate"), text: $setup.usbBaud)
                .keyboardType(.numberPad).disabled(busy).accessibilityIdentifier("toolbox.usb.baud")
            Picker(IDELanguageRunText.t("数据位", "Data bits"), selection: $setup.usbDataBits) {
                ForEach([UInt8(5), 6, 7, 8], id: \.self) { Text(String($0)).tag($0) }
            }.disabled(busy).accessibilityIdentifier("toolbox.usb.dataBits")
            Picker(IDELanguageRunText.t("校验", "Parity"), selection: $setup.usbParity) {
                Text(IDELanguageRunText.t("无", "None")).tag(UInt8(0))
                Text(IDELanguageRunText.t("奇校验", "Odd")).tag(UInt8(1))
                Text(IDELanguageRunText.t("偶校验", "Even")).tag(UInt8(2))
                Text(IDELanguageRunText.t("标记校验", "Mark")).tag(UInt8(3))
                Text(IDELanguageRunText.t("空格校验", "Space")).tag(UInt8(4))
            }.disabled(busy).accessibilityIdentifier("toolbox.usb.parity")
            Picker(IDELanguageRunText.t("停止位", "Stop bits"), selection: $setup.usbStopBits) {
                Text("1").tag(UInt8(1)); Text("2").tag(UInt8(2))
            }.disabled(busy).accessibilityIdentifier("toolbox.usb.stopBits")
            if let device = devices.selectedDevice {
                DisclosureGroup(IDELanguageRunText.t("设备详情", "Device details")) {
                    LabeledContent("VID / PID", value: String(format: "%04X / %04X", device.vendorID, device.productID))
                    LabeledContent(IDELanguageRunText.t("配置", "Configuration"), value: String(device.configurationValue))
                    LabeledContent(IDELanguageRunText.t("接口", "Interface"), value: String(device.interfaceNumber))
                    LabeledContent(IDELanguageRunText.t("接口类型", "Interface type"), value: "\(device.interfaceClass) / \(device.interfaceSubclass) / \(device.interfaceProtocol)")
                    LabeledContent("Registry ID", value: String(device.id))
                }.accessibilityIdentifier("toolbox.usb.details")
            }
        }
    }
    @ViewBuilder private var status: some View {
        switch devices.state {
        case .ready: Text(IDELanguageRunText.t("查找后选择要连接的设备。", "Find and select the device to connect."))
        case .searching: Text(IDELanguageRunText.t("正在查找 USB 设备…", "Finding USB devices…"))
        case .result(let result):
            if result.devices.isEmpty {
                Text(result.unmatchedOwnServiceCount == 0
                    ? IDELanguageRunText.t("未发现可连接的 USB 串口，请检查设备连接与驱动设置。", "No USB serial devices found. Check the device connection and driver settings.")
                    : IDELanguageRunText.t("发现的设备与此版本的配置不匹配。", "The discovered devices do not match this version's configuration."))
            } else if result.unmatchedOwnServiceCount > 0 {
                Text(IDELanguageRunText.t("部分设备与此版本的配置不匹配。", "Some devices do not match this version's configuration."))
            } else {
                Text(IDELanguageRunText.t("请选择要连接的设备。", "Select the device to connect."))
            }
        case .failed(let failure):
            Text(failure.errorDescription ?? "")
            if let details = failure.details {
                DisclosureGroup(IDELanguageRunText.t("详情", "Details")) { Text(details).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }
}
#endif
