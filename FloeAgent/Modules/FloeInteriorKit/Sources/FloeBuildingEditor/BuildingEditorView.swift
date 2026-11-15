// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import FloeCAD
import FloeBuildingUI
import FloeBuildingAssets

/// The App owns assistant conversations, departure policy, protected previews
/// and registration in Space. A standalone host may omit the optional adapters.
@MainActor
public struct BuildingEditorHostActions {
    public var requestAssistant: ((BuildingEditorToolContext) -> Void)?
    public var beforeDeparture: (Bool) async throws -> Bool
    public var departureEnded: () -> Void
    public var didClose: () -> Void
    public var previewFile: ((URL) -> Void)?
    public var registerIndependentCAD: (@MainActor (BuildingIndependentCADHandoff) async throws -> Void)?

    public init(requestAssistant:((BuildingEditorToolContext)->Void)?=nil,
                beforeDeparture:@escaping (Bool) async throws -> Bool={_ in true},
                departureEnded:@escaping ()->Void={},didClose:@escaping ()->Void={},
                previewFile:((URL)->Void)?=nil,
                registerIndependentCAD:(@MainActor (BuildingIndependentCADHandoff) async throws->Void)?=nil) {
        self.requestAssistant=requestAssistant;self.beforeDeparture=beforeDeparture
        self.departureEnded=departureEnded;self.didClose=didClose;self.previewFile=previewFile
        self.registerIndependentCAD=registerIndependentCAD
    }
}

/// One feature surface with one navigation owner and one project Save button.
/// Present directly inside the App's existing editor destination; do not add
/// another NavigationStack, CAD host chrome or assistant conversation.
public struct BuildingEditorView: View {
    @Bindable private var project: BuildingEditorProjectSession
    private let host: BuildingEditorHostActions
    @Environment(\.locale) private var locale
    @State private var choosingFurniture=false
    @State private var folderLease:BuildingFolderAccess?
    @State private var importFailure:String?

    public init(session:BuildingEditorProjectSession,hostActions:BuildingEditorHostActions = .init()) {
        project=session;host=hostActions
    }
    public var body: some View {
        Group {
            if project.closed {
                VStack {
                    ContentUnavailableView(copy("工程已关闭","Project closed"),systemImage:"building.2")
                    if let details=project.publicationWarning {
                        DisclosureGroup(copy("工作副本保留信息","Retained working copy details")){Text(details).font(.caption).textSelection(.enabled)}.padding()
                    }
                }
            } else {
                BuildingWorkbenchView(workspace:project.workspace,actions:actions) {
                    BuildingNativeModelPanel(project:project)
                } furniture: {
                    if let furniture=project.furniture {BuildingFurniturePanel(workspace:furniture)}
                } delivery: {
                    BuildingDeliveryPanel(project:project,previewFile:host.previewFile,
                                          registerIndependentCAD:host.registerIndependentCAD)
                }
                .id(project.mountID)
            }
        }
        .fileImporter(isPresented:$choosingFurniture,allowedContentTypes:[.folder]) { result in
            do {
                let url=try result.get()
                releaseFolder()
                folderLease=BuildingFolderAccess(url)
            } catch {if (error as NSError).code != NSUserCancelledError {importFailure=error.localizedDescription}}
        }
        .sheet(isPresented:Binding(get:{folderLease != nil},set:{if !$0{releaseFolder()}}),onDismiss:releaseFolder) {
            if let lease=folderLease,let furniture=project.furniture {
                BuildingFurnitureImportSheet(folder:lease.url,workspace:furniture)
            }
        }
        .onChange(of:project.closed){_,closed in if closed{releaseFolder()}}
        .onChange(of:project.mountID){_,_ in releaseFolder()}
        .alert(copy("导入未完成","Import incomplete"),isPresented:Binding(get:{importFailure != nil},set:{if !$0{importFailure=nil}})) {
            Button(copy("好","OK"),role:.cancel){importFailure=nil}
        } message:{Text(importFailure ?? "")}
    }
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    private func releaseFolder() {
        folderLease?.release();folderLease=nil
    }
    private var actions:BuildingWorkbenchProjectActions {
        let mount=project.mountID
        return .init(hasUnpublishedChanges:{project.mountID==mount && project.hasUnpublishedChanges},
            checkpoint:{request in
                try requireMount(mount)
                do {try await project.checkpoint(request)}catch{throw projectError(error)}
            },applyCabinet:{try requireMount(mount);try await project.applyCabinet($0)},
            reopen:{try requireMount(mount);try await project.reopenSavedMount();return .replacedWorkspace},
            close:{try requireMount(mount);try await project.close();host.didClose()},
            beforeDeparture:{closing in
                try requireMount(mount)
                guard try await host.beforeDeparture(closing) else{return false}
                try await project.settleOwnedWorkForDeparture();return true
            },departureEnded:host.departureEnded,
            recordsChanged:{if project.mountID==mount {project.noteRecordsRevision(projectID:$0,revision:$1)}},
            roomSelectionChanged:{if !project.closed,project.mountID==mount {project.selectFurnitureRoom($0)}},
            metadataRevision:{!project.closed && project.mountID==mount ? project.recordsRevision:-1},
            requestAssistant:host.requestAssistant.map { action in {if !project.closed,project.mountID==mount{action(project.assistantContext())}} },
            requestFurnitureImport:{if !project.closed,project.mountID==mount{choosingFurniture=true}},
            projectOperationBusy:{project.mountID==mount && (project.busy || project.furniture?.busy==true || project.deliveries?.busy==true)},
            cancelProjectOperation:{if project.mountID==mount{project.cancelOwnedSave();project.furniture?.cancel();project.deliveries?.cancel()}})
    }
    private func requireMount(_ mount:UUID) throws {
        guard !project.closed,project.mountID==mount else{throw BuildingEditorProjectError.closed}
    }
    private func projectError(_ error:Error)->Error {
        guard let projectError=error as? BuildingEditorProjectError else{return error}
        let message:String
        switch projectError {
        case .roomNameConflict(_):message=copy("房间名称有两种修改。请在“关联房间资料”中选择采用哪一边。","Both room names changed. Choose a name in Link room records.")
        case .missingRoomReference(_):message=copy("有关联的房间已不存在。请在“关联房间资料”中重新关联或解除关联。","A linked room is missing. Relink or unlink it in Link room records.")
        default:return error
        }
        return NSError(domain:"FloeBuildingEditor",code:1,userInfo:[NSLocalizedDescriptionKey:message,NSUnderlyingErrorKey:error])
    }
}

private final class BuildingFolderAccess:@unchecked Sendable {
    let url:URL
    private let lock=NSLock()
    private var active:Bool
    init(_ url:URL){self.url=url;active=url.startAccessingSecurityScopedResource()}
    func release() {
        lock.lock();let shouldStop=active;active=false;lock.unlock()
        if shouldStop{url.stopAccessingSecurityScopedResource()}
    }
    deinit{release()}
}
#endif
