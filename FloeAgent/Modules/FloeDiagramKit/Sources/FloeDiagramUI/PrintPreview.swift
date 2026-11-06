// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

struct DiagramPrintPreview: UIViewControllerRepresentable {
    let data: Data
    let title: String
    let finished: (Error?) -> Void
    func makeUIViewController(context: Context) -> DiagramPrintController { .init(data: data,title: title,finished: finished) }
    func updateUIViewController(_ controller: DiagramPrintController,context: Context) {}
    static func dismantleUIViewController(_ controller: DiagramPrintController,coordinator: ()) { controller.stop() }
}
@MainActor final class DiagramPrintController: UIViewController {
    let data: Data
    let jobTitle: String
    let finished: (Error?) -> Void
    private var attempted = false
    private var ownsPanel = false
    init(data: Data,title: String,finished: @escaping (Error?) -> Void) { self.data = data; jobTitle = title; self.finished = finished; super.init(nibName: nil,bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .systemBackground }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); guard !attempted else { return }; attempted = true
        let printer = UIPrintInteractionController.shared, info = UIPrintInfo(dictionary: nil)
        info.jobName = jobTitle; printer.printInfo = info; printer.printingItem = data
        let completion: UIPrintInteractionController.CompletionHandler = { [weak self] _,_,error in self?.ownsPanel = false; self?.finished(error) }
        if traitCollection.userInterfaceIdiom == .pad {
            ownsPanel = printer.present(from: CGRect(x: view.bounds.midX,y: 4,width: 1,height: 1),in: view,animated: true,completionHandler: completion)
        } else { ownsPanel = printer.present(animated: true,completionHandler: completion) }
        if !ownsPanel { finished(nil) }
    }
    func stop() { if ownsPanel { ownsPanel = false; UIPrintInteractionController.shared.dismiss(animated: false) } }
}
#endif
