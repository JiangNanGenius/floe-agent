// SPDX-License-Identifier: MPL-2.0

import SwiftUI

public struct DeviceHistorySyncSettings: View {
    @ObservedObject private var center: DeviceHistorySyncCenter
    private let showsEnableControl: Bool
    @State private var addingPeer = false
    @State private var peerName = ""
    @State private var peerCode = ""
    @State private var pairError = false
    @State private var editingRelay = false
    @State private var relayAddress = ""
    @State private var relayError = false
    @State private var proposed: DeviceHistoryPairingTicket?
    #if os(macOS)
    @State private var selectedPeer: DeviceHistoryPeer?
    #endif

    public init(center: DeviceHistorySyncCenter, showsEnableControl: Bool = true) {
        self.center = center
        self.showsEnableControl = showsEnableControl
    }

    public var body: some View {
        #if os(macOS)
        pairingForm.sheet(item: $selectedPeer) { peer in
            DeviceHistoryPeerSettings(center: center, peerID: peer.id, title: peer.name)
        }
        #else
        pairingForm
        #endif
    }

    private var pairingForm: some View {
        Form {
            if showsEnableControl {
                Section {
                    Toggle(label("跨设备会话同步", "Sync Conversations Across Devices"), isOn: Binding(
                        get: { center.enabled }, set: { value in Task { await center.setEnabled(value) } }))
                        .disabled(center.busy)
                        .accessibilityIdentifier("deviceHistorySync.enabled")
                    if !center.enabled, let statusText {
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if center.enabled {
                Section(label("本机配对", "Pair This Device")) {
                    if let code = center.pairingCode {
                        ShareLink(item: code, preview: SharePreview(label("Floe 设备配对信息", "Floe Device Pairing"))) {
                            Label(label("分享配对信息", "Share Pairing Info"), systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("deviceHistorySync.sharePairing")
                    }
                    Button(label("刷新配对地址", "Refresh Pairing Address"), systemImage: "arrow.clockwise") {
                        Task { await center.refreshPairingCode() }
                    }
                    .disabled(center.fingerprint == nil || center.busy)
                    if let fingerprint = center.fingerprint {
                        DisclosureGroup(label("本机设备指纹", "This Device’s Fingerprint")) {
                            Text(fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .accessibilityIdentifier("deviceHistorySync.fingerprint")
                        }
                    }
                    if let statusText { Text(statusText).font(.callout).foregroundStyle(.secondary) }
                }

                Section(label("已配对设备", "Paired Devices")) {
                    ForEach(center.peers) { peer in
                        #if os(macOS)
                        Button {
                            selectedPeer = peer
                        } label: {
                            peerLabel(peer)
                        }
                        #else
                        NavigationLink {
                            DeviceHistoryPeerSettings(center: center, peerID: peer.id, title: peer.name)
                        } label: {
                            peerLabel(peer)
                        }
                        #endif
                    }
                    Button(label("添加设备", "Add Device"), systemImage: "plus") {
                        peerName = ""
                        peerCode = ""
                        pairError = false
                        addingPeer = true
                    }
                    .disabled(center.pairingCode == nil || center.busy)
                    .accessibilityIdentifier("deviceHistorySync.addDevice")
                }

                Section {
                    Toggle(label("使用公共测试中继", "Use Public Test Relay"), isOn: Binding(
                        get: { center.usesPublicRelay }, set: { value in Task { await center.setPublicRelay(value) } }))
                        .disabled(center.busy)
                    Button {
                        relayAddress = center.customRelayURL?.absoluteString ?? ""
                        relayError = false
                        editingRelay = true
                    } label: {
                        LabeledContent(label("自定义中继", "Custom Relay"), value: center.customRelayURL?.host() ?? "—")
                    }
                    .disabled(center.busy)
                } header: {
                    Text(label("连接选项", "Connection Options"))
                }
            } else if !showsEnableControl {
                ContentUnavailableView(label("会话同步已关闭", "Conversation Sync Is Off"),
                                       systemImage: "laptopcomputer")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("deviceHistorySync.settings")
        .task {
            // The containing app scene owns activation when the switch lives outside this page.
            if showsEnableControl { await center.activate() }
        }
        .sheet(isPresented: $addingPeer) { pairing }
        .alert(label("自定义中继", "Custom Relay"), isPresented: $editingRelay) {
            TextField("https://", text: $relayAddress)
            Button(label("保存", "Save")) {
                Task { do { try await center.setCustomRelay(relayAddress) } catch { relayError = true } }
            }
            Button(label("取消", "Cancel"), role: .cancel) {}
        }
        .alert(label("请输入有效的 HTTPS 中继地址。", "Enter a valid HTTPS relay address."), isPresented: $relayError) {
            Button(label("好", "OK")) {}
        }
    }

    private func peerLabel(_ peer: DeviceHistoryPeer) -> some View {
        LabeledContent(peer.name) {
            Text(label("已共享 \(peer.sharedConversations.count) 个会话",
                       "\(peer.sharedConversations.count) conversations shared"))
        }
    }

    private var statusText: String? {
        center.busy ? label("处理中…", "Working…") : deviceHistoryStatusText(center.status)
    }

    private var pairing: some View {
        NavigationStack {
            Form {
                TextField(label("设备名称", "Device Name"), text: $peerName)
                TextField(label("粘贴对方的配对信息", "Paste Pairing Info"), text: $peerCode, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.caption.monospaced())
                if pairError {
                    Text(label("配对信息无法识别。", "Pairing info couldn’t be read.")).foregroundStyle(.secondary)
                }
                if let proposed {
                    Section(label("核对设备指纹", "Verify the Device Fingerprint")) {
                        Text(proposed.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Button(label("确认配对", "Confirm Pairing")) {
                            Task {
                                await center.pair(proposed, named: peerName)
                                if center.peers.contains(where: { $0.id == proposed.id }) { addingPeer = false }
                            }
                        }
                        .disabled(center.busy || peerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button(label("核对设备", "Verify Device")) {
                        proposed = try? DeviceHistoryPairingTicket(code: peerCode)
                        pairError = proposed == nil
                    }
                    .disabled(peerCode.isEmpty || peerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(label("添加设备", "Add Device"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(label("取消", "Cancel")) { addingPeer = false }
                }
            }
            .onAppear { proposed = nil }
            .onChange(of: peerCode) { _, _ in proposed = nil; pairError = false }
        }
        #if os(macOS)
        .frame(width: 520, height: 430)
        #endif
    }
}

private struct DeviceHistoryPeerSettings: View {
    @ObservedObject var center: DeviceHistorySyncCenter
    let peerID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var local: [DeviceHistoryOffer] = []
    @State private var remote: [DeviceHistoryOffer]?
    @State private var confirmsRemoval = false

    var body: some View {
        #if os(macOS)
        NavigationStack {
            details
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(label("完成", "Done")) { dismiss() }
                    }
                }
        }
        .frame(width: 565, height: 570)
        #else
        details
        #endif
    }

    private var details: some View {
        Form {
            Section(label("对方共享的会话", "Shared by This Device")) {
                Button(label("获取会话列表", "Get Conversation List"), systemImage: "arrow.clockwise") {
                    Task { remote = await center.remoteConversations(from: peerID) }
                }
                .accessibilityIdentifier("deviceHistorySync.getConversations")
                .disabled(center.busy)
                if let remote {
                    ForEach(remote) { task in
                        LabeledContent(task.title) {
                            Button(label("同步", "Sync")) {
                                Task { await center.receive(task.id, from: peerID) }
                            }.disabled(center.busy)
                        }
                    }
                    if remote.isEmpty { Text(label("对方暂无共享会话。", "The other device hasn’t shared any conversations.")).foregroundStyle(.secondary) }
                }
                if let progress = center.receiveProgress, progress.peerID == peerID {
                    ProgressView(label("正在同步，已保存 \(progress.addedMessages) 条新消息",
                                       "Syncing · \(progress.addedMessages) new messages saved"))
                        .accessibilityIdentifier("deviceHistorySync.receiveProgress")
                    Button(label("取消同步", "Cancel Sync"), action: center.cancelReceive)
                        .accessibilityIdentifier("deviceHistorySync.cancelReceive")
                } else if center.busy {
                    ProgressView()
                } else if let text = deviceHistoryStatusText(center.status) {
                    Text(text).foregroundStyle(.secondary)
                }
            }
            Section(label("共享给这台设备", "Share With This Device")) {
                ForEach(local) { task in
                    Toggle(task.title, isOn: Binding(get: {
                        center.peers.first(where: { $0.id == peerID })?.sharedConversations.contains(task.id) == true
                    }, set: { enabled in
                        Task { await center.share(task.id, with: peerID, enabled: enabled) }
                    }))
                    .disabled(center.busy)
                }
                if local.isEmpty { Text(label("当前没有可共享的会话。", "No conversations to share.")).foregroundStyle(.secondary) }
            }
            Section {
                Button(label("解除配对", "Unpair"), role: .destructive) { confirmsRemoval = true }
                    .disabled(center.busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .task { local = await center.localConversations() }
        .confirmationDialog(label("解除与此设备的配对？", "Unpair This Device?"), isPresented: $confirmsRemoval) {
            Button(label("解除配对", "Unpair"), role: .destructive) {
                Task { await center.remove(peerID); dismiss() }
            }
        }
    }
}

private func deviceHistoryStatusText(_ status: DeviceHistorySyncCenter.Status) -> String? {
    switch status {
    case .idle, .ready: nil
    case .unableToStart: label("暂时无法启动设备同步。", "Device sync couldn’t start.")
    case .transferFailed: label("同步未完成。请检查网络和设备的同步设置后重试。",
                                "Sync couldn’t finish. Check the network and both devices’ sync settings, then try again.")
    case .conflict: label("发现不同版本的消息。两台设备都保留了自己的内容。",
                          "A message differs across devices. Both copies were preserved.")
    case .incompatibleVersion: label("两台设备的同步版本不兼容。", "These devices use incompatible sync versions.")
    case .noLongerShared: label("对方当前没有共享此会话。", "The other device isn’t sharing this conversation.")
    case .tooLarge: label("此次数据超出同步上限。请检查两台设备的版本和会话内容。",
                          "This transfer exceeds its size limit. Check both app versions and the conversation.")
    case .interrupted(let count): label("连接中断，已保存 \(count) 条新消息。再次同步可继续。",
                                        "Connection lost. Saved \(count) new messages. Sync again to continue.")
    case .cancelled(let count): label("同步已取消，已保存 \(count) 条新消息。",
                                      "Sync cancelled. Saved \(count) new messages.")
    case .received(let count): label("已同步 \(count) 条新消息。", "Synced \(count) new messages.")
    }
}

private func label(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}
