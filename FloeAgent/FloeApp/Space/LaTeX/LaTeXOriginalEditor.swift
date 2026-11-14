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

#endif
