//
//  CameraPreviewView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVFoundation
import Observation
import SwiftUI

protocol CameraRecordingOutput: AnyObject {

    var isRecording: Bool { get }

    func startRecording(to outputFileURL: URL, recordingDelegate: AVCaptureFileOutputRecordingDelegate)
    func stopRecording()
    func setMaximumRecordedDuration(seconds: Double)
    func addToSession(_ session: AVCaptureSession) -> Bool

}

protocol CameraCaptureControlling: AnyObject {

    var session: AVCaptureSession { get }
    var isRecording: Bool { get }

    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (CameraError) -> Void)
    func configureIfNeeded(cameraPosition: AVCaptureDevice.Position, maxDuration: Double)
    func controlSession(
        start: Bool,
        cameraPosition: AVCaptureDevice.Position,
        maxDuration: Double
    )
    func startRecording(
        to outputFileURL: URL,
        recordingDelegate: AVCaptureFileOutputRecordingDelegate
    )
    func stopRecording()

}

extension AVCaptureMovieFileOutput: CameraRecordingOutput {

    func setMaximumRecordedDuration(seconds: Double) {
        maxRecordedDuration = CMTime(seconds: seconds, preferredTimescale: 1)
    }

    func addToSession(_ session: AVCaptureSession) -> Bool {
        guard session.canAddOutput(self) else { return false }
        session.addOutput(self)
        return true
    }

}

private final class CameraCaptureController: CameraCaptureControlling, @unchecked Sendable {

    // MARK: - Public Properties

    let session: AVCaptureSession

    var isRecording: Bool {
        videoOutput.isRecording
    }

    // MARK: - Private Properties

    private let sessionQueue = DispatchQueue(label: "com.VideoEditorKit.camera.session", qos: .userInitiated)
    private let videoOutput: any CameraRecordingOutput
    private var status: Status = .unconfigurate
    private var errorHandler: (@MainActor @Sendable (CameraError) -> Void)?

    // MARK: - Initializer

    init(
        session: AVCaptureSession = AVCaptureSession(),
        videoOutput: any CameraRecordingOutput = AVCaptureMovieFileOutput()
    ) {
        self.session = session
        self.videoOutput = videoOutput
    }

    // MARK: - Public Methods

    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (CameraError) -> Void) {
        errorHandler = handler
    }

    func configureIfNeeded(cameraPosition: AVCaptureDevice.Position, maxDuration: Double) {
        guard status == .unconfigurate else { return }

        checkPermissions()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            configureCaptureSession(
                cameraPosition: cameraPosition,
                maxDuration: maxDuration
            )

            guard status == .configurate else { return }

            session.startRunning()
        }
    }

    func controlSession(
        start: Bool,
        cameraPosition: AVCaptureDevice.Position,
        maxDuration: Double
    ) {
        guard status == .configurate else {
            configureIfNeeded(
                cameraPosition: cameraPosition,
                maxDuration: maxDuration
            )
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if start {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } else {
                self.session.stopRunning()
            }
        }
    }

    func startRecording(
        to outputFileURL: URL,
        recordingDelegate: AVCaptureFileOutputRecordingDelegate
    ) {
        videoOutput.startRecording(
            to: outputFileURL,
            recordingDelegate: recordingDelegate
        )
    }

    func stopRecording() {
        videoOutput.stopRecording()
    }

    // MARK: - Private Methods

    private func notifyError(_ error: CameraError) {
        guard let errorHandler else { return }

        Task { @MainActor in
            errorHandler(error)
        }
    }

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {

        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] authorized in
                guard let self else { return }

                if !authorized {
                    self.status = .unauthorized
                    self.notifyError(.deniedAuthorization)
                }

                self.sessionQueue.resume()
            }
        case .restricted:
            status = .unauthorized
            notifyError(.restrictedAuthorization)
        case .denied:
            status = .unauthorized
            notifyError(.deniedAuthorization)
        case .authorized:
            break
        @unknown default:
            status = .unauthorized
            notifyError(.unknowAuthorization)
        }
    }

    private func configureCaptureSession(
        cameraPosition: AVCaptureDevice.Position,
        maxDuration: Double
    ) {
        guard status == .unconfigurate else { return }

        session.beginConfiguration()

        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        let device = getCameraDevice(for: cameraPosition)
        let audioDevice = AVCaptureDevice.default(for: .audio)

        guard let camera = device, let audio = audioDevice else {
            notifyError(.cameraUnavalible)
            status = .faild
            return
        }

        do {
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            let audioInput = try AVCaptureDeviceInput(device: audio)

            if session.canAddInput(cameraInput) && session.canAddInput(audioInput) {
                session.addInput(audioInput)
                session.addInput(cameraInput)
            } else {
                notifyError(.cannotAddInput)
                status = .faild
                return
            }
        } catch {
            notifyError(.createCaptureInput(error))
            status = .faild
            return
        }

        if videoOutput.addToSession(session) {
            videoOutput.setMaximumRecordedDuration(seconds: maxDuration)
        } else {
            notifyError(.cannotAddInput)
            status = .faild
            return
        }

        status = .configurate
    }

    private func getCameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInTrueDepthCamera,
                .builtInDualWideCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )

        for device in discoverySession.devices where device.position == position {
            return device
        }

        return nil
    }

}

