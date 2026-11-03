import SwiftUI

struct CADLoftSurfaceEditorSheets: ViewModifier {
    @Bindable var viewModel: EditorViewModel
    func body(content: Content) -> some View {
        content.sheet(item:Binding(get:{ viewModel.loftSurfaceEditor },set:{ viewModel.loftSurfaceEditor=$0 })) { destination in
            switch destination {
            case .draftLoft: LoftOptionsSheet(viewModel:viewModel,featureID:nil)
            case let .loft(id): LoftOptionsSheet(viewModel:viewModel,featureID:id)
            case let .surface(id): SurfaceOptionsSheet(viewModel:viewModel,featureID:id)
            }
        }
    }
}
