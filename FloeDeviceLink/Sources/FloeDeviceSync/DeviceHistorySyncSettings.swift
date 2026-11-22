// SPDX-License-Identifier: MPL-2.0

import SwiftUI

public struct DeviceHistorySyncSettings: View {
    @ObservedObject private var center: DeviceHistorySyncCenter
    @State private var addingPeer = false
    @State private var peerName = ""
    @State private var peerCode = ""
    @State private var pairError = false
    @State private var editingRelay = false
    @State private var relayAddress = ""
    @State private var relayError = false
    @State private var proposed: DeviceHistoryPairingTicket?
    @State private var selectedPeer: DeviceHistoryPeer?

    public init(center: DeviceHistorySyncCenter) { self.center = center }

    public var body: some View {
        Form {
            Section {
                Toggle(label("跨设备会话同步", "Sync Conversations Across Devices"), isOn: Binding(
                    get: { center.enabled }, set: { value in Task { await center.setEnabled(value) } }))
                    .disabled(center.busy)
                if center.enabled {
                    Toggle(label("使用公共测试中继", "Use Public Test Relay"), isOn: Binding(
                        get: { center.usesPublicRelay }, set: { value in Task { await center.setPublicRelay(value) } }))
                        .disabled(center.busy)
                    Button {
                        relayAddress = center.customRelayURL?.absoluteString ?? ""
                        relayError = false
                        editingRelay = true
                    } label: {
                        LabeledContent(label("自定义中继", "Custom Relay"), value: center.customRelayURL?.host() ?? "—")
                    }.disabled(center.busy)
                    if let fingerprint = center.fingerprint {
                        Text(fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityLabel(label("本机设备指纹", "This Device’s Fingerprint"))
                    }
                    HStack {
                        if let code = center.pairingCode {
                            ShareLink(item: code, preview: SharePreview(label("Floe 设备配对信息", "Floe Device Pairing"))) {
                                Label(label("分享配对信息", "Share Pairing Info"), systemImage: "square.and.arrow.up")
                            }
                        }
                        Button(label("刷新配对地址", "Refresh Pairing Address")) {
                            Task { await center.refreshPairingCode() }
                        }
                        .disabled(center.fingerprint == nil || center.busy)
                    }.buttonStyle(.borderless)
                }
                if let statusText { Text(statusText).font(.callout).foregroundStyle(.secondary) }
            }
            if center.enabled {
                Section(label("已配对设备", "Paired Devices")) {
                    ForEach(center.peers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            LabeledContent(peer.name) {
                                Text(label("已共享 \(peer.sharedConversations.count) 个会话",
                                           "\(peer.sharedConversations.count) conversations shared"))
                            }
                        }
                    }
                    Button(label("添加设备", "Add Device"), systemImage: "plus") {
                        peerName = ""
                        peerCode = ""
                        pairError = false
                        addingPeer = true
                    }
                    .disabled(center.pairingCode == nil || center.busy)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("deviceHistorySync.settings")
        .task { await center.activate() }
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
        .sheet(item: $selectedPeer) { peer in
            DeviceHistoryPeerSettings(center: center, peerID: peer.id, title: peer.name)
        }
    }

    private var statusText: String? {
        if center.busy { return label("处理中…", "Working…") }
        switch center.status {
        case .idle, .ready: return nil
        case .unableToStart: return label("暂时无法启动设备同步。", "Device sync couldn’t start.")
        case .transferFailed: return label("同步失败，请确认对端已开启同步且仍在共享此会话。", "Sync failed. Check that the other device is available and still sharing this conversation.")
        case .conflict: return label("发现不同版本的消息，两台设备都保留了自己的内容。", "A message differs across devices. Both copies were preserved.")
        case .incompatibleVersion: return label("两台设备的同步版本不兼容。", "These devices use incompatible sync versions.")
        case .received(let count): return label("已同步 \(count) 条新消息。", "Synced \(count) new messages.")
        }
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
        NavigationStack {
            Form {
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
                Section(label("对方共享的会话", "Shared by This Device")) {
                    Button(label("获取会话列表", "Get Conversation List"), systemImage: "arrow.clockwise") {
                        Task { remote = await center.remoteConversations(from: peerID) }
                    }.disabled(center.busy)
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
                    if center.busy { ProgressView() }
                    if case .received(let count) = center.status {
                        Text(label("已同步 \(count) 条新消息。", "Synced \(count) new messages.")).foregroundStyle(.secondary)
                    } else if center.status == .transferFailed {
                        Text(label("同步失败，请检查对端状态。", "Sync failed. Check the other device.")).foregroundStyle(.secondary)
                    } else if center.status == .conflict {
                        Text(label("发现消息冲突，双方记录已保留。", "A message conflict was found. Both copies were preserved.")).foregroundStyle(.secondary)
                    } else if center.status == .incompatibleVersion {
                        Text(label("两台设备的同步版本不兼容。", "These devices use incompatible sync versions.")).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(label("解除配对", "Unpair"), role: .destructive) { confirmsRemoval = true }
                        .disabled(center.busy)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(label("完成", "Done")) { dismiss() }
                }
            }
            .task { local = await center.localConversations() }
            .confirmationDialog(label("解除与此设备的配对？", "Unpair This Device?"), isPresented: $confirmsRemoval) {
                Button(label("解除配对", "Unpair"), role: .destructive) {
                    Task { await center.remove(peerID); dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 565, height: 570)
        #endif
    }
}

private func label(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}
