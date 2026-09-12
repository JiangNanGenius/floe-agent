import AVFoundation
import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("CameraManagerTests", .serialized)
struct CameraManagerTests {

    // MARK: - Public Methods

    @Test
    func initialPublicStateMatchesCurrentDefaults() {
        let manager = CameraManager(autoConfigure: false)

        #expect(manager.finalURL == nil)
        #expect(manager.recordedDuration == 0)
        #expect(manager.cameraPosition == .back)
        #expect(manager.maxDuration == 100)
        #expect(manager.isRecording == false)
    }

    @Test
    func consumeFinalURLReturnsTheStoredValueAndClearsIt() {
        let manager = CameraManager(autoConfigure: false)
        let url = URL(fileURLWithPath: "/tmp/camera-output.mov")
        manager.finalURL = url

        let consumedURL = manager.consumeFinalURL()

        #expect(consumedURL == url)
        #expect(manager.finalURL == nil)
    }

    @Test
    func stopRecordIsSafeWhenNothingIsBeingRecorded() {
        let manager = CameraManager(autoConfigure: false)

        manager.stopRecord()

        #expect(manager.isRecording == false)
    }

    @Test
    func cameraErrorsCanBeInstantiatedForEachPublicCase() {
        let sampleError = NSError(domain: "CameraManagerTests", code: 1)

        let errors: [CameraError] = [
            .deniedAuthorization,
            .restrictedAuthorization,
            .unknowAuthorization,
            .cameraUnavalible,
            .cannotAddInput,
            .createCaptureInput(sampleError),
            .outputError(sampleError),
        ]

        #expect(errors.count == 7)
    }

    @Test
    func autoConfigureDelegatesConfigurationToTheCaptureController() {
        let captureController = CameraCaptureControllerDouble()

        _ = CameraManager(captureController: captureController)

        #expect(captureController.configureRequests.count == 1)
        #expect(captureController.configureRequests.first?.cameraPosition == .back)
        #expect(captureController.configureRequests.first?.maxDuration == 100)
    }

    @Test
    func controllSessionDelegatesStateChangesToTheCaptureController() {
        let captureController = CameraCaptureControllerDouble()
        let manager = CameraManager(
            captureController: captureController,
            autoConfigure: false
        )

        manager.controllSession(start: true)
        manager.controllSession(start: false)

        #expect(captureController.controlRequests.map(\.start) == [true, false])
        #expect(captureController.controlRequests.allSatisfy { $0.cameraPosition == .back })
        #expect(captureController.controlRequests.allSatisfy { $0.maxDuration == 100 })
    }

    @Test
    func startRecordingUsesTheInjectedCaptureControllerAndTemporaryURLFactory() {
        let captureController = CameraCaptureControllerDouble()
        let expectedURL = URL(fileURLWithPath: "/tmp/camera-phase3.mov")
        let manager = CameraManager(
            maxDuration: 5,
            captureController: captureController,
            sleep: { _ in throw CancellationError() },
            temporaryURLProvider: { expectedURL },
            autoConfigure: false
        )

        manager.recordedDuration = 4
        manager.startRecording()

        #expect(manager.recordedDuration == 0)
        #expect(captureController.startedURLs == [expectedURL])
        #expect(manager.isRecording == true)
    }

    @Test
    func toggleRecordingStopsTheInjectedCaptureControllerWhenAlreadyRecording() {
        let captureController = CameraCaptureControllerDouble()
        captureController.isRecording = true
        let manager = CameraManager(
            captureController: captureController,
            sleep: { _ in },
            autoConfigure: false
        )

        manager.toggleRecording()

        #expect(captureController.stopRecordingCallCount == 1)
    }

