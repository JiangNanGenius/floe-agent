// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD

/// Native snapshot handoff, then the existing independent print editor.
struct PrintPreparationSheet: View {
    let request: PrintPreparationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var unitScale = 1.0
    @State private var isPreparing = false
    @State private var diagnostic: String?
    @State private var coverage: CADExchangeCoverage?
    @State private var createdWork: PersonalContentRecord?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Group {
            if let createdWork {
                PersonalContentEditor(record: createdWork)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            TextField(IDELanguageRunText.t("名称", "Name"), text: $title)
                                .disabled(isPreparing)
                            if request.requiresMeshUnits {
                                Picker(IDELanguageRunText.t("模型单位", "Model units"), selection: $unitScale) {
                                    Text(IDELanguageRunText.t("毫米", "Millimetres")).tag(1.0)
                                    Text(IDELanguageRunText.t("厘米", "Centimetres")).tag(10.0)
                                    Text(IDELanguageRunText.t("米", "Metres")).tag(1_000.0)
                                    Text(IDELanguageRunText.t("英寸", "Inches")).tag(25.4)
                                }.disabled(isPreparing)
                            }
                            Text(IDELanguageRunText.t("将几何复制到新的打印工程，原件保留。", "Copy geometry into a new print project and keep the original."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let coverage {
                            Section(IDELanguageRunText.t("查看复制内容", "Review copied content")) {
                                LabeledContent(IDELanguageRunText.t("可复制对象", "Available objects"), value: coverage.includedCount.formatted())
                                if coverage.excludedCount > 0 {
                                    LabeledContent(IDELanguageRunText.t("无法复制", "Excluded objects"), value: coverage.excludedCount.formatted())
                                    ForEach(Array(coverage.excludedItems.prefix(5).enumerated()), id: \.offset) { _, item in
                                        Text(item.name).font(.footnote)
                                    }
                                }
                                ForEach(Array(coverage.formatLoss.prefix(4).enumerated()), id: \.offset) { _, loss in
                                    Text(loss).font(.footnote).foregroundStyle(.secondary)
                                }
                                Button(IDELanguageRunText.t("复制可用几何", "Copy available geometry")) { prepare(accepting: coverage) }
                                    .disabled(isPreparing || coverage.includedCount == 0)
                                    .accessibilityIdentifier("print.prepare.acceptAvailable")
                            }
                        }
                        if let diagnostic {
                            Section { Text(diagnostic).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Section {
                            Button { prepare(accepting: nil) } label: {
                                HStack {
                                    Label(IDELanguageRunText.t("准备打印", "Prepare Print"), systemImage: "printer")
                                    Spacer()
                                    if isPreparing { ProgressView() }
                                }
                            }.disabled(isPreparing || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("print.prepare.create")
                        }
                    }
                    .navigationTitle(IDELanguageRunText.t("准备打印", "Prepare Print"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(IDELanguageRunText.t("取消", "Cancel")) { operation?.cancel(); dismiss() }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isPreparing)
        .onAppear { if title.isEmpty { title = request.title } }
        .onChange(of: unitScale) { _, _ in coverage = nil }
        .onDisappear { operation?.cancel(); operation = nil }
    }

    @MainActor private func prepare(accepting: CADExchangeCoverage?) {
        guard !isPreparing else { return }
        isPreparing = true; diagnostic = nil
        operation = Task { @MainActor in
            defer { isPreparing = false; operation = nil }
            do {
                let work = try await request.prepare(title.trimmingCharacters(in: .whitespacesAndNewlines), unitScale, accepting)
                try Task.checkCancellation()
                coverage = nil; createdWork = work
            } catch is CancellationError { return }
            catch PrintHandoffError.incomplete(let value) { coverage = value }
            catch { diagnostic = error.localizedDescription }
        }
    }
}
#endif
