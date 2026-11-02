//
//  SelectionInfoBar.swift
//  openshape3d
//
//  Bottom selection info strip (spec §16.3): volume + bounds for a body,
//  area + perimeter for a face, length/radius for sketch entities. Read-only —
//  values come straight from EditorViewModel.selectionMeasurements.
//

import SwiftUI

struct SelectionInfoBar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        let rows = viewModel.selectionMeasurements
        if !rows.isEmpty {
            strip(rows)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .cadFloatingSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("SelectionInfoBar")
        }
    }

    @ViewBuilder
    private func strip(_ rows: [EditorViewModel.MeasurementRow]) -> some View {
        ViewThatFits(in: .horizontal) {
            measurements(rows).fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    ViewThatFits(in: .horizontal) {
                        measurement(row).fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            label(row)
                            value(row)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func measurements(_ rows: [EditorViewModel.MeasurementRow]) -> some View {
        HStack(spacing: 20) {
            ForEach(rows) { row in
                measurement(row)
            }
        }
    }

    private func measurement(_ row: EditorViewModel.MeasurementRow) -> some View {
        HStack(spacing: 6) { label(row); value(row) }.lineLimit(1)
    }

    private func label(_ row: EditorViewModel.MeasurementRow) -> some View {
        Text(row.label).font(.caption).foregroundStyle(.barLabel)
    }

    private func value(_ row: EditorViewModel.MeasurementRow) -> some View {
        Text(row.value)
            .font(.callout.weight(.medium)).monospacedDigit()
            .accessibilityIdentifier("SelectionMeasurement-\(row.label)")
    }
}
