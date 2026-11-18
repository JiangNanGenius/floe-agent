// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeToolboxDiagnostics

enum MacManualNetworkFormatting {
    private static func text(_ zh: String, _ en: String, _ locale: Locale) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    static func ping(_ reply: MacPingObservation, locale: Locale) -> String {
        switch reply.status {
        case .reply(let ms): return "\(reply.sequence)  \(reply.address)  \(String(format: "%.1f", ms)) ms"
        case .timeout: return "\(reply.sequence)  \(text("超时", "Timed out", locale))"
        case .unreachable: return "\(reply.sequence)  \(text("不可达", "Unreachable", locale))"
        }
    }

    static func trace(_ hop: TraceHop, locale: Locale) -> String {
        let status: String
        switch hop.status {
        case .reached: status = text("已到达", "Reached", locale)
        case .intermediate: status = text("途经", "Hop", locale)
        case .timeout: status = text("超时", "Timed out", locale)
        case .unreachable: status = text("不可达", "Unreachable", locale)
        }
        return "\(hop.ttl)  \(hop.address ?? "*")  \(status)"
    }

    static func port(_ observation: MacPortObservation, locale: Locale) -> String {
        "\(observation.port)  \(observation.isOpen ? text("开放", "Open", locale) : text("未能连接", "Could not connect", locale))"
    }

    static func lan(_ report: LANScanReport, locale: Locale) -> String {
        let status: String
        switch report.status {
        case .foundDevices: status = text("发现已广播的服务", "Advertised services found", locale)
        case .noDevices: status = text("未发现已广播的服务", "No advertised services found", locale)
        case .permissionUncertain: status = text("无法确认本地网络访问是否可用", "Local network access could not be confirmed", locale)
        case .noWiFiPath: status = text("没有可用的本地网络连接", "No usable local network connection", locale)
        case .outOfScopeOnly: status = text("所选服务不在可发现范围内", "The selected services are outside the discovery scope", locale)
        }
        var lines = [status]
        if report.truncated { lines.append(text("结果已截断", "Results were truncated", locale)) }
        if report.unresolvedCount > 0 {
            lines.append(text("未解析：\(report.unresolvedCount)", "Unresolved: \(report.unresolvedCount)", locale))
        }
        lines += report.services.map { "\($0.name)  \($0.serviceType)  \($0.displayAddress)  \($0.displayPort)" }
        return lines.joined(separator: "\n")
    }

    static func wifi(_ observation: MacWiFiObservation, locale: Locale) -> String {
        let status: String
        switch observation.status {
        case .wifi: status = text("Wi-Fi 已开启", "Wi-Fi is on", locale)
        case .notWiFi: status = text("Wi-Fi 未开启", "Wi-Fi is off", locale)
        case .unavailable: status = text("Wi-Fi 不可用", "Wi-Fi is unavailable", locale)
        case .notObserved: status = text("尚未读取", "Not read", locale)
        }
        let identity: String
        switch observation.identityState {
        case .observed: identity = text("系统已提供网络信息", "Network information provided by macOS", locale)
        case .permissionRequired: identity = text("读取网络名称需要定位权限", "Location permission is required for the network name", locale)
        case .systemDidNotProvideIdentity: identity = text("系统未提供网络名称", "macOS did not provide a network name", locale)
        case .unavailable: identity = text("网络信息不可用", "Network information unavailable", locale)
        case .notConnected: identity = text("Wi-Fi 未开启", "Wi-Fi is off", locale)
        }
        return [status, identity, "SSID: \(observation.ssid ?? "—")", "BSSID: \(observation.bssid ?? "—")",
                "\(text("信号", "Signal", locale)): \(observation.signalDBM.map(String.init) ?? "—") dBm"].joined(separator: "\n")
    }

    static func roaming(_ samples: [(seconds: Int, observation: MacWiFiObservation)], locale: Locale) -> String {
        var previousBSSID: String?
        return samples.map { sample in
            let value = sample.observation
            let bssid = value.identityState == .observed ? value.bssid : nil
            let signal = value.signalDBM.map { "  \($0) dBm" } ?? ""
            defer { previousBSSID = bssid }
            guard let bssid else {
                return "+\(sample.seconds) s  "
                    + (value.identityState == .permissionRequired
                       ? text("需要定位权限才能观察接入点", "Location permission is needed to observe the access point", locale)
                       : text("未取得接入点信息", "Access point unavailable", locale))
            }
            let change = previousBSSID.map { $0.caseInsensitiveCompare(bssid) != .orderedSame } == true
                ? "  " + text("接入点已变化", "Access point changed", locale) : ""
            return "+\(sample.seconds) s  \(value.ssid ?? "—")  \(bssid)\(signal)\(change)"
        }.joined(separator: "\n")
    }
}
