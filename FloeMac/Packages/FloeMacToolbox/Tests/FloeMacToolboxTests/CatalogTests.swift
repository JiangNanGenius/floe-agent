import Testing
@testable import FloeMacToolbox

@Test func catalogLoadsTheFirstMacBatch() {
    #expect(MacToolboxTool.firstMacBatch.count == 5)
}

@Test func supportedMediaEntriesAreExplicitAndDistinct() {
    #expect(MacToolboxTool.mediaBatch == [.magnifier, .scanner])
    #expect(Set(MacToolboxTool.firstMacBatch).isDisjoint(with: MacToolboxTool.mediaBatch))
}

@Test func unfinishedTimerIsNotAnEnabledTool() {
    #expect(!MacToolboxTool.firstMacBatch.contains(.timer))
    #expect(!MacToolboxTool.mediaBatch.contains(.timer))
}
