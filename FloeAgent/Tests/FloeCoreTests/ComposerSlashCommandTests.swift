import Testing
@testable import FloeCore

struct ComposerSlashCommandTests {
    @Test func parsesCommandAndArgument() {
        #expect(ComposerSlashQuery.parse("/skill pdf") == .init(command: "skill", argument: "pdf"))
        #expect(ComposerSlashQuery.parse("/") == .init(command: "", argument: ""))
        #expect(ComposerSlashQuery.parse("/PLAN") == .init(command: "plan", argument: ""))
    }

    @Test func doesNotInterceptOrdinaryText() {
        #expect(ComposerSlashQuery.parse("打开 https://example.com") == nil)
        #expect(ComposerSlashQuery.parse("docs/readme.md") == nil)
        #expect(ComposerSlashQuery.parse("/compact\n下一行") == nil)
    }
}
