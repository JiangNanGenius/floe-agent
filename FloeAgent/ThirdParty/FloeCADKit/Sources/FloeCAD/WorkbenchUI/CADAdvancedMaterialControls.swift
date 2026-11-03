// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor struct CADAdvancedMaterialControls:View {
    @Bindable var model:CADMaterialDraftModel
    var body:some View {
        Section {
            parameter("cad.advanced.coat","Clearcoat",\.clearcoat,"CADMaterialClearcoat")
            parameter("cad.advanced.coatRough","Coat roughness",\.coatRoughness,"CADMaterialCoatRoughness")
            parameter("cad.advanced.anisotropy","Anisotropy",\.anisotropyLevel,"CADMaterialAnisotropy")
            parameter("cad.advanced.angle","Direction",\.anisotropyAngle,"CADMaterialAnisotropyAngle")
            parameter("cad.advanced.specular","Specular",\.specular,"CADMaterialSpecular")
            ColorPicker(FloeCADStrings.text("cad.advanced.sheen","Sheen color"),selection:Binding(get:{
                let v=model.draft.advanced?.sheen ?? .zero;return Color(red:v.x,green:v.y,blue:v.z)
            },set:{ color in
                var r:CGFloat=0;var g:CGFloat=0;var b:CGFloat=0;var a:CGFloat=0
                if UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) { model.update { var value=$0.advanced ?? CADAdvancedMaterial();value.sheen=SIMD3(Double(r),Double(g),Double(b));$0.advanced=value } }
            }),supportsOpacity:false).accessibilityIdentifier("CADMaterialSheen")
            Text(FloeCADStrings.text("cad.advanced.preview","Advanced shading appears in Present. Anisotropy needs UVs or a projected mapping.")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(FloeCADStrings.text("cad.ui.common.details","Details")) {
                Text(FloeCADStrings.text("cad.advanced.exchange","GLB uses fixed sheen roughness 1 and records native-angle conversion loss. Refraction and displacement are unavailable.")).font(.caption).foregroundStyle(.secondary)
            }
            Button(FloeCADStrings.text("cad.advanced.reset","Remove advanced settings")) { model.update { $0.advanced=nil } }
        } header:{ Text(FloeCADStrings.text("cad.advanced.title","Advanced surface")) }
    }
    private func parameter(_ key:String,_ fallback:String,_ path:WritableKeyPath<CADAdvancedMaterial,Double>,_ id:String) -> some View {
        VStack(alignment:.leading) {
            Text(FloeCADStrings.text(key,fallback))
            Slider(value:Binding(get:{ (model.draft.advanced ?? CADAdvancedMaterial())[keyPath:path] },set:{ value in model.update { var advanced=$0.advanced ?? CADAdvancedMaterial();advanced[keyPath:path]=value;$0.advanced=advanced } }),in:0...1).accessibilityIdentifier(id)
        }.frame(minHeight:44)
    }
}
#endif
