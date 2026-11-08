// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct EDCrossProbePicker: View {
    let request: EDACrossProbeRequest
    let busy: Bool
    let select: (EDACrossProbeTarget) -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            List(request.resolution.targets) { target in
                Button { select(target) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.contextName).foregroundStyle(.primary)
                        Text(target.reference + (target.unit.map { " · " + edText("单元 ", "Unit ") + String($0) } ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        // Repeated instance names/units remain distinguishable.
                        Text(String(target.objectID.uuidString.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.disabled(busy)
            }
            .navigationTitle(edText("选择对应实例", "Choose corresponding instance"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(edText("取消", "Cancel"), action: cancel).disabled(busy)
            } }
        }.interactiveDismissDisabled(busy)
    }
}
