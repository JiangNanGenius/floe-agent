// FloeApp — Collapsible "thinking" block.
//
// SPDX-License-Identifier: MPL-2.0
//
// Reasoning is separated from the answer behind a DisclosureGroup,
// collapsed by default: a one-line preview when folded, full selectable
// text plus a copy action when expanded. Animation honors Reduce Motion
// via FloeTheme.motionAnimation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A foldable reasoning ("思考过程") block.
struct ReasoningBlockView: View {
    let text: String
    /// True while reasoning is still streaming (shows a spinner).
    var isStreaming: Bool = false

    @State private var isExpanded = false
    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLongText: Bool { text.utf8.count > 8_192 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(isLongText ? nil : FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isStreaming {
                        ProgressView().controlSize(.small)
                    }
                    Text("reasoning.title")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                    if !isExpanded {
                        Text(preview)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reasoning.expand")
            if isExpanded {
                if isLongText {
                    LongReasoningReader(text: text, isStreaming: isStreaming)
                } else {
                    Text(text)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button {
                        UIPasteboard.general.string = text
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    } label: {
                        Label(
                            didCopy
                                ? LocalizedStringKey("action.copied")
                                : LocalizedStringKey("action.copy"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(didCopy ? FloeTheme.success : FloeTheme.primary)
                    }
                    .buttonStyle(.plain)
                    .frame(
                        minWidth: FloeTheme.minimumTarget,
                        minHeight: FloeTheme.minimumTarget
                    )
                }
            }
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .animation(isLongText ? nil : FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: isExpanded)
    }

    /// Last non-empty line as the folded preview.
    private var preview: String {
        text.suffix(512).split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Immutable, stable fragments keep Text layout bounded even without newlines.
/// Joining their source strings reproduces the full transcript exactly.
struct ReasoningTextChunk: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String

    static let maximumCharacters = 1_024

    nonisolated static func split(_ source: String) -> [Self] {
        var chunks: [Self] = []
        var start = source.startIndex
        while start < source.endIndex {
            let end = source.index(start, offsetBy: maximumCharacters, limitedBy: source.endIndex) ?? source.endIndex
            chunks.append(Self(id: chunks.count, text: String(source[start..<end])))
            start = end
        }
        return chunks
    }
}

/// One coalescing worker, not a new parse task for every token. Preparation
/// happens off the main actor and finished snapshots are published in order.
@MainActor
final class ReasoningTextLayout: ObservableObject {
    @Published private(set) var chunks: [ReasoningTextChunk] = []
    private var pending: String?
    private var worker: Task<Void, Never>?
    private var generation = 0

    func submit(_ source: String) {
        pending = source
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, token == generation, let source = pending {
                pending = nil
                let prepared = await Task.detached(priority: .userInitiated) {
                    ReasoningTextChunk.split(source)
                }.value
                guard !Task.isCancelled, token == generation else { return }
                chunks = prepared
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            if token == generation { worker = nil }
        }
    }

    func stop() {
        generation += 1
        pending = nil
        worker?.cancel()
        worker = nil
    }
}

private struct ReasoningTextFragment: View, Equatable {
    let chunk: ReasoningTextChunk
    var body: some View {
        Text(verbatim: chunk.text)
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("reasoning.chunk.\(chunk.id)")
    }
}

private struct LongReasoningReader: View {
    let text: String
    let isStreaming: Bool
    @StateObject private var layout = ReasoningTextLayout()
    @State private var fullscreen = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(isStreaming ? "思考内容持续更新中" : "思考全文")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right") { fullscreen = true }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("reasoning.fullscreen")
            }
            reader.frame(height: 340)
        }
        .onAppear { layout.submit(text) }
        .onChange(of: text) { _, source in layout.submit(source) }
        .onDisappear { layout.stop() }
        .fullScreenCover(isPresented: $fullscreen) {
            NavigationStack {
                reader.padding()
                    .navigationTitle("思考全文")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { fullscreen = false }
                                .accessibilityIdentifier("reasoning.fullscreen.done")
                        }
                    }
            }
        }
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 4) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(layout.chunks) { chunk in
                            ReasoningTextFragment(chunk: chunk).equatable().id(chunk.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("reasoning.reader")
                .overlay { if layout.chunks.isEmpty { ProgressView() } }
                HStack {
                    Button("回到开头") { if let first = layout.chunks.first { proxy.scrollTo(first.id, anchor: .top) } }
                        .accessibilityIdentifier("reasoning.first")
                    Spacer()
                    Button(isStreaming ? "最新内容" : "到结尾") {
                        if let last = layout.chunks.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .accessibilityIdentifier("reasoning.latest")
                }
                .font(FloeTheme.Typography.metadata)
                .frame(minHeight: 44)
                .disabled(layout.chunks.isEmpty)
            }
        }
    }
}

#if DEBUG
/// Synthetic transcript only; exercises the real disclosure and reader with
/// no provider, account or personal conversation needed for regression captures.
struct LongReasoningTestHarness: View {
    @State private var text = String(repeating: "长文测试，保留全部思考内容。👨‍👩‍👧‍👦é\n", count: 4_000) + "原文结束标记"
    @State private var additions = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                ReasoningBlockView(text: text, isStreaming: true).padding()
            }
            .navigationTitle("长文性能测试")
            .safeAreaInset(edge: .bottom) {
                Button("追加内容 \(additions)") {
                    additions += 1
                    text += String(repeating: "追加思考内容，完整保留。", count: 200) + "追加结束标记\(additions)"
                }
                .accessibilityIdentifier("reasoning.fixture.append")
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            }
        }
    }
}
#endif
#endif
