#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloePersistence
import FloeSync

/// Opened inside the Installed skill's existing detail navigation stack.
struct SkillConfigurationEntryView: View {
    let skill: PersistedSkill
    @Environment(\.skillConfigurationAccess) private var access

    var body: some View {
        Group {
            if let access {
                SkillConfigurationView(skill: skill, access: access)
            } else {
                ContentUnavailableView {
                    Label(SkillConfigurationCopy.title, systemImage: "slider.horizontal.3")
                } description: {
                    Text(SkillConfigurationCopy.text(
                        "Configuration is temporarily unavailable. Your saved settings are kept.",
                        "配置服务暂不可用，已保存的设置仍保留。"))
                }
            }
        }
        .navigationTitle(SkillConfigurationCopy.title)
        .navigationDestination(for: SkillConfigurationConnectionRequest.self) { request in
            SkillNativeConnectionDestination(request: request)
        }
    }
}

@MainActor
struct SkillConfigurationView: View {
    @State private var center: SkillConfigurationCenter
    @State private var editor: EditorRoute?
    @State private var clearingField: CredentialEditorRoute?
    @State private var removingLocalField: LocalFieldRemovalRoute?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private struct CredentialEditorRoute: Identifiable {
        let field: SkillConfigFieldRequirement
        var id: String { field.key }
    }

    private enum EditorRoute: Identifiable {
        case credential(SkillConfigFieldRequirement)
        case addEnvironment
        var id: String {
            switch self {
            case .credential(let field): "credential:\(field.key)"
            case .addEnvironment: "add-environment"
            }
        }
    }

    private struct LocalFieldRemovalRoute: Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    init(skill: PersistedSkill, access: SkillConfigurationUIAccess) {
        _center = State(initialValue: SkillConfigurationCenter(skill: skill, access: access))
    }

