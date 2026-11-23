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
                    Toggle(label("跨设备同步", "Sync Across Devices"), isOn: Binding(
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
                ContentUnavailableView(label("设备同步已关闭", "Device Sync Is Off"),
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
    @State private var staleShares: Set<UUID> = []

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
                            receiveControl(for: task)
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
                } else if center.busy, center.workspacePeerID == peerID {
                    if let progress = center.workspaceProgress {
                        ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total))) {
                            Text(label("正在同步文件 · \(progress.processed)/\(progress.total) 项",
                                       "Syncing files · \(progress.processed)/\(progress.total) items"))
                        }
                    } else {
                        ProgressView(label("正在准备工作区文件…", "Preparing workspace files…"))
                    }
                    Button(label("取消同步", "Cancel Sync"), action: center.cancelReceive)
                } else if center.busy {
                    ProgressView()
                } else if let text = deviceHistoryStatusText(center.status) {
                    Text(text).foregroundStyle(.secondary)
                }
                if center.workspacePeerID == peerID, let result = center.workspaceResult {
                    Text(workspaceStatusText(result)).foregroundStyle(.secondary)
                }
                if let result = center.attachmentResult, result.peerID == peerID {
                    Text(label("已接收 \(result.restoredAttachments) 个附件。",
                               "Received \(result.restoredAttachments) attachments.")).foregroundStyle(.secondary)
                    if result.failedAttachments > 0 {
                        Text(label("\(result.failedAttachments) 个附件未接收，可再次同步。",
                                   "\(result.failedAttachments) attachments are pending. Sync again to retry."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(local) { task in
                    Toggle(task.title, isOn: Binding(get: {
                        center.peers.first(where: { $0.id == peerID })?.sharedConversations.contains(task.id) == true
                    }, set: { enabled in
                        Task { await center.share(task.id, with: peerID, enabled: enabled) }
                    }))
                    .disabled(center.busy)
                    if center.supportsWorkspaceSync,
                       center.peers.first(where: { $0.id == peerID })?.sharedConversations.contains(task.id) == true {
                        Toggle(label("同时共享工作区文件", "Also Share Workspace Files"), isOn: Binding(get: {
                            !staleShares.contains(task.id)
                                && center.peers.first(where: { $0.id == peerID })?.sharesWorkspace(for: task.id) == true
                        }, set: { enabled in
                            Task {
                                await center.shareWorkspace(task.id, with: peerID, enabled: enabled)
                                staleShares = await center.staleWorkspaceShares(for: peerID)
                            }
                        }))
                        .disabled(center.busy)
                        .accessibilityLabel(label("共享 \(task.title) 的工作区文件", "Share workspace files for \(task.title)"))
                        .accessibilityIdentifier("deviceHistorySync.shareWorkspace.\(task.id.uuidString)")
                        if center.supportsWorkspaceChanges, !staleShares.contains(task.id),
                           let peer = center.peers.first(where: { $0.id == peerID }), peer.sharesWorkspace(for: task.id) {
                            Toggle(label("同步重命名和删除", "Sync Renames and Deletions"), isOn: Binding(get: {
                                center.peers.first(where: { $0.id == peerID })?.convergesWorkspace(for: task.id) == true
                            }, set: { enabled in
                                Task { await center.shareWorkspace(task.id, with: peerID, enabled: true, propagateChanges: enabled) }
                            }))
                            .disabled(center.busy)
                        }
                        if staleShares.contains(task.id) {
                            Text(label("工作区已变更。重新开启文件共享后可继续同步。",
                                       "The workspace changed. Turn on file sharing again to sync the new workspace."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if local.isEmpty { Text(label("当前没有可共享的会话。", "No conversations to share.")).foregroundStyle(.secondary) }
            } header: {
                Text(label("共享给这台设备", "Share With This Device"))
            } footer: {
                if center.supportsWorkspaceSync {
                    Text(label("授权后，对方可以接收会话附件和工作区文件。双方开启同步删除时，移除的文件可在工作区的 Floe Sync Conflicts 中找回。",
                               "File sharing includes conversation attachments and workspace files. With deletion sync on for both devices, removed files can be recovered in Floe Sync Conflicts."))
                }
            }
            Section {
                Button(label("解除配对", "Unpair"), role: .destructive) { confirmsRemoval = true }
                    .disabled(center.busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .task {
            local = await center.localConversations()
            staleShares = await center.staleWorkspaceShares(for: peerID)
        }
        .confirmationDialog(label("解除与此设备的配对？", "Unpair This Device?"), isPresented: $confirmsRemoval) {
            Button(label("解除配对", "Unpair"), role: .destructive) {
                Task { await center.remove(peerID); dismiss() }
            }
        }
    }

    @ViewBuilder
    private func receiveControl(for task: DeviceHistoryOffer) -> some View {
        if task.workspaceFiles == true, center.supportsWorkspaceSync {
            Menu(label("同步", "Sync")) {
                Button(label("会话和工作区", "Conversation and Workspace"), systemImage: "folder") {
                    Task { await center.receive(task.id, from: peerID, includeWorkspace: true) }
                }
                Button(label("仅会话", "Conversation Only"), systemImage: "text.bubble") {
                    Task { await center.receive(task.id, from: peerID) }
                }
            }
            .disabled(center.busy)
        } else {
            Button(label("同步", "Sync")) {
                Task { await center.receive(task.id, from: peerID) }
            }
            .disabled(center.busy)
        }
    }
}

private func workspaceStatusText(_ result: DeviceHistorySyncCenter.WorkspaceResult) -> String {
    switch result {
    case .received(let progress):
        if progress.movedFiles > 0 || progress.deletedFiles > 0 || progress.preservedRemovals > 0 {
            return label("已保存 \(progress.savedFiles) 个文件，重命名 \(progress.movedFiles) 个，移入恢复文件夹 \(progress.deletedFiles) 个，保留 \(progress.conflicts + progress.preservedRemovals) 项不同内容。",
                         "Saved \(progress.savedFiles) files, renamed \(progress.movedFiles), moved \(progress.deletedFiles) to recovery, and preserved \(progress.conflicts + progress.preservedRemovals) differences.")
        }
        if progress.conflicts > 0 {
            return label("已保存 \(progress.savedFiles) 个文件，\(progress.conflicts) 项冲突留在工作区的 Floe Sync Conflicts 文件夹。",
                         "Saved \(progress.savedFiles) files. Find \(progress.conflicts) conflicts in the workspace’s Floe Sync Conflicts folder.")
        }
        return label("工作区已同步，保存 \(progress.savedFiles) 个文件。",
                     "Workspace synced. Saved \(progress.savedFiles) files.")
    case .interrupted(let progress, let reason):
        let saved = progress?.savedFiles ?? 0
        switch reason {
        case .noLongerShared:
            return label("对方已停止共享工作区。已保存 \(saved) 个文件。",
                         "The other device stopped sharing its workspace. Saved \(saved) files.")
        case .tooLarge:
            return label("工作区超出同步上限。", "This workspace exceeds the sync limit.")
        case .workspaceBusy:
            return label("工作区正在使用。结束相关任务后可重试，已保存 \(saved) 个文件。",
                         "This workspace is in use. Finish its active tasks and try again. Saved \(saved) files.")
        case .workspaceUnavailable:
            return label("暂时无法访问工作区。请检查会话的工作区位置。", "The workspace is unavailable. Check the conversation’s workspace location.")
        default:
            return label("工作区同步未完成。已保存 \(saved) 个文件，可以重试。",
                         "Workspace sync was interrupted. Saved \(saved) files. You can try again.")
        }
    case .cancelled(let progress):
        let saved = progress?.savedFiles ?? 0
        return label("工作区同步已取消，已保存 \(saved) 个文件。",
                     "Workspace sync cancelled. Saved \(saved) files.")
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
    case .workspaceBusy: label("工作区正在使用。结束相关任务后可重试。", "This workspace is in use. Finish its active tasks and try again.")
    case .workspaceUnavailable: label("暂时无法访问工作区。请检查会话的工作区位置。",
                                      "The workspace is unavailable. Check the conversation’s workspace location.")
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
