// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameDeveloperCore
import FloeGameDeveloperUI
import FloeGameCore

@MainActor
@Test func readPollDoesNotDisableEditingControls() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let model = GameDeveloperMenuModel(session: session)
    transport.responseDelay = .milliseconds(180)
    let refresh = Task { await session.refresh() }
    try await Task.sleep(for: .milliseconds(40))
    #expect(session.isRefreshing)
    #expect(model.isBusy == false)
    await refresh.value
    transport.responseDelay = nil
    #expect(model.isBusy == false)
}

@MainActor
@Test func successAndErrorFeedbackAreSeparate() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let model = GameDeveloperMenuModel(session: session)
    transport.rejectWrites = true
    model.write(field: try #require(session.capabilities?.field("party.gold")), value: .integer(7))
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.errorText != nil)
    #expect(model.successText == nil)
    model.dismissError()
    transport.rejectWrites = false
    model.write(field: try #require(session.capabilities?.field("party.gold")), value: .integer(8))
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.errorText == nil)
    #expect(model.successText != nil)
}

@Test func englishAndChineseStringsStayAligned() {
    let english = GameDeveloperStrings(locale: .english)
    let chinese = GameDeveloperStrings(locale: .simplifiedChinese)
    #expect(english.title == "Developer menu")
    #expect(chinese.title == "开发者菜单")
    #expect(english.search == "Search fields and actions")
    #expect(chinese.search == "搜索字段和动作")
}
