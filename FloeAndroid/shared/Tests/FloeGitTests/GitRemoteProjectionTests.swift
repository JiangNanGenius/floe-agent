// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGit

@Suite("Git remote projection")
struct GitRemoteProjectionTests {
    @Test func importedRemoteDoesNotPublishUserinfoOrQueryCredentials() {
        let input = URL(string: "https://synthetic-user:synthetic-password@github.com/example/repository.git?token=synthetic#private")!
        #expect(LocalGitService.displayRemoteURL(input) == "https://github.com/example/repository.git")
        #expect(input.user == "synthetic-user") // Display cleanup never mutates transport configuration.
    }
    @Test func ordinaryRemoteRetainsHostPortAndRepositoryPath() {
        let value = "https://github.com:443/example/repository.git"
        #expect(LocalGitService.displayRemoteURL(URL(string: value)) == value)
    }
    @Test func localOrOpaqueRemoteDoesNotExposeAnUnstructuredCredentialString() {
        #expect(LocalGitService.displayRemoteURL(URL(fileURLWithPath: "/synthetic/private/repository")) == nil)
        #expect(LocalGitService.displayRemoteURL(nil) == nil)
    }
}
