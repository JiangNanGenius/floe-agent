#if canImport(UIKit) && canImport(ImagePlayground)
import SwiftUI
import UIKit
import ImagePlayground

/// Install once on a stable App scene. The supplied conversation identities
/// come from native navigation/assistant ownership, never tool arguments.
extension View {
    func appleImagePlaygroundHost(
        service: AppleImagePlaygroundService,
        sceneID: String,
        visibleConversationIDs: Set<UUID>,
        active: Bool
    ) -> some View {
        modifier(AppleImagePlaygroundHost(
            service: service, sceneID: sceneID,
            visibleConversationIDs: visibleConversationIDs, active: active))
    }
}

@MainActor private final class AppleImagePlaygroundPresentationIdentity {
    var id: UUID?
}

/// Queries this host's own UIKit ancestry at request time. An active SwiftUI
/// scene may still contain a chat underneath Settings, voice, a design cover
/// or another editor; that covered chat must not claim the presentation slot.
@MainActor private final class AppleImagePlaygroundVisibility {
    weak var controller: UIViewController?
    var canPresent: Bool {
        guard let controller, let window = controller.viewIfLoaded?.window, !window.isHidden else { return false }
        var ancestor: UIViewController? = controller
        while let value = ancestor {
            if let presented = value.presentedViewController, !presented.isBeingDismissed { return false }
            ancestor = value.parent
        }
        return !controller.isBeingDismissed && !controller.isMovingFromParent
    }
}

private struct AppleImagePlaygroundVisibilityProbe: UIViewControllerRepresentable {
    let visibility: AppleImagePlaygroundVisibility
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view = UIView(frame: .zero)
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        visibility.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private struct AppleImagePlaygroundHost: ViewModifier {
    @ObservedObject var service: AppleImagePlaygroundService
    let sceneID: String
    let visibleConversationIDs: Set<UUID>
    let active: Bool
    @State private var presented = AppleImagePlaygroundPresentationIdentity()
    @State private var visibility = AppleImagePlaygroundVisibility()

    private var request: AppleImagePlaygroundService.Presentation? {
        guard let request = service.presentation, request.sceneID == sceneID else { return nil }
        return request
    }

    func body(content: Content) -> some View {
        content
            .background { AppleImagePlaygroundVisibilityProbe(visibility: visibility).frame(width: 0, height: 0).allowsHitTesting(false) }
            .onAppear { update() }
            .onChange(of: visibleConversationIDs) { _, _ in update() }
            .onChange(of: active) { _, _ in update() }
            .onDisappear { service.removeHost(sceneID: sceneID) }
            .sheet(item: Binding(get: { request }, set: { value in
                if value == nil, let id = presented.id ?? request?.id { service.fail(id: id, error: .cancelled) }
            }), onDismiss: {
                if let id = presented.id { service.didDismiss(id: id) }
                presented.id = nil
            }) { request in
                AppleImagePlaygroundNativeSheet(request: request, service: service, presented: presented)
                    .accessibilityIdentifier("system.imagePlayground.sheet")
            }
    }

    private func update() {
        service.updateHost(sceneID: sceneID,
            visibleConversationIDs: visibleConversationIDs, active: active,
            canPresent: { [weak visibility] in visibility?.canPresent == true })
    }
}

private struct AppleImagePlaygroundNativeSheet: UIViewControllerRepresentable {
    let request: AppleImagePlaygroundService.Presentation
    let service: AppleImagePlaygroundService
    let presented: AppleImagePlaygroundPresentationIdentity

    func makeCoordinator() -> Coordinator { Coordinator(id: request.id, service: service) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard service.beginPresentation(id: request.id) else { return UIViewController() }
        presented.id = request.id
        let controller = ImagePlaygroundViewController()
        controller.delegate = context.coordinator
        controller.concepts = [.text(request.input.prompt)]
        if let image = request.input.source {
            controller.sourceImage = UIImage(data: image.data)
        }
        // External providers are an explicit separate route. Emoji returns a
        // glyph instead of this tool's image-file contract, so omit it too.
        var styles: [ImagePlaygroundStyle] = [.animation, .illustration, .sketch]
        if #available(iOS 27.0, *) { styles.insert(.any, at: 0) }
        controller.allowedGenerationStyles = styles
        switch request.input.style {
        case .automatic:
            if #available(iOS 27.0, *) { controller.selectedGenerationStyle = .any }
            else { controller.selectedGenerationStyle = .illustration }
        case .animation: controller.selectedGenerationStyle = .animation
        case .illustration: controller.selectedGenerationStyle = .illustration
        case .sketch: controller.selectedGenerationStyle = .sketch
        }
        if #available(iOS 27.0, *) {
            var options = ImagePlaygroundOptions()
            options.creationStrategy = request.input.intent == .edit ? .editExisting : .generateNew
            if let width = request.input.width, let height = request.input.height {
                options.sizeSpecification = .closest(to: CGSize(width: width, height: height))
            }
            controller.options = options
        }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // A request is immutable while its system session is open.
    }

    @MainActor final class Coordinator: NSObject, ImagePlaygroundViewController.Delegate {
        let id: UUID
        weak var service: AppleImagePlaygroundService?
        init(id: UUID, service: AppleImagePlaygroundService) { self.id = id; self.service = service }

        func imagePlaygroundViewController(_ controller: ImagePlaygroundViewController,
                                          didCreateImageAt imageURL: URL) {
            service?.receive(id: id, imageURL: imageURL)
        }

        func imagePlaygroundViewControllerDidCancel(_ controller: ImagePlaygroundViewController) {
            service?.fail(id: id, error: .cancelled)
        }
    }
}
#endif
