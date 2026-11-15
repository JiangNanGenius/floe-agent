// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeInteriorCore
import FloeBuildingAssets

struct BuildingFurnitureImportSheet:View {
    let folder:URL
    let workspace:BuildingFurnitureWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var paths:[String]=[]
    @State private var chosen=""
    @State private var name=""
    @State private var unit:FurnitureLengthUnit?
    @State private var zUp=false
    @State private var declaresDimensions=false
    @State private var width=""
    @State private var depth=""
    @State private var height=""
    @State private var loading=true
    @State private var failure:String?
    private func copy(_ zh:String,_ en:String)->String {locale.language.languageCode?.identifier=="zh" ? zh:en}
    var body:some View {
        NavigationStack {
            Form {
                Section(copy("模型文件","Model file")) {
                    Text(folder.lastPathComponent).foregroundStyle(.secondary)
                    if loading {ProgressView()}
                    else if paths.isEmpty {Text(copy("所选文件夹中没有 OBJ 文件。","No OBJ files were found in this folder."))}
                    else {
                        Picker(copy("选择 OBJ","Choose an OBJ"),selection:$chosen) {
                            Text(copy("请选择","Choose a file")).tag("")
                            ForEach(paths,id:\.self){Text($0).tag($0)}
                        }
                        TextField(copy("家具名称","Furniture name"),text:$name)
                    }
                }
                Section(copy("单位与方向","Units and orientation")) {
                    Picker(copy("源模型单位","Source model unit"),selection:$unit) {
                        Text(copy("未知","Unknown")).tag(Optional<FurnitureLengthUnit>.none)
                        ForEach(FurnitureLengthUnit.allCases,id:\.self){Text($0.rawValue).tag(Optional($0))}
                    }
                    Picker(copy("源模型竖直方向","Source up axis"),selection:$zUp) {
                        Text("Y").tag(false);Text("Z").tag(true)
                    }
                    Toggle(copy("提供标称尺寸（毫米）","Provide catalog dimensions (mm)"),isOn:$declaresDimensions)
                    if declaresDimensions {
                        TextField(copy("宽度","Width"),text:$width).keyboardType(.decimalPad)
                        TextField(copy("深度","Depth"),text:$depth).keyboardType(.decimalPad)
                        TextField(copy("高度","Height"),text:$height).keyboardType(.decimalPad)
                    }
                }
                if let failure {Section {Text(failure).foregroundStyle(.secondary).textSelection(.enabled)}}
            }
            .navigationTitle(copy("导入家具","Import furniture")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(copy("取消","Cancel")){dismiss()}}
                ToolbarItem(placement:.confirmationAction){Button(copy("导入","Import")){importChosen()}
                    .disabled(loading || chosen.isEmpty || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || workspace.busy)}
            }
        }
        .task(id:folder) {
            do {
                let selected=folder
                let values=try await Task.detached{try Self.modelPaths(in:selected)}.value
                guard !Task.isCancelled else{return}
                paths=values
                if values.count==1 {chosen=values[0]}
                name=folder.lastPathComponent;loading=false
            } catch {if !Task.isCancelled {loading=false;failure=error.localizedDescription}}
        }
    }
    private func importChosen() {
        let dimensions:FurnitureDeclaredDimensions?
        if declaresDimensions {
            guard let w=Double(width),let d=Double(depth),let h=Double(height),
                  [w,d,h].allSatisfy({$0.isFinite && $0>0 && $0<=1_000_000}) else {
                failure=copy("请填写有效的宽、深、高。","Enter a valid width, depth and height.");return
            }
            dimensions = .init(width:w,depth:d,height:h,unit:.millimetre)
        } else {dimensions=nil}
        guard paths.contains(chosen) else{return}
        let orientation:FurnitureSourceOrientation=zUp ? .rotation3x3([1,0,0,0,0,-1,0,1,0]):.cadYUp
        workspace.importOBJ(folder:folder,relativePath:chosen,name:name,unit:unit,
            orientation:orientation,declaredDimensions:dimensions)
        dismiss()
    }
    nonisolated private static func modelPaths(in root:URL) throws -> [String] {
        let root=root.standardizedFileURL
        let keys:Set<URLResourceKey>=[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey]
        guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),
            options:[.skipsHiddenFiles]) else {return []}
        var result:[String]=[],seen=0
        while let url=enumerator.nextObject() as? URL {
            try Task.checkCancellation();seen+=1
            guard seen<=4096 else {throw BuildingFurnitureInputError.packageFileBudget}
            let info=try url.resourceValues(forKeys:keys)
            if info.isSymbolicLink==true {enumerator.skipDescendants();continue}
            if info.isRegularFile==true,url.pathExtension.lowercased()=="obj" {
                let path=Array(url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count)).joined(separator:"/")
                if !path.isEmpty {result.append(path)}
            }
        }
        return result.sorted()
    }
}
#endif
