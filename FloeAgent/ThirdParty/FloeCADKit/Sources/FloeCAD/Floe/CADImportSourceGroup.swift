// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Value snapshot of files EXPLICITLY selected by the user. The parser sees
/// only these bytes. A model reference never authorizes another filesystem read.
public nonisolated struct CADImportSourceGroup: Sendable {
    public let primary: CADImportSource
    public let resources: [String:Data]
}

public nonisolated extension CADImportSourceReader {
    static func readGroup(urls:[URL],lease:CADImportSourceLease = .system,
                          limits:MeshImportLimits = .standard) async -> Result<CADImportSourceGroup,CADImportSourceReadError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let formats:Set<String>=["stl","obj","glb","gltf","zip","blend","usd","usda","usdc","usdz"]
        let primary=urls.filter { formats.contains($0.pathExtension.lowercased()) }
        guard primary.count == 1,let model=primary.first,urls.count <= limits.maximumArchiveEntries else {
            return .failure(.unreadable(FloeCADStrings.text("cad.import.groupSelect", "Select one model and its referenced resource files, or one complete ZIP.")))
        }
        let worker=Task.detached(priority:.userInitiated) { () -> Result<CADImportSourceGroup,CADImportSourceReadError> in
            do {
                var main:CADImportSource?,resources:[String:Data]=[:],total=0
                let base=model.deletingLastPathComponent().standardizedFileURL.pathComponents
                for url in urls {
                    if Task.isCancelled { return .failure(.cancelled) }
                    let scoped=lease.begin(url)
                    defer { if scoped { lease.end(url) } }
                    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                    guard values.isRegularFile == true,let size=values.fileSize,size >= 0,
                          size <= limits.maximumExpandedBytes-total else {
                        return .failure(.unreadable(FloeCADStrings.text("cad.import.groupBudget", "The selected files exceed the import limit or include a folder.")))
                    }
                    let bytes=try Data(contentsOf:url)
                    if Task.isCancelled { return .failure(.cancelled) }
                    guard bytes.count <= limits.maximumExpandedBytes-total else { return .failure(.unreadable(FloeCADStrings.text("cad.import.groupBudget", "The selected files exceed the import limit or include a folder."))) }
                    total += bytes.count
                    if url == model {
                        main=CADImportSource(url:url,fileName:url.lastPathComponent,data:bytes,usedSecurityScope:scoped)
                    } else {
                        let path=url.standardizedFileURL.pathComponents
                        var common=0
                        while common < min(base.count,path.count),base[common] == path[common] { common += 1 }
                        let logical=(Array(repeating:"..",count:base.count-common)+Array(path.dropFirst(common))).joined(separator:"/")
                        guard let key=CADImportResources.name(logical),resources[key] == nil else {
                            return .failure(.unreadable(FloeCADStrings.text("cad.import.groupAmbiguous", "Some resource names conflict. Use a complete ZIP with unique paths.")))
                        }
                        resources[key]=bytes
                    }
                }
                guard let main else { return .failure(.unreadable(FloeCADStrings.text("cad.import.groupUnreadable", "The selected model could not be read."))) }
                return .success(CADImportSourceGroup(primary:main,resources:resources))
            } catch { return .failure(.unreadable(error.localizedDescription)) }
        }
        let result=await withTaskCancellationHandler { await worker.value }
        onCancel: { worker.cancel() }
        if Task.isCancelled { return .failure(.cancelled) }
        return result
    }
}
