// FloeApp — format-aware Office command panel.
//
// The same validated `OfficeEngineCommand` catalog the agent tools use is the
// UI's only action surface: every control dispatches through the live session
// (with the saved-package verification), and model-authored proposals appear
// here for an explicit accept/discard. No control invents a command that the
// document.office.edit contract cannot verify.

#if canImport(UIKit)
import SwiftUI
import FloeDocuments
import FloeCore

struct OfficeCommandPanel: View {
    let documentID: String
    let format: OfficeDocumentFormat
    @ObservedObject var session: OfficeFileSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var proposals: [OfficeCommandProposal] = []
    @State private var busy = false
    @State private var message: String?

    // Word
    @State private var style = "Heading 1"
    @State private var alignment: OfficeParagraphAlignment = .left
    @State private var tableRows = 3
    @State private var tableColumns = 3

    // Excel
    @State private var cell = "A1"
    @State private var numberFormat: OfficeNumberFormat = .decimal
    @State private var count = 1
    @State private var sortRange = ""
    @State private var errorCells: [OfficeErrorCell] = []

    // Presentation
    @State private var slideIndex = 1
    @State private var moveFrom = 1
    @State private var moveTo = 2

    private var center: OfficeCommandCenter { environment.officeCommandCenter }

    var body: some View {
        NavigationStack {
            Form {
                if !proposals.isEmpty {
                    proposalsSection
                }
                switch format {
                case .docx: wordSection
                case .xlsx: excelSection
                case .pptx: presentationSection
                }
                if !errorCells.isEmpty {
                    Section(OfficeInkText.t("公式错误", "Formula errors")) {
                        ForEach(errorCells, id: \.cell) { error in
                            Button {
                                Task { await run([.excelGoToCell(error.cell)]) }
                            } label: {
                                LabeledContent(error.cell, value: error.error)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                }
                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if session.canRevertLastEngineBatch {
                    Section(OfficeInkText.t("批量撤销", "Batch revert")) {
                        Button {
                            Task { _ = await session.revertLastEngineBatch() }
                        } label: {
                            Label(OfficeInkText.t("撤销上一批命令", "Revert previous command batch"),
                                  systemImage: "arrow.uturn.backward")
                                .frame(minHeight: 44)
                        }
                        Text(OfficeInkText.t(
                            "该引擎版本没有撤销分组命令；此操作恢复批次前的精确字节并要求文件 SHA 未变化，文档变化或有未保存修改时会拒绝。",
                            "This engine build has no undo-group command; this restores the exact pre-batch bytes with a SHA check and refuses when the document changed or has unsaved edits."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(OfficeInkText.t("文档命令", "Document commands"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(OfficeInkText.t("关闭", "Close")) { dismiss() }
                }
            }
            .disabled(busy)
            .task { await refreshProposals() }
        }
    }

    // MARK: Sections

    @ViewBuilder private var proposalsSection: some View {
        Section(OfficeInkText.t("待确认的助手提案", "Pending assistant proposals")) {
            ForEach(proposals, id: \.id) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    Text(proposal.summary).font(.callout)
                    Text(proposal.targetSummary).font(.caption).foregroundStyle(.secondary)
                    ForEach(proposal.expectations.prefix(6), id: \.self) { expectation in
                        Text("• \(expectation)").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(OfficeInkText.t("应用", "Apply")) {
                            Task { await apply(proposal) }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        Button(OfficeInkText.t("放弃", "Discard"), role: .destructive) {
                            Task { await discard(proposal) }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    @ViewBuilder private var wordSection: some View {
        Section(OfficeInkText.t("段落", "Paragraphs")) {
            Picker(OfficeInkText.t("样式", "Style"), selection: $style) {
                ForEach(OfficeEngineCommandCatalog.paragraphStyles, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .onChange(of: style) { _, value in
                Task { await run([.wordStyle(name: value)]) }
            }
            .frame(minHeight: 44)

            Picker(OfficeInkText.t("对齐", "Alignment"), selection: $alignment) {
                Text(OfficeInkText.t("左", "Left")).tag(OfficeParagraphAlignment.left)
                Text(OfficeInkText.t("居中", "Center")).tag(OfficeParagraphAlignment.center)
                Text(OfficeInkText.t("右", "Right")).tag(OfficeParagraphAlignment.right)
                Text(OfficeInkText.t("两端", "Justified")).tag(OfficeParagraphAlignment.justified)
            }
            .pickerStyle(.segmented)
            .onChange(of: alignment) { _, value in
                Task { await run([.wordAlignment(value)]) }
            }

            HStack {
                Button {
                    Task { await run([.wordBulletList]) }
                } label: { Label(OfficeInkText.t("项目符号", "Bulleted"), systemImage: "list.bullet") }
                    .frame(minHeight: 44)
                Button {
                    Task { await run([.wordNumberedList]) }
                } label: { Label(OfficeInkText.t("编号", "Numbered"), systemImage: "list.number") }
                    .frame(minHeight: 44)
            }
        }
        Section(OfficeInkText.t("表格", "Table")) {
            Stepper(OfficeInkText.t("行 \(tableRows)", "Rows \(tableRows)"), value: $tableRows, in: 1...100)
            Stepper(OfficeInkText.t("列 \(tableColumns)", "Columns \(tableColumns)"), value: $tableColumns, in: 1...20)
            Button {
                Task { await run([.wordInsertTable(rows: tableRows, columns: tableColumns)]) }
            } label: { Label(OfficeInkText.t("在光标处插入表格", "Insert table at cursor"), systemImage: "tablecells") }
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder private var excelSection: some View {
        Section(OfficeInkText.t("目标单元格", "Target cell")) {
            TextField(OfficeInkText.t("单元格（如 B2）", "Cell (e.g. B2)"), text: $cell)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("office.commands.cell")
        }
        Section(OfficeInkText.t("数字格式", "Number format")) {
            Picker(OfficeInkText.t("格式", "Format"), selection: $numberFormat) {
                Text(OfficeInkText.t("常规", "Standard")).tag(OfficeNumberFormat.standard)
                Text(OfficeInkText.t("数值", "Decimal")).tag(OfficeNumberFormat.decimal)
                Text(OfficeInkText.t("百分比", "Percent")).tag(OfficeNumberFormat.percent)
                Text(OfficeInkText.t("货币", "Currency")).tag(OfficeNumberFormat.currency)
                Text(OfficeInkText.t("日期", "Date")).tag(OfficeNumberFormat.date)
                Text(OfficeInkText.t("时间", "Time")).tag(OfficeNumberFormat.time)
                Text(OfficeInkText.t("科学计数", "Scientific")).tag(OfficeNumberFormat.scientific)
                Text(OfficeInkText.t("千位分隔", "Thousands")).tag(OfficeNumberFormat.thousands)
            }
            Button {
                Task { await run([.excelNumberFormat(numberFormat, cell: cell)]) }
            } label: { Label(OfficeInkText.t("应用数字格式", "Apply number format"), systemImage: "number") }
                .frame(minHeight: 44)
        }
        Section(OfficeInkText.t("行与列", "Rows & columns")) {
            Stepper(OfficeInkText.t("数量 \(count)", "Count \(count)"), value: $count, in: 1...100)
            HStack {
                Button(OfficeInkText.t("插入行", "Insert rows")) {
                    Task { await run([.excelInsertRows(count: count, at: cell)]) }
                }
                Button(OfficeInkText.t("删除行", "Delete rows"), role: .destructive) {
                    Task { await run([.excelDeleteRows(count: count, at: cell)]) }
                }
            }
            .frame(minHeight: 44)
            HStack {
                Button(OfficeInkText.t("插入列", "Insert columns")) {
                    Task { await run([.excelInsertColumns(count: count, at: cell)]) }
                }
                Button(OfficeInkText.t("删除列", "Delete columns"), role: .destructive) {
                    Task { await run([.excelDeleteColumns(count: count, at: cell)]) }
                }
            }
            .frame(minHeight: 44)
        }
        Section(OfficeInkText.t("视图与数据", "View & data")) {
            Button {
                Task { await run([.excelFreezePanes(at: cell)]) }
            } label: { Label(OfficeInkText.t("在目标单元格冻结窗格", "Freeze panes at cell"), systemImage: "snowflake") }
                .frame(minHeight: 44)
            TextField(OfficeInkText.t("排序范围（可留空，如 A1:C9）", "Sort range (optional, e.g. A1:C9)"), text: $sortRange)
            HStack {
                Button(OfficeInkText.t("升序", "Ascending")) {
                    Task { await run([.excelSort(ascending: true, range: sortRange.isEmpty ? nil : sortRange)]) }
                }
                Button(OfficeInkText.t("降序", "Descending")) {
                    Task { await run([.excelSort(ascending: false, range: sortRange.isEmpty ? nil : sortRange)]) }
                }
            }
            .frame(minHeight: 44)
            Button {
                Task { await run([.excelAutoFilter]) }
            } label: { Label(OfficeInkText.t("切换自动筛选", "Toggle AutoFilter"), systemImage: "line.3.horizontal.decrease.circle") }
                .frame(minHeight: 44)
            Button {
                Task { await run([.excelRecalculate]) }
            } label: { Label(OfficeInkText.t("重新计算", "Recalculate"), systemImage: "function") }
                .frame(minHeight: 44)
            Button {
                Task { await loadErrorCells() }
            } label: { Label(OfficeInkText.t("检查公式错误", "Check formula errors"), systemImage: "exclamationmark.triangle") }
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder private var presentationSection: some View {
        Section(OfficeInkText.t("幻灯片", "Slides")) {
            Stepper(OfficeInkText.t("目标位置 \(slideIndex)", "Target position \(slideIndex)"),
                    value: $slideIndex, in: 1...500)
            Button {
                Task { await run([.pptDuplicateSlide(at: slideIndex)]) }
            } label: { Label(OfficeInkText.t("复制当前幻灯片", "Duplicate current slide"), systemImage: "plus.square.on.square") }
                .frame(minHeight: 44)
            HStack {
                Stepper(OfficeInkText.t("从 \(moveFrom)", "From \(moveFrom)"), value: $moveFrom, in: 1...500)
                Stepper(OfficeInkText.t("到 \(moveTo)", "To \(moveTo)"), value: $moveTo, in: 1...500)
            }
            Button {
                Task { await run([.pptMoveSlide(from: moveFrom, to: moveTo)]) }
            } label: { Label(OfficeInkText.t("移动幻灯片", "Move slide"), systemImage: "arrow.up.arrow.down") }
                .frame(minHeight: 44)
            Text(OfficeInkText.t("移动通过复制到目标位置并删除原页完成；内容与备注保留，页面身份可能重置。",
                                 "Move duplicates to the target position and deletes the original; content and notes are preserved, slide identity may reset."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section(OfficeInkText.t("对象对齐", "Object alignment")) {
            HStack {
                alignmentButton(.left, symbol: "align.horizontal.left")
                alignmentButton(.center, symbol: "align.horizontal.center")
                alignmentButton(.right, symbol: "align.horizontal.right")
                alignmentButton(.top, symbol: "align.vertical.top")
                alignmentButton(.middle, symbol: "align.vertical.center")
                alignmentButton(.bottom, symbol: "align.vertical.bottom")
            }
        }
    }

    private func alignmentButton(_ value: OfficeObjectAlignment, symbol: String) -> some View {
        Button {
            Task { await run([.pptAlignObjects(value)]) }
        } label: {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Actions

    @MainActor private func run(_ commands: [OfficeEngineCommand]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            for command in commands { try command.validate() }
            let fingerprint = commands.contains(where: \.requiresSelectionFingerprint)
                ? await session.liveSelectionFingerprint()
                : nil
            let result = try await session.applyEngineCommands(
                commands, expectedSelectionFingerprint: fingerprint)
            let verified = result.facts.isEmpty
                ? OfficeInkText.t("已应用并保存。", "Applied and saved.")
                : result.facts.joined(separator: ", ")
            message = OfficeInkText.t("已应用并保存：\(verified)", "Applied and saved: \(verified)")
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor private func loadErrorCells() async {
        busy = true
        defer { busy = false }
        do {
            errorCells = try await session.formulaErrorCells()
            if errorCells.isEmpty {
                message = OfficeInkText.t("未发现公式错误单元格。", "No formula-error cells found.")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor private func refreshProposals() async {
        proposals = await center.pendingProposals(documentID: documentID)
    }

    @MainActor private func apply(_ proposal: OfficeCommandProposal) async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            let receipt = try await center.approveAndApply(proposal: proposal)
            proposals.removeAll { $0.id == proposal.id }
            message = OfficeInkText.t(
                "已应用并保存（\(receipt.verified.joined(separator: ", "))）。",
                "Applied and saved (\(receipt.verified.joined(separator: ", "))).")
            await notify(proposal: proposal, decision: "applied",
                         revision: nil, sha256: receipt.sha256)
            // Reflect the committed bytes in the live editor (the user had no
            // unsaved changes; the proposal refused a dirty session).
            try? await session.reloadAfterEngineApply()
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor private func discard(_ proposal: OfficeCommandProposal) async {
        await center.discardProposal(id: proposal.id)
        proposals.removeAll { $0.id == proposal.id }
        message = OfficeInkText.t("已放弃该提案。", "Proposal discarded.")
        await notify(proposal: proposal, decision: "rejected", revision: nil, sha256: nil)
    }

    /// Tells the originating task through the durable runtime-input ingress;
    /// the model cannot author this event.
    @MainActor private func notify(proposal: OfficeCommandProposal, decision: String,
                                   revision: Int64?, sha256: String?) async {
        guard let conversationID = await center.proposalOwnerConversation(proposalID: proposal.id) else {
            return
        }
        try? await environment.conversationCenter.recordProposalDecision(
            conversationID: conversationID, proposalID: proposal.id, decision: decision,
            revision: revision, sha256: sha256)
    }
}
#endif
