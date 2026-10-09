//
//  CameraAnimator.swift
//  openshape3d
//
//  Eases the turntable camera to a target pose. Drives the paused MTKView
//  with a CADisplayLink for the duration of the flight.
//

import Foundation
import UIKit
import MetalKit

@MainActor
final class CameraAnimator {
    private weak var renderer: Renderer?
    private weak var view: MTKView?

    private var displayLink: CADisplayLink?
    private var start: TurntableCamera?
    private var target: TurntableCamera?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.35

    /// Fired on every animation step (the camera moved).
    var cameraChanged: (() -> Void)?

    init(renderer: Renderer, view: MTKView) {
        self.renderer = renderer
        self.view = view
    }

    func animate(to camera: TurntableCamera, duration: CFTimeInterval = 0.35) {
        guard let renderer else { return }
        displayLink?.invalidate()
        start = renderer.camera
        target = camera
        startTime = CACurrentMediaTime()
        self.duration = duration

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        guard let renderer, let start, let target else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        let raw = min(elapsed / duration, 1)
        // easeInOut
        let t = Float(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)

        var camera = renderer.camera
        camera.target = simd_mix(start.target, target.target, SIMD3(repeating: t))
        camera.distance = start.distance + (target.distance - start.distance) * t
        camera.azimuth = start.azimuth + shortestAngle(from: start.azimuth, to: target.azimuth) * t
        camera.elevation = start.elevation + (target.elevation - start.elevation) * t
        renderer.camera = camera
        view?.setNeedsDisplay()
        cameraChanged?()

        if raw >= 1 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func shortestAngle(from a: Float, to b: Float) -> Float {
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