    var body: some View {
        Form {
            statusSection
            if center.isLoading && center.status == nil {
                ProgressView()
            } else if center.status != nil {
                if center.requirements.fields.isEmpty {
                    Text(SkillConfigurationCopy.text(
                        "This skill has no declared configuration. You can add your own environment variables.",
                        "此技能尚未声明配置，可以添加自己的环境变量。"))
                }
                parameterSection
                credentialSection
                connectionSection
                localEnvironmentSection
            }
            feedbackSection
        }
        .formStyle(.grouped)
        .navigationTitle(SkillConfigurationCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(center.hasChanges || center.isMutating)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(center.hasChanges ? SkillConfigurationCopy.cancel : SkillConfigurationCopy.done) {
                    if center.hasChanges { confirmingDiscard = true } else { dismiss() }
                }
                .disabled(center.isMutating)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(SkillConfigurationCopy.save) {
                    Task { _ = await center.saveValues() }
                }
                .disabled(!center.canEdit || !center.hasChanges)
                .accessibilityIdentifier("skill.configuration.save")
            }
        }
        .task {
            if center.status == nil { await center.load() }
            else { await center.refreshStatus() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await center.refreshStatus() } }
        }
        .interactiveDismissDisabled(center.hasChanges || center.isMutating)
        .sheet(item: $editor) { route in
            switch route {
            case .credential(let field): SkillConfigurationCredentialEditor(center: center, field: field)
            case .addEnvironment: SkillConfigurationAddEnvironmentView(center: center)
            }
        }
        .confirmationDialog(
            SkillConfigurationCopy.text("Discard unsaved changes?", "放弃未保存的更改？"),
            isPresented: $confirmingDiscard
        ) {
            Button(SkillConfigurationCopy.text("Discard changes", "放弃更改"), role: .destructive) { dismiss() }
        }
        .confirmationDialog(
            SkillConfigurationCopy.text("Remove this credential binding?", "移除此凭据绑定？"),
            isPresented: Binding(get: { clearingField != nil }, set: { if !$0 { clearingField = nil } })
        ) {
            if let field = clearingField?.field {
                Button(SkillConfigurationCopy.text("Remove binding", "移除绑定"), role: .destructive) {
                    clearingField = nil
                    Task { await center.clear(field) }
                }
            }
        } message: {
            Text(SkillConfigurationCopy.text("Shared credentials used elsewhere are kept.", "其他配置使用的共享凭据会保留。"))
        }
        .confirmationDialog(
            SkillConfigurationCopy.text("Delete this local variable?", "删除此本地变量？"),
            isPresented: Binding(get: { removingLocalField != nil }, set: { if !$0 { removingLocalField = nil } })
        ) {
            if let field = removingLocalField {
                Button(SkillConfigurationCopy.text("Delete variable", "删除变量"), role: .destructive) {
                    removingLocalField = nil
                    Task { await center.removeLocalField(field.key) }
                }
            }
        } message: {
            Text(SkillConfigurationCopy.text(
                "Its value or binding will be removed from this configuration. Shared credentials and skill files are kept.",
                "将移除此配置中的取值或绑定，共享凭据和技能文件会保留。"))
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(SkillConfigurationCopy.text("Skill", "技能"), value: center.skill.name)
            LabeledContent(SkillConfigurationCopy.text("Used by", "用于"), value: configurationTargetTitle)
            if let status = center.status {
                LabeledContent(SkillConfigurationCopy.text("Status", "状态")) {
                    if center.installationChanged {
                        Text(SkillConfigurationCopy.text("Skill updated · reopen configuration", "技能已更新，请重新打开配置"))
                    } else {
                        Text(SkillConfigurationCopy.readiness(status.readiness))
                            .foregroundStyle(status.readiness == .ready ? Color.green : Color.secondary)
                    }
                }
                .accessibilityIdentifier("skill.configuration.status")
                Button(SkillConfigurationCopy.text("Refresh status", "刷新状态")) {
                    Task { await center.refreshStatus() }
                }.disabled(center.isLoading || center.isMutating)
                if status.sourceChanged {
                    Text(SkillConfigurationCopy.text(
                        "This skill's source changed. Saved credentials from its previous source are kept separately.",
                        "此技能的来源已更改，原来源的凭据仍单独保留。"))
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if status.readiness == .locked {
                    Text(SkillConfigurationCopy.text("Unlock this device, then reload to continue.", "请解锁此设备，再重新载入。"))
                        .font(.footnote)
                }
            }
        }
    }

    private var configurationTargetTitle: String {
        switch center.scope.target {
        case "local-ios": return SkillConfigurationCopy.text("Automation on this device", "此设备的自动化")
        case "local-mac": return SkillConfigurationCopy.text("This Mac", "这台 Mac")
        case "local-linux": return SkillConfigurationCopy.text("On-device environment", "本机运行环境")
        default:
            return center.scope.target.hasPrefix("ssh:")
                ? SkillConfigurationCopy.text("Selected remote host", "已选远程主机")
                : SkillConfigurationCopy.text("Selected configuration", "已选配置")
        }
    }

    @ViewBuilder private var parameterSection: some View {
        let fields = center.requirements.fields.filter { $0.kind == .variable }
        if !fields.isEmpty {
            Section(SkillConfigurationCopy.parameters) {
                ForEach(fields, id: \.key) { field in
                    SkillConfigurationParameterRow(
                        field: field,
                        value: Binding(get: { center.values[field.key] ?? "" }, set: { center.values[field.key] = $0 }),
                        environmentNames: center.requirements.environmentNames(fieldKey: field.key)
                    )
                    .disabled(!center.canEdit)
                    if field.declaredBy == .local { removeLocalFieldButton(field) }
                }
            }
        }
    }

    @ViewBuilder private var credentialSection: some View {
        let fields = center.requirements.fields.filter { $0.kind == .secret }
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 8) {
                        fieldHeader(field)
                        if let state = center.fieldStatus(field.key) {
                            Text(SkillConfigurationCopy.fieldState(state.state))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if state.bindingRole == .shared {
                                Label(SkillConfigurationCopy.text("Shared credential", "共享凭据"), systemImage: "person.2")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let card = center.boundCredentials[field.key] {
                                    Text(card.label).font(.subheadline)
                                }
                            } else if state.bindingRole == .owned {
                                Text(SkillConfigurationCopy.text("Only this configuration", "此配置专用"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(SkillConfigurationCopy.text("Choose or enter a credential", "选择或填写凭据")) {
                            editor = .credential(field)
                        }
                        .disabled(!center.canEdit)
                        .accessibilityIdentifier("skill.configuration.credential.\(field.key)")
                        if center.fieldStatus(field.key)?.credentialReference != nil {
                            Button(SkillConfigurationCopy.text("Remove binding", "移除绑定"), role: .destructive) {
                                clearingField = .init(field: field)
                            }.disabled(!center.canEdit)
                        }
                        if field.declaredBy == .local { removeLocalFieldButton(field) }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(SkillConfigurationCopy.credentials)
            } footer: {
                Text(SkillConfigurationCopy.text(
                    "You can also provide credentials in a conversation. Saved secret values are never displayed here.",
                    "也可以在对话中提供凭据，此处不会显示已保存的秘密原值。"))
            }
        }
    }

    private var localEnvironmentSection: some View {
        Section {
            Button(SkillConfigurationCopy.text("Add environment variable", "添加环境变量"), systemImage: "plus") {
                editor = .addEnvironment
            }
            .disabled(!center.canEdit || center.hasChanges)
            .accessibilityIdentifier("skill.configuration.addEnvironment")
            if center.hasChanges {
                Text(SkillConfigurationCopy.text(
                    "Save parameter changes before adding or deleting variables.",
                    "请先保存参数更改，再添加或删除变量。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(center.status?.localDeclarationConflicts ?? [], id: \.fieldKey) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflict.environmentName).font(.body.monospaced())
                    Text(SkillConfigurationCopy.text(
                        "This local variable conflicts with the skill's configuration and is not being used.",
                        "此本地变量与技能配置冲突，暂不会使用。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(SkillConfigurationCopy.text("Delete local variable", "删除本地变量"), role: .destructive) {
                        removingLocalField = .init(key: conflict.fieldKey, name: conflict.environmentName)
                    }.disabled(!center.canEdit || center.hasChanges)
                }
            }
        } header: {
            Text(SkillConfigurationCopy.text("Local environment variables", "本地环境变量"))
        } footer: {
            Text(SkillConfigurationCopy.text(
                "Applies to this skill configuration. Adding a variable does not grant execution or network access.",
                "仅用于此技能配置，添加变量不会授予执行或网络访问权限。"))
        }
    }

    private func removeLocalFieldButton(_ field: SkillConfigFieldRequirement) -> some View {
        Button(SkillConfigurationCopy.text("Delete local variable", "删除本地变量"), role: .destructive) {
            removingLocalField = .init(key: field.key,
                name: center.requirements.environmentNames(fieldKey: field.key).first ?? field.title ?? field.key)
        }
        .disabled(!center.canEdit || center.hasChanges)
        .accessibilityIdentifier("skill.configuration.removeLocal.\(field.key)")
    }

    @ViewBuilder private var connectionSection: some View {
        let fields = center.requirements.fields.filter { $0.kind == .connection }
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 8) {
                        fieldHeader(field)
                        if let state = center.fieldStatus(field.key) {
                            Text(SkillConfigurationCopy.fieldState(state.state))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        NavigationLink(value: center.connectionRequest(field)) {
                            Label(SkillConfigurationCopy.text("Connection settings", "连接设置"), systemImage: "link")
                        }
                        .disabled(!center.canOpenConnection(field) || center.isMutating || center.hasChanges)
                        .accessibilityIdentifier("skill.configuration.connection.\(field.key)")
                        if !center.canOpenConnection(field) {
                            Text(SkillConfigurationCopy.text("Connection setup is not available in this version.", "此版本暂未提供该连接的配置页面。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                Button(SkillConfigurationCopy.text("Check connections", "检查连接")) {
                    Task { await center.validateConnections() }
                }
                .disabled(!center.canEdit || center.hasChanges)
                .accessibilityIdentifier("skill.configuration.validate")
                if center.hasChanges {
                    Text(SkillConfigurationCopy.text("Save parameter changes before checking connections.", "请先保存参数更改，再检查连接。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(SkillConfigurationCopy.connections)
            }
        }
    }

    @ViewBuilder private var feedbackSection: some View {
        if center.isMutating { Section { ProgressView() } }
        if let notice = center.notice { Section { Text(notice).font(.footnote) } }
        if let error = center.errorMessage {
            Section {
                Text(error).foregroundStyle(.red)
                Button(SkillConfigurationCopy.text("Reload saved configuration", "重新载入已保存配置")) {
                    Task { await center.load(force: true) }
                }.disabled(center.isMutating || center.hasChanges)
            }
        }
    }

    private func fieldHeader(_ field: SkillConfigFieldRequirement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.title ?? field.key).font(.body)
            if let detail = field.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            if field.required {
                Text(SkillConfigurationCopy.text("Required", "必填"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct SkillConfigurationAddEnvironmentView: View {
    let center: SkillConfigurationCenter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var label = ""
    @State private var isSecret = false

    private var validName: Bool {
        let bytes = Array(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard let first = bytes.first, bytes.count <= 64,
              (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || $0 == UInt8(ascii: "_")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(SkillConfigurationCopy.text("Variable name", "变量名"), text: $name)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("skill.configuration.environmentName")
                    TextField(SkillConfigurationCopy.text("Label (optional)", "显示名称（可选）"), text: $label)
                        .accessibilityIdentifier("skill.configuration.environmentLabel")
                } footer: {
                    Text(SkillConfigurationCopy.text(
                        "Use uppercase letters, numbers and underscores; start with a letter. Example: API_BASE_URL.",
                        "使用大写字母、数字和下划线，并以字母开头，例如 API_BASE_URL。"))
                }
                Section {
                    Picker(SkillConfigurationCopy.text("Type", "类型"), selection: $isSecret) {
                        Text(SkillConfigurationCopy.text("Ordinary value", "普通内容")).tag(false)
                        Text(SkillConfigurationCopy.text("Secret", "秘密凭据")).tag(true)
                    }
                    .accessibilityIdentifier("skill.configuration.environmentKind")
                } footer: {
                    Text(SkillConfigurationCopy.text(
                        "After adding, enter the value on the configuration page. For a secret, choose a saved credential or enter a new one.",
                        "添加后可在配置页填写内容；秘密凭据可选择已存凭据或填写新凭据。"))
                }
                if let error = center.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if center.isMutating { Section { ProgressView() } }
            }
            .disabled(center.isMutating)
            .navigationTitle(SkillConfigurationCopy.text("Add environment variable", "添加环境变量"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SkillConfigurationCopy.cancel) { clearDrafts(); dismiss() }
                        .disabled(center.isMutating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(SkillConfigurationCopy.text("Add", "添加")) {
                        Task {
                            if await center.addEnvironmentField(name: name, label: label, secret: isSecret) {
                                clearDrafts()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!validName || !center.canEdit || center.hasChanges || label.utf8.count > 120)
                    .accessibilityIdentifier("skill.configuration.confirmAddEnvironment")
                }
            }
            .interactiveDismissDisabled(center.isMutating)
            .onDisappear { clearDrafts() }
        }
    }

    private func clearDrafts() {
        name = ""
        label = ""
        isSecret = false
    }
}

private struct SkillConfigurationParameterRow: View {
    let field: SkillConfigFieldRequirement
    @Binding var value: String
    let environmentNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title ?? field.key)
            if field.valueType == .boolean {
                Picker(SkillConfigurationCopy.text("Value", "取值"), selection: $value) {
                    Text(SkillConfigurationCopy.text("Not set", "未设置")).tag("")
                    Text(SkillConfigurationCopy.text("On", "开启")).tag("true")
                    Text(SkillConfigurationCopy.text("Off", "关闭")).tag("false")
                }
            } else if field.valueType == .enumeration {
                Picker(SkillConfigurationCopy.text("Value", "取值"), selection: $value) {
                    Text(SkillConfigurationCopy.text("Not set", "未设置")).tag("")
                    ForEach(field.allowedValues, id: \.self) { Text($0).tag($0) }
                }
            } else {
                TextField(SkillConfigurationCopy.text("Value", "填写内容"), text: $value, axis: .vertical)
                    .keyboardType(field.valueType == .number ? .decimalPad : (field.valueType == .url ? .URL : .default))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(1...4)
            }
            if let detail = field.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            if field.required { Text(SkillConfigurationCopy.text("Required", "必填")).font(.caption).foregroundStyle(.secondary) }
            if !environmentNames.isEmpty {
                DisclosureGroup(SkillConfigurationCopy.text("Environment variables", "环境变量")) {
                    ForEach(environmentNames, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
        .accessibilityIdentifier("skill.configuration.value.\(field.key)")
        .padding(.vertical, 4)
    }
}

@MainActor
private struct SkillConfigurationCredentialEditor: View {
    let center: SkillConfigurationCenter
    let field: SkillConfigFieldRequirement
    @Environment(\.dismiss) private var dismiss
    @State private var useExisting = true
    @State private var credentialID: UUID?
    @State private var secret = ""
    @State private var share = false

    private var selected: SkillConfigurationCredentialChoice? {
        center.credentials.first { $0.id == credentialID }
    }

    private var canSave: Bool {
        guard center.canEdit else { return false }
        if useExisting {
            guard let selected else { return false }
            return selected.bindingCount == 0 || share
        }
        return !secret.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(SkillConfigurationCopy.text("Use", "使用方式"), selection: $useExisting) {
                        Text(SkillConfigurationCopy.text("Saved credential", "已存凭据")).tag(true)
                        Text(SkillConfigurationCopy.text("New credential", "新凭据")).tag(false)
                    }.pickerStyle(.segmented)
                }
                if useExisting {
                    Section {
                        if center.credentials.isEmpty {
                            Text(SkillConfigurationCopy.text("No compatible saved credentials. You can enter a new one.", "暂无可用的已存凭据，可以填写新凭据。"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(center.credentials) { choice in
                            Button {
                                credentialID = choice.id
                                share = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(choice.card.label)
                                        Text(Self.kindName(choice.card.kind)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if choice.id == credentialID { Image(systemName: "checkmark") }
                                }.foregroundStyle(.primary).frame(minHeight: 44)
                            }
                        }
                    }
                    if let selected, selected.bindingCount > 0 {
                        Section {
                            Toggle(SkillConfigurationCopy.text("Share with this configuration", "与此配置共享"), isOn: $share)
                        } footer: {
                            Text(SkillConfigurationCopy.text("This credential is already used by another binding. Removing this skill will not delete the shared credential.", "此凭据已用于其他绑定，卸载此技能不会删除共享凭据。"))
                        }
                    }
                } else {
                    Section {
                        SecureField(SkillConfigurationCopy.text("Credential", "凭据"), text: $secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("skill.configuration.newCredential")
                    } footer: {
                        Text(SkillConfigurationCopy.text("Saved in Keychain for this skill configuration. You can also provide it in chat.", "将存入此技能配置的钥匙串，也可以通过对话提供。"))
                    }
                }
                if let error = center.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if center.isMutating { Section { ProgressView() } }
            }
            .disabled(center.isMutating)
            .navigationTitle(field.title ?? field.key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SkillConfigurationCopy.cancel) { secret = ""; dismiss() }.disabled(center.isMutating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(SkillConfigurationCopy.save) {
                        Task {
                            let saved = await center.bind(field: field, secret: useExisting ? nil : secret,
                                credentialID: useExisting ? credentialID : nil, share: share)
                            secret = ""
                            if saved { dismiss() }
                        }
                    }.disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(center.isMutating)
            .task { await center.loadCredentials(for: field) }
            .onChange(of: useExisting) { _, _ in secret = "" }
            .onDisappear { secret = "" }
        }
    }

    private static func kindName(_ kind: CredentialKind) -> String {
        switch kind {
        case .providerAPIKey: SkillConfigurationCopy.text("API key", "API 密钥")
        case .sshPassword: SkillConfigurationCopy.text("SSH password", "SSH 密码")
        case .sshPrivateKey: SkillConfigurationCopy.text("SSH key", "SSH 密钥")
        case .vncPassword: SkillConfigurationCopy.text("VNC password", "VNC 密码")
        case .websitePassword: SkillConfigurationCopy.text("Account password", "账户密码")
        case .genericToken: SkillConfigurationCopy.text("Credential", "凭据")
        }
    }
}
#endif
