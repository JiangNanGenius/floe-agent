// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI

public enum BuildingEditorLaunch: Equatable,Sendable {
    case create(name:String)
    case open
}

/// Standalone entry for qualification and later App inclusion. Directory
/// resolution/access belongs to the existing host, never imported files or AI.
public struct BuildingEditorProjectHost:View {
    private let directory:URL
    private let library:URL
    private let launch:BuildingEditorLaunch
    private let actions:BuildingEditorHostActions
    /// A saved native package this new project starts from. Only read; the
    /// project copy is verified before any generation is published.
    private let importingNativeDocument:URL?
    @Environment(\.locale) private var locale
    @State private var session:BuildingEditorProjectSession?
    @State private var recovery:BuildingEditorRecoveryOptions?
    @State private var loading=false
    @State private var started=false
    @State private var failure:String?
    @State private var ownedTask:Task<Void,Never>?
    @State private var closed=false

    public init(projectDirectory:URL,assetLibraryDirectory:URL,launch:BuildingEditorLaunch = .open,
                hostActions:BuildingEditorHostActions = .init(),
                importingNativeDocument:URL? = nil) {
        directory=projectDirectory;library=assetLibraryDirectory;self.launch=launch;actions=hostActions
        self.importingNativeDocument=importingNativeDocument
    }
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    public var body:some View {
        Group {
            if closed {
                ContentUnavailableView {
                    Label(copy("工程已关闭","Project closed"),systemImage:"building.2")
                } description:{if let failure{Text(failure)}}
                actions:{Button(copy("重新打开工程","Reopen project")){closed=false;inspectForRecovery()}.accessibilityIdentifier("building.closed.reopen")}
            }
            else if let session {BuildingEditorView(session:session,hostActions:editorActions)}
            else if loading {
                VStack(spacing:12) {
                    ProgressView(copy("正在打开工程…","Opening project…"))
                    Button(copy("取消","Cancel"),role:.cancel) {cancelLoading()}
                        .accessibilityIdentifier("building.loading.cancel")
                }
            }
            else if let recovery {
                NavigationStack {
                    List {
                        Section {
                            Text(copy("发现未完成的本地工作。选择恢复其中一份，或打开已保存版本。","Unfinished local work is available. Restore a copy, or open the saved version."))
                                .foregroundStyle(.secondary)
                            if recovery.hasPublishedProject {
                                Button(copy("打开已保存版本","Open saved version")){open(.published)}
                                    .accessibilityIdentifier("building.recovery.published")
                            }
                        }
                        Section(copy("本地工作副本","Local working copies")) {
                            ForEach(recovery.workingCopies) { item in
                                Button {open(.workingCopy(item.id))} label:{
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(item.updatedAt,format:.dateTime.year().month().day().hour().minute())
                                        if item.hasPendingSave {Text(copy("保存尚未完成","Save unfinished")).font(.caption)}
                                        if !item.isBasedOnCurrentGeneration {
                                            Text(copy("基于较早版本；恢复后需另存或解决版本冲突。","Based on an earlier version; save a copy or resolve the conflict after restoring."))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if let failure {Section {Text(failure).font(.caption).textSelection(.enabled)}}
                    }
                    .navigationTitle(copy("恢复工程","Recover project"))
                    .toolbar {ToolbarItem(placement:.cancellationAction){Button(copy("关闭","Close")){actions.didClose()}}}
                }
            } else {
                ContentUnavailableView {
                    Label(copy("工程未能建立或打开","The project could not be created or opened"),systemImage:"exclamationmark.folder")
                } description:{Text(failure ?? copy("请检查工程文件后重试。","Check the project files and retry."))}
                actions:{
                    Button(copy("检查恢复副本","Check recovery copies")){inspectForRecovery()}
                    Button(copy("关闭工程面板","Close project panel"),role:.cancel){actions.didClose()}
                        .accessibilityIdentifier("building.failed.close")
                }
            }
        }
        .task {
            guard !started else{return};started=true
            switch launch {
            case .open:inspectForRecovery()
            case .create(let name):run {
                let created:BuildingEditorProjectSession
                if let importingNativeDocument {
                    created=try await BuildingEditorProjectSession.create(at:directory,name:name,
                        assetLibraryDirectory:library,importingNativeDocument:importingNativeDocument)
                } else {
                    created=try await BuildingEditorProjectSession.create(at:directory,name:name,
                        assetLibraryDirectory:library)
                }
                guard !Task.isCancelled else {try? await created.close(discardWorkingCopy:false);return}
                session=created
            }
            }
        }
    }
    private func run(_ work:@escaping @MainActor () async throws -> Void) {
        guard !loading else{return};loading=true;failure=nil
        ownedTask=Task {@MainActor in
            defer{loading=false;ownedTask=nil}
            do {try await work()}catch{if !Task.isCancelled {failure=error.localizedDescription}}
        }
    }
    /// Leaving an opening/creating mount must not leave the panel with no way
    /// out. The in-flight create closes a session it finished after cancel.
    private func cancelLoading() {
        ownedTask?.cancel();ownedTask=nil;loading=false;actions.didClose()
    }
    private var editorActions:BuildingEditorHostActions {
        var configured=actions
        configured.didClose={
            failure=session?.publicationWarning
            closed=true;session=nil
            actions.didClose()
        }
        return configured
    }
    private func inspectForRecovery() {
        run {
            let options=try await BuildingEditorProjectSession.recoveryOptions(at:directory)
            if options.workingCopies.isEmpty {
                session=try await BuildingEditorProjectSession.open(at:directory,assetLibraryDirectory:library)
            } else {recovery=options}
        }
    }
    private func open(_ choice:BuildingEditorOpenChoice) {
        run {session=try await BuildingEditorProjectSession.open(at:directory,assetLibraryDirectory:library,choice:choice)}
    }
}
#endif