extension CameraCaptureController {

    enum Status {
        case unconfigurate
        case configurate
        case unauthorized
        case faild
    }

}

@MainActor
@Observable
final class CameraManager: NSObject {

    // MARK: - Public Properties

    let maxDuration: Double

    var error: CameraError?
    let session: AVCaptureSession
    var finalURL: URL?
    var recordedDuration: Double = .zero
    var cameraPosition: AVCaptureDevice.Position = .back

    var isRecording: Bool {
        captureController.isRecording
    }

    // MARK: - Private Properties

    @ObservationIgnored
    private var recordingDurationTask: Task<Void, Never>?

    @ObservationIgnored
    private let captureController: any CameraCaptureControlling

    @ObservationIgnored
    private let sleep: @Sendable (Duration) async throws -> Void

    @ObservationIgnored
    private let temporaryURLProvider: () -> URL

    // MARK: - Initializer

    init(
        maxDuration: Double = 100,
        cameraPosition: AVCaptureDevice.Position = .back,
        captureController: (any CameraCaptureControlling)? = nil,
        session: AVCaptureSession = AVCaptureSession(),
        videoOutput: any CameraRecordingOutput = AVCaptureMovieFileOutput(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        temporaryURLProvider: @escaping () -> URL = {
            URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        },
        autoConfigure: Bool = true
    ) {
        let resolvedCaptureController =
            captureController
            ?? CameraCaptureController(session: session, videoOutput: videoOutput)

        self.maxDuration = maxDuration
        self.cameraPosition = cameraPosition
        self.captureController = resolvedCaptureController
        self.session = resolvedCaptureController.session
        self.sleep = sleep
        self.temporaryURLProvider = temporaryURLProvider

        super.init()

        resolvedCaptureController.setErrorHandler { [weak self] error in
            self?.error = error
        }

        if autoConfigure {
            resolvedCaptureController.configureIfNeeded(
                cameraPosition: cameraPosition,
                maxDuration: maxDuration
            )
        }
    }

    // MARK: - Public Methods

    func controllSession(start: Bool) {
        captureController.controlSession(
            start: start,
            cameraPosition: cameraPosition,
            maxDuration: maxDuration
        )
    }

    func stopRecord() {
        stopRecordingDurationUpdates()
        captureController.stopRecording()
    }

    func toggleRecording() {
        if isRecording {
            stopRecord()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        recordedDuration = .zero

        let tempURL = temporaryURLProvider()

        captureController.startRecording(
            to: tempURL,
            recordingDelegate: self
        )

        startRecordingDurationUpdates()
    }

    // MARK: - Private Methods

    private func setFinalURL(_ url: URL) {
        finalURL = url
    }

    func consumeFinalURL() -> URL? {
        let url = finalURL
        finalURL = nil
        return url
    }

    // MARK: - Private Methods

    private func startRecordingDurationUpdates() {
        recordingDurationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                do {
                    try await self.sleep(.seconds(1))
                } catch {
                    return
                }

                guard captureController.isRecording else { return }

                recordedDuration = min(recordedDuration + 1, maxDuration)

                if recordedDuration >= maxDuration {
                    stopRecord()
                    return
                }
            }
        }
    }

    private func stopRecordingDurationUpdates() {
        recordingDurationTask?.cancel()
        recordingDurationTask = nil
    }

}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    // MARK: - Public Methods

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            stopRecordingDurationUpdates()

            if let error {
                self.error = .outputError(error)
            } else {
                setFinalURL(outputFileURL)
            }
        }
    }

}
