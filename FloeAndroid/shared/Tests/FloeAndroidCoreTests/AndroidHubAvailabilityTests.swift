// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
@testable import FloeTransport
@testable import FloeAndroidWebTools
@testable import FloeAndroidCore

/// Real response-waiter and HTTP error-mapping boundaries. No remote calls.
final class AndroidHubAvailabilityTests: XCTestCase, @unchecked Sendable {
    func testHeadFailureRetainsThePlatformCategoryBeforeAndDuringWait() async {
        for code in [URLError.timedOut, .cannotFindHost, .serverCertificateUntrusted, .cancelled] {
            for waitingFirst in [false, true] {
                let sink = TransportSink(mode: .stream(maxBufferedBytes: 128))
                if !waitingFirst { sink.handleCompletion(URLError(code)) }
                let waiter = Task { try await sink.waitForResponse() }
                if waitingFirst { sink.handleCompletion(URLError(code)) }
                do {
                    _ = try await waiter.value
                    XCTFail("expected platform failure")
                } catch {
                    XCTAssertEqual((error as? URLError)?.code, code)
                }
                XCTAssertEqual(sink.terminalCount, 1)
            }
        }
    }

    func testFirstFailureFencesLateCompletion() async {
        let sink = TransportSink(mode: .stream(maxBufferedBytes: 128))
        sink.handleCompletion(URLError(.timedOut))
        sink.handleCompletion(URLError(.serverCertificateUntrusted))
        do { _ = try await sink.waitForResponse(); XCTFail("expected original failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(sink.terminalCount, 1)
    }

    func testCleanCompletionWithoutHeadKeepsMissingResponseFailure() async {
        let sink = TransportSink(mode: .stream(maxBufferedBytes: 128))
        sink.handleCompletion(nil)
        do { _ = try await sink.waitForResponse(); XCTFail("expected missing response") }
        catch {
            guard case IncrementalTransportError.noHTTPResponse = error else {
                return XCTFail("missing-response category changed")
            }
        }
    }

    func testHTTPMappingPreservesOnlyTypedAvailabilityForRouting() {
        for code in [URLError.timedOut, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] {
            let error = HTTPRequestService.transportFailure(URLError(code))
            XCTAssertEqual((error as? URLError)?.code, code)
            XCTAssertTrue(AndroidHubMirrorTransport.isAvailabilityFailure(error))
        }
        for code in [URLError.serverCertificateUntrusted, .secureConnectionFailed,
                     .cannotLoadFromNetwork, .userAuthenticationRequired, .unknown] {
            let error = HTTPRequestService.transportFailure(URLError(code))
            XCTAssertEqual((error as? URLError)?.code, code)
            XCTAssertFalse(AndroidHubMirrorTransport.isAvailabilityFailure(error))
        }
    }

    func testCancellationAndLocalErrorsNeverAdvanceRoute() {
        for original: Error in [CancellationError(), URLError(.cancelled)] {
            let error = HTTPRequestService.transportFailure(original)
            guard case FloeError.cancelled = error else {
                XCTFail("cancellation category lost"); continue
            }
            XCTAssertFalse(AndroidHubMirrorTransport.isAvailabilityFailure(error))
        }
        let error = HTTPRequestService.transportFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        guard case HTTPRequestError.requestFailed = error else {
            return XCTFail("local error category lost")
        }
        XCTAssertFalse(AndroidHubMirrorTransport.isAvailabilityFailure(error))
    }
}
