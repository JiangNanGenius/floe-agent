// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeGameCore
import FloeGameStarterKit
import FloeGameProjectFlow

public typealias GameProjectEngineSelectionHandler =
    @MainActor (GameRelativePath?, GameEngineID) -> Void
public typealias GameProjectEngineCreationHandler =
    @MainActor (GameEngineID) -> Void

/// Optional reference picker. Root owns the final visual direction; this view
/// only presents a dense iPad-friendly list and never starts a run by itself.
@MainActor
public struct GameProjectSelectionPicker: View {
    public let snapshot: GameProjectSelectionSnapshot
    public let creationCapabilities: [GameProjectEngineCapability]
    public let onSelect: GameProjectEngineSelectionHandler
    public let onCreate: GameProjectEngineCreationHandler?

    @State private var rootID: String

    public init(snapshot: GameProjectSelectionSnapshot,
                creationCapabilities: [GameProjectEngineCapability] = [],
                onSelect: @escaping GameProjectEngineSelectionHandler,
                onCreate: GameProjectEngineCreationHandler? = nil) {
        self.snapshot = snapshot
        self.creationCapabilities = creationCapabilities
        self.onSelect = onSelect
        self.onCreate = onCreate
        _rootID = State(initialValue: snapshot.selectedRoot?.value
            ?? snapshot.choices.first?.id ?? ".")
    }