    @Test
    func captureControllerErrorsPublishOnTheObservedState() async {
        let captureController = CameraCaptureControllerDouble()
        let manager = CameraManager(
            captureController: captureController,
            autoConfigure: false
        )

        let sampleError = NSError(domain: "CameraManagerTests", code: 77)
        captureController.emitError(.outputError(sampleError))

        await waitUntil {
            if case .outputError = manager.error {
                true
            } else {
                false
            }
        }

        guard case .outputError(let receivedError)? = manager.error else {
            Issue.record("Expected an outputError published by the capture controller.")
            return
        }

        #expect((receivedError as NSError).domain == sampleError.domain)
        #expect((receivedError as NSError).code == sampleError.code)
    }

    @Test
    func fileOutputSuccessPublishesTheRecordedURL() async {
        let manager = CameraManager(autoConfigure: false)
        let outputURL = URL(fileURLWithPath: "/tmp/camera-success.mov")

        manager.fileOutput(
            AVCaptureMovieFileOutput(),
            didFinishRecordingTo: outputURL,
            from: [],
            error: nil
        )

        await waitUntil { manager.finalURL == outputURL }

        #expect(manager.finalURL == outputURL)
        #expect(manager.error == nil)
    }

    @Test
    func fileOutputFailurePublishesTheOutputError() async {
        let manager = CameraManager(autoConfigure: false)
        let sampleError = NSError(domain: "CameraManagerTests", code: 99)

        manager.fileOutput(
            AVCaptureMovieFileOutput(),
            didFinishRecordingTo: URL(fileURLWithPath: "/tmp/camera-failure.mov"),
            from: [],
            error: sampleError
        )

        await waitUntil {
            if case .outputError = manager.error {
                true
            } else {
                false
            }
        }

        guard case .outputError(let receivedError)? = manager.error else {
            Issue.record("Expected an outputError after a failed recording callback.")
            return
        }

        #expect((receivedError as NSError).domain == sampleError.domain)
        #expect((receivedError as NSError).code == sampleError.code)
    }

    @Test
    func recordingDurationUpdatesCanBeDrivenByTheInjectedSleeper() async {
        let captureController = CameraCaptureControllerDouble()
        let manager = CameraManager(
            maxDuration: 2,
            captureController: captureController,
            sleep: { _ in },
            autoConfigure: false
        )

        manager.startRecording()
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(manager.recordedDuration == 2)
        #expect(captureController.stopRecordingCallCount == 1)
        #expect(manager.isRecording == false)
    }

}

private final class CameraCaptureControllerDouble: CameraCaptureControlling {

    // MARK: - Public Properties

    let session = AVCaptureSession()
    var isRecording = false
    private(set) var configureRequests: [(cameraPosition: AVCaptureDevice.Position, maxDuration: Double)] = []
    private(set) var controlRequests: [(start: Bool, cameraPosition: AVCaptureDevice.Position, maxDuration: Double)] =
        []
    private(set) var startedURLs: [URL] = []
    private(set) var stopRecordingCallCount = 0

    // MARK: - Private Properties

    private var errorHandler: (@MainActor (CameraError) -> Void)?

    // MARK: - Public Methods

    func setErrorHandler(_ handler: @escaping @MainActor (CameraError) -> Void) {
        errorHandler = handler
    }

    func configureIfNeeded(cameraPosition: AVCaptureDevice.Position, maxDuration: Double) {
        configureRequests.append((cameraPosition, maxDuration))
    }

    func controlSession(
        start: Bool,
        cameraPosition: AVCaptureDevice.Position,
        maxDuration: Double
    ) {
        controlRequests.append((start, cameraPosition, maxDuration))
    }

    func startRecording(
        to outputFileURL: URL,
        recordingDelegate: AVCaptureFileOutputRecordingDelegate
    ) {
        startedURLs.append(outputFileURL)
        isRecording = true
    }

    func stopRecording() {
        stopRecordingCallCount += 1
        isRecording = false
    }

    func emitError(_ error: CameraError) {
        Task { @MainActor [errorHandler] in
            errorHandler?(error)
        }
    }

}

private func waitUntil(
    iterations: Int = 20,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<iterations where !(await MainActor.run { condition() }) {
        await Task.yield()
    }
}
