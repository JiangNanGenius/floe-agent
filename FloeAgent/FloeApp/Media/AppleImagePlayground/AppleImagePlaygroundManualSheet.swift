// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(ImagePlayground)
import SwiftUI
import UIKit
import ImagePlayground

/// A deliberate native Files action has a view-owned picker, while model
/// calls keep their existing run-owned service and foreground checks. Both
/// use the same controller configuration and validated output representation.
@MainActor struct AppleImagePlaygroundManualSheet: UIViewControllerRepresentable {
    let input: AppleImagePlaygroundInput
    let completion: @MainActor (Result<AppleImagePlaygroundImage, AppleImagePlaygroundFailure>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIViewController {
        AppleImagePlaygroundControllerFactory.make(input: input, delegate: context.coordinator)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, ImagePlaygroundViewController.Delegate {
        private let completion: @MainActor (Result<AppleImagePlaygroundImage, AppleImagePlaygroundFailure>) -> Void
        private var finished = false
        init(completion: @escaping @MainActor (Result<AppleImagePlaygroundImage, AppleImagePlaygroundFailure>) -> Void) {
            self.completion = completion
        }
        func imagePlaygroundViewController(_ controller: ImagePlaygroundViewController, didCreateImageAt imageURL: URL) {
            guard !finished else { return }; finished = true
            // Consume the temporary system file before dismissing its picker.
            do { completion(.success(try AppleImagePlaygroundImage(contentsOf: imageURL))) }
            catch { completion(.failure(.invalidImage)) }
        }
        func imagePlaygroundViewControllerDidCancel(_ controller: ImagePlaygroundViewController) {
            guard !finished else { return }; finished = true
            completion(.failure(.cancelled))
        }
    }
}
#endif
