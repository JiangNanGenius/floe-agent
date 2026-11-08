// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeExecution

@MainActor enum ToolboxBluetoothPresentation {
    static func title(_ channel: BluetoothSerialChannel, index: Int) -> String {
        switch channel.recognition {
        case .nordicUART: "Nordic UART"
        case .microchipUART: "Microchip UART"
        case .unverified: IDELanguageRunText.t("数据通道 \(index + 1)", "Data channel \(index + 1)")
        }
    }
    static func message(_ error: Error) -> String {
        guard let failure = error as? BluetoothSerialError else {
            return IDELanguageRunText.t("未能连接，请检查设备后重试。", "Unable to connect. Check the device and retry.")
        }
        switch failure {
        case .permissionDenied:
            return IDELanguageRunText.t("请在系统设置中允许 Floe 使用蓝牙。", "Allow Floe to use Bluetooth in system settings.")
        case .poweredOff:
            return IDELanguageRunText.t("请打开蓝牙。", "Turn on Bluetooth.")
        case .unsupported:
            return IDELanguageRunText.t("此设备不支持低功耗蓝牙。", "This device does not support Bluetooth Low Energy.")
        case .authenticationRequired:
            return IDELanguageRunText.t("设备需要认证。请完成系统提示后重新连接。", "The device requires authentication. Complete the system prompt, then reconnect.")
        case .accessoryAccessDenied:
            return IDELanguageRunText.t("设备未允许访问此通道。请检查设备设置。", "The device denied access to this channel. Check its settings.")
        case .channelSelectionRequired:
            return IDELanguageRunText.t("请选择要使用的通道。", "Choose a channel to use.")
        case .noSerialChannel:
            return IDELanguageRunText.t("未找到兼容的串口通道。请确认设备支持低功耗蓝牙串口。", "No compatible serial channel was found. Check that the device supports BLE serial.")
        case .connectionBusy:
            return IDELanguageRunText.t("设备正在连接或断开，请稍后重试。", "The device is busy connecting or disconnecting. Try again shortly.")
        case .timedOut, .notReady, .peripheralNotFound:
            return IDELanguageRunText.t("设备未响应。请靠近设备并重试。", "The device did not respond. Move closer and retry.")
        case .serviceNotFound, .writeCharacteristicNotFound, .notifyCharacteristicNotFound, .notificationNotReady, .peripheralMismatch:
            return IDELanguageRunText.t("此通道不可用，请重新识别或选择其他通道。", "This channel is unavailable. Detect it again or choose another channel.")
        case .disconnected:
            return IDELanguageRunText.t("蓝牙连接已断开，请重新连接。", "Bluetooth disconnected. Reconnect to continue.")
        case .ambiguousAttributes, .discoveryLimit:
            return IDELanguageRunText.t("暂不支持此设备的通道布局。", "This device's channel layout is not supported yet.")
        case .unavailable, .connectionFailed:
            return IDELanguageRunText.t("未能连接，请检查设备后重试。", "Unable to connect. Check the device and retry.")
        }
    }
}
#endif