    public var body: some View {
        List {
            Section {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller")
                        Text(text("游戏工程", "Game project"))
                    }
                    Spacer()
                    Text(stateText(snapshot.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot.isEmptyProject {
                    Text(text("先选择引擎并新建，或导入一个完整工程。",
                              "Create from an engine or import a complete project first."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let engine = snapshot.selectedEngine,
                          let capability = snapshot.engines(forRoot: snapshot.selectedRoot)
                            .first(where: { $0.engine == engine }) {
                    HStack {
                        Text(text("当前引擎", "Engine"))
                        Spacer()
                        Text(capability.displayName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(text("游戏目录", "Game folder"))
                        Spacer()
                        Text(rootText(snapshot.selectedRoot))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(snapshot.ambiguities, id: \.self) { ambiguity in
                    Text(ambiguityText(ambiguity))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(snapshot.choices) { choice in
                    Button {
                        rootID = choice.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: rootID == choice.id
                                ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(rootID == choice.id
                                    ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rootText(choice.root))
                                Text(engineSummary(choice.engines))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(choice.engines.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(text("游戏目录", "Game folders"))
            } footer: {
                Text(text("多个目录或引擎不会自动挑选。",
                          "Multiple folders or engines are never chosen automatically."))
                    .font(.caption2)
            }

            if let choice = activeChoice, !choice.engines.isEmpty {
                Section {
                    ForEach(choice.engines, id: \.engine) { capability in
                        engineRow(capability, root: choice.root)
                    }
                } header: {
                    Text(text("引擎", "Engines"))
                } footer: {
                    if !hasHostReport(choice.engines) {
                        Text(text("编辑器/运行时状态尚未由宿主验证，不表示已安装。",
                                  "Editor/runtime state is not host-verified. Nothing is claimed installed."))
                            .font(.caption2)
                    }
                }
            }

            if let ai = snapshot.aiRecommendation {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(ai.engine))
                            .font(.headline)
                        Text(ai.rationale)
                            .font(.caption)
                        Text(text("来源：", "Source: ") + ai.generatedBy)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if snapshot.isEmptyProject, onCreate != nil {
                        Button {
                            onCreate?(ai.engine)
                        } label: {
                            Text(text("按 AI 建议新建", "Create using AI suggestion"))
                        }
                    } else {
                        Button {
                            onSelect(ai.root, ai.engine)
                        } label: {
                            Text(text("采用 AI 建议", "Use AI suggestion"))
                        }
                        .disabled(!isRecognized(ai.root, ai.engine))
                    }
                } header: {
                    Text(text("AI 建议", "AI suggestion"))
                } footer: {
                    Text(text("仅作建议；需要用户确认后才会成为选择。",
                              "Advisory only. It becomes the selection only after the user confirms."))
                        .font(.caption2)
                }
            }

            if let heuristic = snapshot.heuristicRecommendation {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(heuristic.engine))
                            .font(.headline)
                        Text(heuristicText(heuristic))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(text("识别建议（非 AI）", "Recognition hint (not AI)"))
                }
            }

            if snapshot.isEmptyProject, onCreate != nil, !creationCapabilities.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(creationCapabilities, id: \.engine) { capability in
                            Button {
                                onCreate?(capability.engine)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(capability.displayName)
                                        Text(readinessText(capability))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let present = capability.preparedRuntimePackPresent {
                                        Text(present
                                            ? text("已提供包", "Pack supplied")
                                            : text("需要准备包", "Pack required"))
                                            .font(.caption2)
                                            .foregroundStyle(present
                                                ? Color.secondary : Color.orange)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Text(text("按引擎新建", "Create by engine"))
                    }
                } footer: {
                    Text(text("实际创建仍由现有 starter scaffolder 校验；缺少编辑器或运行时不会被声称已安装。",
                              "Creation is verified by the existing starter scaffolder. Missing editors/runtimes are never claimed installed."))
                        .font(.caption2)
                }
            }

            if !snapshot.diagnostics.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(snapshot.diagnostics.indices, id: \.self) { index in
                            Text("\(snapshot.diagnostics[index].source.rawValue): "
                                + snapshot.diagnostics[index].message)
                                .font(.caption2)
                                .textSelection(.enabled)
                        }
                    } label: {
                        Text(text("诊断", "Diagnostics"))
                    }
                }
            }
        }
        .onChange(of: snapshot.projectID) { _, _ in
            rootID = snapshot.selectedRoot?.value ?? snapshot.choices.first?.id ?? "."
        }
        .onChange(of: snapshot.selectedRoot?.value) { _, value in
            if let value = value {
                rootID = value
            } else {
                rootID = snapshot.choices.first(where: { $0.isProjectRoot })?.id ?? "."
            }
        }
    }

    private var activeChoice: GameProjectSelectionChoice? {
        snapshot.choices.first(where: { $0.id == rootID }) ?? snapshot.choices.first
    }

    @ViewBuilder
    private func engineRow(_ capability: GameProjectEngineCapability,
                           root: GameRelativePath?) -> some View {
        Button {
            onSelect(root, capability.engine)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(capability.displayName)
                        .font(.body.weight(.medium))
                    Spacer()
                    if snapshot.selectedRoot == root,
                       snapshot.selectedEngine == capability.engine {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                HStack(spacing: 6) {
                    badge(readinessText(capability))
                    if let ai = snapshot.aiRecommendation, ai.engine == capability.engine {
                        badge(text("AI 建议", "AI suggestion"), color: .purple)
                    }
                    if let heuristic = snapshot.heuristicRecommendation,
                       heuristic.engine == capability.engine {
                        badge(text("识别建议", "Hint"), color: .orange)
                    }
                }
                if !capability.recognizedMarkerPaths.isEmpty {
                    Text(evidenceText(capability))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ value: String, color: Color = .secondary) -> some View {
        Text(value)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func hasHostReport(_ engines: [GameProjectEngineCapability]) -> Bool {
        engines.contains { capability in
            capability.prerequisites.contains { state in
                if case .reported = state.host { return true }
                return false
            }
        }
    }

    private func isRecognized(_ root: GameRelativePath?, _ engine: GameEngineID) -> Bool {
        snapshot.engines(forRoot: root).contains { $0.engine == engine }
    }

    private func stateText(_ state: GameProjectSelectionState) -> String {
        switch state {
        case .empty: return text("空工程", "Empty")
        case .unresolved: return text("未识别引擎", "Engine not recognized")
        case .ambiguous: return text("需要选择", "Choose one")
        case .automatic: return text("已自动选择", "Auto-selected")
        case .confirmed: return text("已确认", "Confirmed")
        }
    }

    private func rootText(_ root: GameRelativePath?) -> String {
        guard let root = root else { return text("工程根目录", "Project root") }
        return root.value
    }

    private func engineSummary(_ engines: [GameProjectEngineCapability]) -> String {
        if engines.isEmpty { return text("未识别引擎", "No engine recognized") }
        return engines.map { $0.displayName }.joined(separator: " · ")
    }

    private func readinessText(_ capability: GameProjectEngineCapability) -> String {
        switch capability.starterReadiness {
        case .completeSource: return text("完整源码", "Complete source")
        case .sourceWithBuildTool: return text("源码 + 构建工具", "Source + build tool")
        case .sourceWithEditor: return text("源码 + 编辑器", "Source + editor")
        case .runtimePackRequired: return text("需要运行时包", "Runtime pack required")
        }
    }

    private func evidenceText(_ capability: GameProjectEngineCapability) -> String {
        let paths = capability.recognizedMarkerPaths.prefix(3).map(\.value)
            .joined(separator: ", ")
        return text("识别依据：", "Recognized from: ") + paths
    }

    private func heuristicText(_ recommendation: GameProjectHeuristicRecommendation) -> String {
        switch recommendation.reason {
        case .strongestEvidence:
            return text("目录内标记最多；仅供确认，不是 AI。",
                        "Most markers in this folder. A hint, not AI.")
        case .tieByCatalogOrder:
            return text("证据相同，按固定目录顺序给出；仅供确认，不是 AI。",
                        "Evidence tied; fixed catalog order. A hint, not AI.")
        }
    }

    private func ambiguityText(_ ambiguity: GameProjectSelectionAmbiguity) -> String {
        switch ambiguity {
        case .multipleRoots(let roots):
            return text("发现 \(roots.count) 个游戏目录，需要明确选择。",
                        "\(roots.count) game folders need an explicit choice.")
        case .multipleEngines(let root, let engines):
            return text("\(rootText(root)) 识别到 \(engines.count) 个引擎，需要明确选择。",
                        "\(engines.count) engines in \(rootText(root)); choose one.")
        case .noEngineRecognized(let root):
            return text("\(rootText(root)) 未识别到支持的引擎。",
                        "No supported engine in \(rootText(root)).")
        case .noEngineRecognizedAnywhere:
            return text("所有目录都未识别到支持的引擎。",
                        "No supported engine was recognized in any folder.")
        case .persistedSelectionInvalidated:
            return text("上次选择已因内容变化失效。",
                        "The previous choice no longer matches the project.")
        case .manualSelectionUnverified:
            return text("这是手动选择，没有识别依据；试玩和构建保持关闭。",
                        "This manual choice has no recognized evidence; play and build stay closed.")
        }
    }

    private func displayName(_ engine: GameEngineID) -> String {
        creationCapabilities.first { $0.engine == engine }?.displayName
            ?? snapshot.choices.flatMap(\.engines)
                .first { $0.engine == engine }?.displayName
            ?? engine.rawValue
    }

    private func text(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }
}
