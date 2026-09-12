//
//  RangeSliderView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

enum RangeSliderMaskedRegionStyle {

    // MARK: - Public Properties

    static let cornerRadius: CGFloat = 8

}

struct RangedSliderView: View {

    private enum SliderFeedbackEvent: Int {
        case dragStarted = 1
        case dragCommitted = 2
    }

    // MARK: - States

    @State private var leftThumbDragStartX: CGFloat?
    @State private var rightThumbDragStartX: CGFloat?
    @State private var leftThumbDragStartRange: ClosedRange<Double>?
    @State private var rightThumbDragStartRange: ClosedRange<Double>?
    @State private var sliderFeedbackEvent: SliderFeedbackEvent?
    @State private var sliderFeedbackTrigger = 0

    // MARK: - Private Properties

    private let currentValue: Binding<ClosedRange<Double>>?
    private let sliderBounds: ClosedRange<Double>
    private let step: Double
    private let minimumDistance: Double
    private let maximumDistance: Double?
    private let onStartChange: (() -> Void)?
    private let onEndChange: (() -> Void)?

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            sliderView(sliderSize: geometry.size)
        }
        .sensoryFeedback(trigger: sliderFeedbackTrigger) {
            resolvedSliderFeedback
        }
    }

    // MARK: - Private Properties

    private let handleWidth: CGFloat = 16
    private let minimumHandleHitSize = CGSize(width: 44, height: 44)
    private let minimumVisualGap: CGFloat = 8

    private var resolvedStep: Double {
        guard step.isFinite, step > 0 else { return 1 }
        return step
    }

    private var sliderRange: Double {
        max(sliderBounds.upperBound - sliderBounds.lowerBound, 0)
    }

    private var resolvedSliderFeedback: SensoryFeedback? {
        switch sliderFeedbackEvent {
        case .dragStarted:
            .selection
        case .dragCommitted:
            .success
        case nil:
            nil
        }
    }

    // MARK: - Initializer

    init(
        _ value: Binding<ClosedRange<Double>>?,
        bounds: ClosedRange<Double>,
        step: Double = 1,
        minimumDistance: Double = 0,
        maximumDistance: Double? = nil,
        onStartChange: (() -> Void)? = nil,
        onEndChange: (() -> Void)?
    ) {
        self.currentValue = value

        self.onStartChange = onStartChange
        self.onEndChange = onEndChange
        self.step = step
        self.minimumDistance = max(minimumDistance, 0)
        self.maximumDistance = maximumDistance
        self.sliderBounds = bounds
    }

    // MARK: - Private Methods

    private func sliderView(sliderSize: CGSize) -> some View {
        let trackHeight = max(sliderSize.height, 1)
        let valueRange = clampedRange(currentValue?.wrappedValue ?? sliderBounds)
        let leftThumbLocation = position(for: valueRange.lowerBound, width: sliderSize.width)
        let rightThumbLocation = position(for: valueRange.upperBound, width: sliderSize.width)
        let selectedWidth = max(rightThumbLocation - leftThumbLocation, 0)

        return ZStack {
            maskedOverlay(
                width: sliderSize.width,
                height: trackHeight,
                selectionX: leftThumbLocation,
                selectionWidth: selectedWidth
            )

            Rectangle()
                .fill(.black.opacity(0.36))
                .overlay {
                    Rectangle()
                        .strokeBorder(.yellow, lineWidth: 2)
                }
                .frame(width: selectedWidth, height: trackHeight)
                .position(
                    x: leftThumbLocation + (selectedWidth / 2),
                    y: trackHeight / 2
                )
                .allowsHitTesting(false)

            let leftThumbPoint = CGPoint(
                x: leftThumbLocation - (handleWidth / 4),
                y: trackHeight / 2
            )
            let rightThumbPoint = CGPoint(
                x: rightThumbLocation + (handleWidth / 4),
                y: trackHeight / 2
            )

            handleView(
                height: trackHeight,
                position: leftThumbPoint,
                isLeftThumb: true
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragValue in
                        if leftThumbDragStartX == nil {
                            leftThumbDragStartX = leftThumbLocation
                            leftThumbDragStartRange = currentValue?.wrappedValue
                            triggerDragStartHaptic()
                            onStartChange?()
                        }

                        let xThumbOffset = min(
                            max((leftThumbDragStartX ?? leftThumbLocation) + dragValue.translation.width, 0),
                            rightThumbLocation - minimumGap(in: sliderSize.width)
                        )

                        updateLowerBound(xThumbOffset, width: sliderSize.width)
                    }
                    .onEnded { _ in
                        triggerDragEndHapticIfNeeded(
                            initialRange: leftThumbDragStartRange,
                            currentRange: currentValue?.wrappedValue
                        )
                        leftThumbDragStartX = nil
                        leftThumbDragStartRange = nil
                        onEndChange?()
                    }
            )

            handleView(
                height: trackHeight,
                position: rightThumbPoint,
                isLeftThumb: false
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragValue in
                        if rightThumbDragStartX == nil {
                            rightThumbDragStartX = rightThumbLocation
                            rightThumbDragStartRange = currentValue?.wrappedValue
                            triggerDragStartHaptic()
                            onStartChange?()
                        }

                        let xThumbOffset = max(
                            leftThumbLocation + minimumGap(in: sliderSize.width),
                            min(
                                (rightThumbDragStartX ?? rightThumbLocation) + dragValue.translation.width,
                                sliderSize.width
                            )
                        )

                        updateUpperBound(xThumbOffset, width: sliderSize.width)
                    }
                    .onEnded { _ in
                        triggerDragEndHapticIfNeeded(
                            initialRange: rightThumbDragStartRange,
                            currentRange: currentValue?.wrappedValue
                        )
                        rightThumbDragStartX = nil
                        rightThumbDragStartRange = nil
                        onEndChange?()
                    }
            )
        }
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }

        let totalRange = max(sliderRange, resolvedStep)
        let relativeValue = clampedValue(value) - sliderBounds.lowerBound
        let progress = relativeValue / totalRange

        return min(max(CGFloat(progress) * width, 0), width)
    }

    private func value(at position: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return sliderBounds.lowerBound }

        let totalRange = max(sliderRange, resolvedStep)
        let rawValue = sliderBounds.lowerBound + (Double(position / width) * totalRange)
        let relativeValue = rawValue - sliderBounds.lowerBound
        let steppedValue = (round(relativeValue / resolvedStep) * resolvedStep) + sliderBounds.lowerBound

        return clampedValue(steppedValue)
    }

    private func minimumGap(in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }

        let totalRange = max(sliderRange, resolvedStep)
        let stepsAcrossRange = max(totalRange / resolvedStep, 1)
        let stepWidth = width / CGFloat(stepsAcrossRange)
        let minimumDistanceWidth =
            sliderRange > 0
            ? (CGFloat(minimumDistance / sliderRange) * width)
            : 0

        return max(stepWidth, minimumVisualGap, minimumDistanceWidth)
    }

    private func maskedOverlay(
        width: CGFloat,
        height: CGFloat,
        selectionX: CGFloat,
        selectionWidth: CGFloat
    ) -> some View {
        RoundedRectangle(
            cornerRadius: RangeSliderMaskedRegionStyle.cornerRadius,
            style: .continuous
        )
        .fill(.black.opacity(0.8))
        .frame(width: max(width, 0), height: height)
        .overlay {
            Rectangle()
                .fill(.black)
                .frame(width: max(selectionWidth, 0), height: height)
                .position(
                    x: selectionX + (selectionWidth / 2),
                    y: height / 2
                )
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private func handleView(height: CGFloat, position: CGPoint, isLeftThumb: Bool) -> some View {
        let hitSize = CGSize(
            width: minimumHandleHitSize.width,
            height: max(height + 8, minimumHandleHitSize.height)
        )

        return ZStack {
            Rectangle()
                .fill(.yellow)
                .frame(width: handleWidth, height: height)
                .overlay {
                    VStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule(style: .continuous)
                                .fill(.background)
                                .frame(width: 2, height: 2)
                        }
                    }
                }
                .clipShape(
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: isLeftThumb ? 8 : 0,
                            bottomLeading: isLeftThumb ? 8 : 0,
                            bottomTrailing: isLeftThumb ? 0 : 8,
                            topTrailing: isLeftThumb ? 0 : 8
                        )
                    )
                )
        }
        .frame(
            width: hitSize.width,
            height: hitSize.height
        )
        .position(
            x: position.x,
            y: position.y
        )
        .accessibilityLabel(
            isLeftThumb
                ? VideoEditorStrings.trimStart
                : VideoEditorStrings.trimEnd
        )
    }

    private func clampedRange(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        RangeSliderConstraintResolver.clampedRange(
            range,
            bounds: sliderBounds,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance
        )
    }

    private func clampedValue(_ value: Double) -> Double {
        min(sliderBounds.upperBound, max(sliderBounds.lowerBound, value))
    }

    private func updateLowerBound(_ xThumbOffset: CGFloat, width: CGFloat) {
        guard let currentValue else { return }

        let currentRange = clampedRange(currentValue.wrappedValue)
        let allowedRange = RangeSliderConstraintResolver.allowedLowerBoundRange(
            for: currentRange,
            bounds: sliderBounds,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance
        )
        let newLowerBound = value(
            at: xThumbOffset,
            width: width
        ).clamped(to: allowedRange)
        let newRange = newLowerBound...currentRange.upperBound

        guard newRange != currentRange else { return }
        guard newLowerBound < currentRange.upperBound else { return }

        currentValue.wrappedValue = newRange
    }

    private func updateUpperBound(_ xThumbOffset: CGFloat, width: CGFloat) {
        guard let currentValue else { return }

        let currentRange = clampedRange(currentValue.wrappedValue)
        let allowedRange = RangeSliderConstraintResolver.allowedUpperBoundRange(
            for: currentRange,
            bounds: sliderBounds,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance
        )
        let newUpperBound = value(
            at: xThumbOffset,
            width: width
        ).clamped(to: allowedRange)
        let newRange = currentRange.lowerBound...newUpperBound

        guard newRange != currentRange else { return }
        guard newUpperBound > currentRange.lowerBound else { return }

        currentValue.wrappedValue = newRange
    }

    private func triggerDragStartHaptic() {
        sliderFeedbackEvent = .dragStarted
        sliderFeedbackTrigger += 1
    }

    private func triggerDragEndHapticIfNeeded(
        initialRange: ClosedRange<Double>?,
        currentRange: ClosedRange<Double>?
    ) {
        guard initialRange != currentRange else { return }
        sliderFeedbackEvent = .dragCommitted
        sliderFeedbackTrigger += 1
    }

}

#Preview {
    RangedSliderView(
        .constant(20...60),
        bounds: 1...100,
        maximumDistance: 30,
        onStartChange: {},
        onEndChange: {}
    )
    .frame(height: 72)
}
