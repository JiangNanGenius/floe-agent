// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeBiologyEngine

@MainActor struct BiologyNativeExportPicker:UIViewControllerRepresentable {
    let export:BiologyNativeFileExport
    let onFinish:@MainActor ()->Void
    func makeCoordinator()->Coordinator {Coordinator(onFinish:onFinish)}
    func makeUIViewController(context:Context)->UIDocumentPickerViewController {
        let controller=UIDocumentPickerViewController(forExporting:[export.url],asCopy:true)
        controller.delegate=context.coordinator;return controller
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    static func dismantleUIViewController(_ controller:UIDocumentPickerViewController,coordinator:Coordinator){coordinator.finish()}
    @MainActor final class Coordinator:NSObject,UIDocumentPickerDelegate {
        private var onFinish:(@MainActor ()->Void)?
        init(onFinish:@escaping @MainActor ()->Void){self.onFinish=onFinish}
        func finish(){let callback=onFinish;onFinish=nil;callback?()}
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController){finish()}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]){finish()}
    }
}
#endif
