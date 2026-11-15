import Foundation
import XCTest
@testable import FloeLinuxGPU

final class LinuxGraphicsCapabilityTests: XCTestCase {
    private let evidence = "qual-01|libvulkan_virtio.so@sha256:abc"

    private func verified(_ evidence: String = "qual-01|artifact@sha256:abc") -> LinuxGraphicsFeature {
        LinuxGraphicsFeature(available: true, evidence: evidence)
    }

    func testValidDeclarationAcceptsGatedFeatures() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: verified(),
            openGL: verified(),
            shaderCache: verified())
        XCTAssertTrue(declaration.isValid)
        XCTAssertEqual(declaration.issues(), [])
    }

    func testAvailableWithoutEvidenceIsRejected() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: LinuxGraphicsFeature(available: true))
        XCTAssertFalse(declaration.isValid)
        XCTAssertEqual(declaration.issues(), [.missingEvidence("venusVulkan")])
    }

    func testEvidenceWithoutAvailabilityIsRejected() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: LinuxGraphicsFeature(available: false, evidence: "stale"))
        XCTAssertFalse(declaration.isValid)
        XCTAssertEqual(declaration.issues(), [.evidenceWithoutAvailability("venusVulkan")])
    }

    func testOpenGLRequiresVenus() {
        let declaration = LinuxGraphicsCapabilities(openGL: verified())
        XCTAssertFalse(declaration.isValid)
        XCTAssertTrue(declaration.issues().contains(.gateNotSatisfied("openGL", "venusVulkan")))
    }

    func testShaderCacheRequiresOpenGL() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: verified(),
            shaderCache: verified())
        XCTAssertFalse(declaration.isValid)
        XCTAssertTrue(declaration.issues().contains(.gateNotSatisfied("shaderCache", "openGL")))
    }

    func testDecodesProducerShape() throws {
        let json = """
        {
          "schemaVersion": 1,
          "venusVulkan": {"available": true, "evidence": "qual|a@sha256:1", "limitation": null},
          "openGL": {"available": true, "evidence": "qual|b@sha256:2", "limitation": null},
          "openCL": {"available": false, "evidence": null, "limitation": "compiler not admitted"},
          "shaderCache": {"available": true, "evidence": "qual|b@sha256:2", "limitation": null},
          "video": {
            "hardwareDecode": {"available": false, "evidence": null, "limitation": null},
            "hardwareEncode": {"available": false, "evidence": null, "limitation": null},
            "nativeSoftware": {"available": true, "evidence": "qual|c@sha256:3", "limitation": "CPU codec"}
          }
        }
        """.data(using: .utf8)!
        let declaration = try JSONDecoder().decode(LinuxGraphicsCapabilities.self, from: json)
        XCTAssertTrue(declaration.isValid)
        XCTAssertEqual(declaration.openCL?.limitation, "compiler not admitted")
        XCTAssertFalse(declaration.video?.hardwareDecode?.available ?? true)
        XCTAssertTrue(declaration.video?.nativeSoftware?.available ?? false)
    }

    func testStoppedGuestIsNotPresentedAsAccelerated() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: verified(), openGL: verified(), shaderCache: verified())
        let status = LinuxGraphicsStatus(
            capabilities: declaration,
            runtime: .init(guestRunning: false, gpuPresent: nil))
        XCTAssertEqual(status.summary, .guestStopped)
        XCTAssertFalse(status.venusVulkan)
        XCTAssertFalse(status.openGL)
        XCTAssertFalse(status.shaderCache)
    }

    func testCPUOnlyFallbackIsExplicit() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: verified(), openGL: verified(), shaderCache: verified())
        let status = LinuxGraphicsStatus(
            capabilities: declaration,
            runtime: .init(guestRunning: true, gpuPresent: false, effectiveBytes: 0))
        XCTAssertEqual(status.summary, .cpuOnly)
        XCTAssertFalse(status.venusVulkan)
        XCTAssertFalse(status.openGL)
    }

    func testActiveDeviceReportsLiveBytesAndFeatures() {
        let declaration = LinuxGraphicsCapabilities(
            venusVulkan: verified(), openGL: verified(), shaderCache: verified())
        let status = LinuxGraphicsStatus(
            capabilities: declaration,
            runtime: .init(guestRunning: true, gpuPresent: true,
                           effectiveBytes: 512 * 1_048_576))
        XCTAssertEqual(status.summary, .ready(effectiveBytes: 512 * 1_048_576))
        XCTAssertTrue(status.venusVulkan)
        XCTAssertTrue(status.openGL)
        XCTAssertTrue(status.shaderCache)
    }

    func testNeedsResetHidesCapabilities() {
        let declaration = LinuxGraphicsCapabilities(venusVulkan: verified(), openGL: verified())
        let status = LinuxGraphicsStatus(
            capabilities: declaration,
            runtime: .init(guestRunning: true, gpuPresent: true, needsReset: true))
        XCTAssertEqual(status.summary, .needsReset)
        XCTAssertFalse(status.venusVulkan)
    }

    func testMissingDeclarationNeverBecomesAvailable() {
        let status = LinuxGraphicsStatus(
            capabilities: nil,
            runtime: .init(guestRunning: true, gpuPresent: true, effectiveBytes: 1024))
        XCTAssertEqual(status.summary, .noDeclaredCapabilities)
        XCTAssertFalse(status.venusVulkan)
    }

    func testProbeRejectsSoftwareAndUnsupportedDevices() {
        let software = LinuxGraphicsProbeReport(
            device: "llvmpipe (LLVM 19)", deviceType: "cpu", apiVersion: 4200000,
            venus: true, softwareDevice: true)
        XCTAssertFalse(software.isTrustworthy)

        let lavapipe = LinuxGraphicsProbeReport(
            device: "Virtio-GPU Venus", deviceType: "virtual", apiVersion: 4200000,
            venus: true, softwareDevice: false)
        XCTAssertTrue(lavapipe.isTrustworthy)

        let softGL = LinuxGraphicsProbeReport(
            device: "Virtio-GPU Venus", deviceType: "integrated", apiVersion: 4200000,
            venus: true,
            openGL: .init(renderer: "llvmpipe (LLVM 19, 128 bits)", version: "4.5", hardware: true))
        XCTAssertFalse(softGL.isTrustworthy)
        XCTAssertTrue(softGL.rejections().contains {
            if case .softwareOpenGL = $0 { return true }
            return false
        })
    }

    func testProbeRejectsMissingVenusAndRenderer() {
        let noVenus = LinuxGraphicsProbeReport(
            device: "Apple M5 Pro", deviceType: "integrated", apiVersion: 4200000, venus: false)
        XCTAssertTrue(noVenus.rejections().contains(.venusDisabled))

        let emptyGL = LinuxGraphicsProbeReport(
            device: "Virtio-GPU Venus", deviceType: "virtual", apiVersion: 4200000,
            venus: true, openGL: .init())
        XCTAssertTrue(emptyGL.rejections().contains(.missingOpenGLRenderer))
    }
}
