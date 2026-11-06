// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import PencilKit
import FloeNotes

@MainActor struct NotesInkShapePreview: View {
    let draft: NotesInkShapeDraft
    let session: NotesSession
    var onApplied: (NoteDocument) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var keepOriginal = true
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var originalImage: UIImage?
    @State private var candidateImage: UIImage?

    init(draft: NotesInkShapeDraft, session: NotesSession, onApplied: @escaping (NoteDocument) -> Void = { _ in }) {
        self.draft = draft; self.session = session; self.onApplied = onApplied
        _selected = State(initialValue: Set(draft.proposals.map(\.id)))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.scope == .selection
                         ? text("来源：所选笔迹", "Source: selected ink")
                         : text("来源：当前页笔迹", "Source: ink on this page"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            preview(originalImage, title: text("原迹", "Original ink")).frame(minWidth: 220)
                            preview(candidateImage, title: text("形状候选", "Shape candidates")).frame(minWidth: 220)
                        }
                        VStack(spacing: 12) {
                            preview(originalImage, title: text("原迹", "Original ink"))
                            preview(candidateImage, title: text("形状候选", "Shape candidates"))
                        }
                    }
                    if draft.proposals.isEmpty {
                        ContentUnavailableView(text("尚无形状候选", "No shape candidates"), systemImage: "pencil.and.outline",
                            description: Text(text("可用套索缩小范围后重试。", "Try selecting a smaller amount of ink with the lasso.")))
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(draft.proposals.enumerated()), id: \.element.id) { index, proposal in
                                Toggle("\(index + 1). \(proposal.title)", isOn: Binding(
                                    get: { selected.contains(proposal.id) },
                                    set: { enabled in
                                        if enabled { selected.insert(proposal.id) } else { selected.remove(proposal.id) }
                                    }))
                                    .frame(minHeight: 44)
                            }
                        }
                        Toggle(text("保留原笔迹", "Keep original ink"), isOn: $keepOriginal).frame(minHeight: 44)
                        Text(keepOriginal
                             ? text("应用后同时保留原迹与形状。", "Apply keeps both the original ink and the shapes.")
                             : text("仅替换勾选候选的来源笔迹；撤销可恢复原迹。", "Only the selected candidates replace their source strokes. Undo restores the original ink."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.orange) }
                }.padding(20).disabled(applying)
            }
            .navigationTitle(text("修形预览", "Convert ink to shapes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("取消", "Cancel")) { dismiss() }.disabled(applying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { apply() } label: {
                        if applying { ProgressView() } else { Text(text("应用", "Apply")) }
                    }.disabled(applying || selected.isEmpty || session.pendingWrites > 0)
                        .accessibilityIdentifier("notes.inkShape.apply")
                }
            }
            .interactiveDismissDisabled(applying)
            .onAppear { renderPreviews() }
            .onChange(of: selected) { _, _ in renderPreviews() }
            .accessibilityIdentifier("notes.inkShape.preview")
        }.presentationDetents([.large])
    }
    private func preview(_ image: UIImage?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "scribble.variable").font(.largeTitle).foregroundStyle(.gray) }
            }.frame(maxWidth: .infinity).frame(height: 230)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.25)))
        }
    }
    private func renderPreviews() {
        let source = draft.sourcePreview, candidate = draft.candidatePreview(selected: selected)
        let bounds = (candidate.strokes.isEmpty ? source.bounds : source.bounds.union(candidate.bounds)).insetBy(dx: -12, dy: -12)
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(2, 1536 / max(bounds.width, bounds.height))
        originalImage = source.image(from: bounds, scale: scale)
        candidateImage = selected.isEmpty ? nil : candidate.image(from: bounds, scale: scale)
    }
    private func apply() {
        applying = true; errorMessage = nil
        Task { @MainActor in
            do {
                let result = try await session.applyInkShapes(draft, selected: selected, keepOriginal: keepOriginal)
                onApplied(result); dismiss()
            } catch { errorMessage = error.localizedDescription }
            applying = false
        }
    }
    private func text(_ zh: String, _ en: String) -> String { NotesInkShapeText.text(zh, en) }
}
#endif
