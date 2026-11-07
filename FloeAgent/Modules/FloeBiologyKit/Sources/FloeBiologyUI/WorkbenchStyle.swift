// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

enum BiologyStyle {
    static let spacing:CGFloat=20
    static let contentWidth:CGFloat=1120
    static let fieldRadius:CGFloat=10
    static let canvas=Color(uiColor:.secondarySystemGroupedBackground)
    static let background=Color(uiColor:.systemGroupedBackground)
    static let border=Color.secondary.opacity(0.7)
}
struct BiologySectionHeading:View {
    let title:String
    var detail:String=""
    var body:some View {
        HStack(alignment:.firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength:12)
            if !detail.isEmpty {Text(detail).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)}
        }
    }
}
struct BiologyViewFootnote:View {
    let text:String
    var symbol:String="info.circle"
    var body:some View {Label(text,systemImage:symbol).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)}
}
struct BiologyControlButtonStyle:ButtonStyle {
    var compact=false
    var expands=false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .frame(minWidth:44,maxWidth:expands ? .infinity:nil,minHeight:44)
            .padding(.horizontal,compact ? 0:12)
            .foregroundStyle(configuration.role == .destructive ? Color.red:Color.accentColor)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.14):BiologyStyle.canvas,in:RoundedRectangle(cornerRadius:10))
            .overlay{RoundedRectangle(cornerRadius:10).strokeBorder(BiologyStyle.border,lineWidth:1).allowsHitTesting(false)}
            .contentShape(RoundedRectangle(cornerRadius:10))
            .opacity(enabled ? 1:0.45)
    }
}
struct BiologyPrimaryButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon)
            .frame(minWidth:44,maxWidth:.infinity,minHeight:44).padding(.horizontal,12)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8:1),in:RoundedRectangle(cornerRadius:BiologyStyle.fieldRadius))
            .contentShape(RoundedRectangle(cornerRadius:BiologyStyle.fieldRadius)).opacity(enabled ? 1:0.45)
    }
}
/// A native selection menu with a full-width 44-point button label. Framing
/// only the Picker's outer view leaves its text-sized hit target ambiguous.
struct BiologyChoiceField<Selection:Hashable,Options:View>:View {
    let title:String
    @Binding var selection:Selection
    let value:String
    var identifier=""
    let options:()->Options
    init(title:String,selection:Binding<Selection>,value:String,identifier:String="",@ViewBuilder options:@escaping ()->Options){
        self.title=title;_selection=selection;self.value=value;self.identifier=identifier;self.options=options
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Menu {
                Picker(title,selection:$selection){options()}
            } label:{
                HStack(spacing:12){
                    Text(value.isEmpty ? biologyText("Choose","请选择"):value).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                    Spacer(minLength:4)
                    Image(systemName:"chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }.frame(maxWidth:.infinity,minHeight:44).padding(.horizontal,12)
                    .background(BiologyStyle.canvas,in:RoundedRectangle(cornerRadius:10))
                    .overlay{RoundedRectangle(cornerRadius:10).strokeBorder(BiologyStyle.border,lineWidth:1).allowsHitTesting(false)}
                    .contentShape(RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).disabled(value.isEmpty).accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier(identifier)
        }
    }
}
extension View {
    func biologyCanvas()->some View {background(BiologyStyle.canvas,in:RoundedRectangle(cornerRadius:14)).clipShape(RoundedRectangle(cornerRadius:14))}
    func biologyInputSurface()->some View {
        padding(8).background(BiologyStyle.canvas,in:RoundedRectangle(cornerRadius:10))
            .overlay{RoundedRectangle(cornerRadius:10).strokeBorder(BiologyStyle.border,lineWidth:1).allowsHitTesting(false)}
    }
    func biologyNamedInput(_ title:String)->some View {
        VStack(alignment:.leading,spacing:8){
            Text(title).font(.subheadline).foregroundStyle(.primary)
            self.textFieldStyle(.plain).padding(.horizontal,12).frame(minHeight:44)
                .background(BiologyStyle.canvas,in:RoundedRectangle(cornerRadius:BiologyStyle.fieldRadius))
                .overlay{RoundedRectangle(cornerRadius:BiologyStyle.fieldRadius).strokeBorder(BiologyStyle.border,lineWidth:1).allowsHitTesting(false)}
        }
    }
}
struct BiologyInspectorSection<Content:View>:View {
    let title:String
    let symbol:String
    @ViewBuilder var content:()->Content
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            Label(title,systemImage:symbol).font(.headline).foregroundStyle(.primary)
            content()
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct BiologyPanelHeader:View {
    let title:String
    let detail:String
    let symbol:String
    var body:some View {
        HStack(alignment:.top,spacing:12){
            Image(systemName:symbol).font(.title3).foregroundStyle(.tint).frame(width:32,height:32)
            VStack(alignment:.leading,spacing:4){
                Text(title).font(.headline)
                if !detail.isEmpty{Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            }
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
#endif
