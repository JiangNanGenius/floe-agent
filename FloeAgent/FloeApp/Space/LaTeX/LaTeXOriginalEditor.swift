// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore

struct LaTeXOpenRequest:Identifiable {let id:UUID}

/// A task/Notes original opens in the same editor used by Space. Native
/// selection never changes its persisted owner or another editor's state.
struct LaTeXOriginalEditor:View {
    let projectID:UUID
    @EnvironmentObject private var environment:AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var session:LaTeXProjectSession?
    @State private var diagnostic:String?
    @State private var assistant=false
    var body:some View {
        NavigationStack {
            Group {
                if let session {LaTeXEditorSurface(session:session,onAssistant:{assistant=true})}
                else if let diagnostic {ContentUnavailableView(IDELanguageRunText.t("无法打开论文","Unable to open document"),systemImage:"doc.badge.ellipsis",description:Text(diagnostic))}
                else {ProgressView()}
            }
            .navigationTitle(session?.editor.manifest?.title ?? IDELanguageRunText.t("LaTeX 论文","LaTeX document"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.confirmationAction) {
                Button(IDELanguageRunText.t("完成","Done")) {Task {if await session?.flushForClose() != false {dismiss()}}}
            }}
        }
        .interactiveDismissDisabled()
        .task(id:projectID) {
            do {session=try await LaTeXProjectSession.open(id:projectID,composition:environment.latexComposition)}
            catch {diagnostic=error.localizedDescription}
        }
        .sheet(isPresented:$assistant,onDismiss:{Task {await session?.refresh()}}) {
            if let session {LaTeXOriginalAssistant(original:session.original)}
        }
        .onReceive(NotificationCenter.default.publisher(for:.floeLaTeXDocumentDidChange)) {value in
            if value.object as? UUID == projectID {Task {await session?.refresh()}}
        }
    }
}

private struct LaTeXOriginalAssistant:View {
    let original:LaTeXOriginal
    @EnvironmentObject private var environment:AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var conversationID:UUID?
    @State private var error:String?
    var body:some View {
        NavigationStack {
            Group {
                if let conversationID {ThreadDetailView(conversationID:conversationID,center:environment.conversationCenter,embedded:true,documentAssistant:true,ownsNavigationTitle:false)}
                else if let error {Text(error).foregroundStyle(.secondary).padding()}
                else {ProgressView()}
            }.navigationTitle(IDELanguageRunText.t("论文助手","Writing assistant"))
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button(IDELanguageRunText.t("完成","Done")) {dismiss()}}}
        }.task(id:original.id) {
            do {conversationID=try await environment.latexComposition.assistantForNativeOriginal(original)}catch {self.error=error.localizedDescription}
        }
    }
}

struct LaTeXOwnedProjectsSheet:View {
    let owner:LaTeXOwner
    @EnvironmentObject private var environment:AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var projects=[Project]()
    @State private var open:LaTeXOpenRequest?
    @State private var title=IDELanguageRunText.t("未命名论文","Untitled document")
    @State private var template=IDELanguageRunText.isChinese ? "chinese":"article"
    @State private var creating=false
    @State private var diagnostic:String?
    private struct Project:Identifiable {let id:UUID;let title:String}
    var body:some View {
        NavigationStack {
            Form {
                if !projects.isEmpty {Section(IDELanguageRunText.t("已有论文","Documents")) {
                    ForEach(projects) {value in Button(value.title) {open = .init(id:value.id)}}
                }}
                Section(IDELanguageRunText.t("新建论文","New document")) {
                    TextField(IDELanguageRunText.t("名称","Name"),text:$title)
                    Picker(IDELanguageRunText.t("模板","Template"),selection:$template) {
                        ForEach(LaTeXTemplates.all) {value in Text(IDELanguageRunText.isChinese ? value.chineseTitle:value.englishTitle).tag(value.id)}
                    }
                    Button(IDELanguageRunText.t("创建","Create")) {create()}.disabled(creating || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    if creating {ProgressView()}
                }
                if let diagnostic {Text(diagnostic).foregroundStyle(.secondary)}
            }.navigationTitle(IDELanguageRunText.t("LaTeX 论文","LaTeX documents"))
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button(IDELanguageRunText.t("完成","Done")) {dismiss()}.disabled(creating)}}
        }
        .task {await refresh()}
        .fullScreenCover(item:$open,onDismiss:{Task {await refresh()}}) {request in LaTeXOriginalEditor(projectID:request.id)}
        .interactiveDismissDisabled(creating)
    }
    @MainActor private func refresh() async {
        do {
            var result=[Project]()
            for value in try await environment.latexComposition.owned(by:owner) {
                if let manifest=try? await LaTeXProjectStore(root:value.root).manifest(),manifest.owner==owner {result.append(.init(id:value.id,title:manifest.title))}
            }
            projects=result
        } catch {diagnostic=error.localizedDescription}
    }
    @MainActor private func create() {
        guard !creating else {return};creating=true;diagnostic=nil
        Task { @MainActor in
            defer {creating=false}
            do {let value=try await environment.latexComposition.createNative(owner:owner,title:title.trimmingCharacters(in:.whitespacesAndNewlines),templateID:template);open = .init(id:value.id);await refresh()}
            catch {diagnostic=error.localizedDescription}
        }
    }
}
#endif
