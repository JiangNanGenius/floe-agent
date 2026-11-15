// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Observation
import FloeBuildingWorkspace

@MainActor @Observable
final class BuildingNumberInputs {
    var locale=Locale.current
    @MainActor @Observable final class Entry {
        var text:String
        var committed:String
        var error:String?
        var allowsEmpty=false
        var owner:UUID?
        @ObservationIgnored var read:(()->Double?)?
        @ObservationIgnored var write:((Double?)->Void)?
        init(value:Double?){
            let initialText=BuildingNumberInputs.format(value)
            text=initialText;committed=initialText
        }
        var pending:Bool{text != committed}
    }
    var entries:[String:Entry]=[:]
    static func format(_ value:Double?)->String{value.map{String(format:"%.10g",locale:Locale(identifier:"en_US_POSIX"),$0)} ?? ""}
    var hasPending:Bool{entries.values.contains{$0.pending}}
    func hasPending(prefix:String)->Bool{entries.contains{$0.key.hasPrefix(prefix+".") && $0.value.pending}}
    func register(_ id:String,owner:UUID,value:Double?,allowsEmpty:Bool,read:@escaping ()->Double?,write:@escaping (Double?)->Void){
        let e=entries[id] ?? Entry(value:value);e.read=read;e.write=write;e.owner=owner;e.allowsEmpty=allowsEmpty;entries[id]=e
        if !e.pending{e.text=Self.format(value);e.committed=e.text}
    }
    func unregister(_ id:String,owner:UUID){guard entries[id]?.owner==owner else{return};entries[id]?.read=nil;entries[id]?.write=nil;entries[id]?.owner=nil}
    @discardableResult func commit(_ id:String)->Bool{
        guard let e=entries[id],e.pending else{return true}
        do {
            let value:Double?
            if e.allowsEmpty,e.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{value=nil}
            else{value=try BuildingNumericInput.parse(e.text,decimalSeparator:locale.decimalSeparator ?? ".")}
            guard let write=e.write else{return false}
            e.text=Self.format(value);e.committed=e.text;e.error=nil;write(value);return true
        } catch {e.error=BuildingCopy.text("请输入完整数值，不含单位或千位分隔符。","Enter a complete number without units or grouping separators.",locale:locale);return false}
    }
    func commit(prefix:String)->Bool{var valid=true;for id in entries.keys where id.hasPrefix(prefix+"."){if !commit(id){valid=false}};return valid}
    func commitAll()->Bool{var valid=true;for id in entries.keys{if !commit(id){valid=false}};return valid}
    func discardPending(prefix:String)->Bool{
        var discarded=false
        for (id,e) in entries where id.hasPrefix(prefix+".") && e.pending {
            e.text=e.read.map{Self.format($0())} ?? e.committed;e.committed=e.text;e.error=nil;discarded=true
        }
        return discarded
    }
    func clear(){entries=[:]}
}
struct BuildingNumberField:View {
    let title:String
    @Binding var value:Double
    let inputs:BuildingNumberInputs
    let id:String
    var body:some View{BuildingNumericField(title:title,value:Binding(get:{value},set:{if let number=$0{value=number}}),allowsEmpty:false,inputs:inputs,id:id)}
}
struct BuildingOptionalNumberField:View {
    let title:String
    @Binding var value:Double?
    let inputs:BuildingNumberInputs
    let id:String
    var body:some View{BuildingNumericField(title:title,value:$value,allowsEmpty:true,inputs:inputs,id:id)}
}
private struct BuildingNumericField:View {
    let title:String
    @Binding var value:Double?
    let allowsEmpty:Bool
    let inputs:BuildingNumberInputs
    let id:String
    @FocusState private var focused:Bool
    @State private var owner=UUID()
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title,text:Binding(get:{inputs.entries[id]?.text ?? BuildingNumberInputs.format(value)},set:{text in
                if inputs.entries[id]==nil{register()};inputs.entries[id]?.text=text;inputs.entries[id]?.error=nil
            }))
            .textFieldStyle(.roundedBorder).frame(minHeight:44).focused($focused).accessibilityIdentifier("building.number."+id)
            .onSubmit{_=inputs.commit(id)}
            if let error=inputs.entries[id]?.error{Text(error).font(.caption).foregroundStyle(.red)}
        }.frame(minWidth:100,idealWidth:150,maxWidth:220)
        .onAppear{register()}
        .onChange(of:focused){_,active in if !active{_=inputs.commit(id)}}
        .onChange(of:value){_,new in if inputs.entries[id]?.pending != true{inputs.entries[id]?.text=BuildingNumberInputs.format(new);inputs.entries[id]?.committed=BuildingNumberInputs.format(new)}}
        .onDisappear{if inputs.entries[id]?.owner==owner{_=inputs.commit(id)};inputs.unregister(id,owner:owner)}
    }
    private func register(){inputs.register(id,owner:owner,value:value,allowsEmpty:allowsEmpty,read:{value},write:{value=$0})}
}
