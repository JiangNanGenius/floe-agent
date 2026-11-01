// SPDX-License-Identifier: MPL-2.0
//
// X33 — capability summary/detail/search/schema must report genuinely
// executable availability. These tests drive the real catalog/dispatcher
// APIs (never source-string matching):
//
//  * every advertised native op is recognized by the real parser;
//  * guaranteed-refusal ops stay parseable for the original structured
//    refusal but are absent from the advertised list and reported as
//    unavailable;
//  * Command Search's default corpus, the chord registry and the cheat sheet
//    contain only ids the dispatcher declares executable.
//

import XCTest
@testable import FloeCAD

@MainActor
final class CADCapabilityAvailabilityTests: XCTestCase {

    func testEveryAdvertisedNativeOperationIsRecognizedByTheParser() {
        for op in FloeCADDocument.nativeOperationNames {
            let result = AgentExec.parse(["op": op, "args": [:]])
            if case .failure(let error) = result {
                XCTAssertNotEqual(
                    error.code, "unknown_op",
                    "\(op) is advertised as executable but AgentExec.parse does not recognize it")
            }
        }
    }

    func testGuaranteedRefusalsAreUnavailableNotAdvertisedButStillParseable() {
        let advertised = Set(FloeCADDocument.nativeOperationNames)
        let unavailable = FloeCADDocument.unavailableNativeOperations
        let names = Set(unavailable.compactMap { $0["op"] as? String })
        XCTAssertEqual(names, Set(["feature.scaleFace", "feature.rotateFace"]))
        XCTAssertTrue(advertised.isDisjoint(with: names),
                      "a guaranteed-refusal op must not be advertised as executable")
        for row in unavailable {
            guard let op = row["op"] as? String else {
                XCTFail("unavailable operation row has no op")
                continue
            }
            XCTAssertEqual(row["code"] as? String, "exact_edit_unsupported")
            XCTAssertEqual(row["available"] as? Bool, false)
            let detail = AgentExec.unavailableOps.first { $0.op == op }
            XCTAssertFalse(detail?.message.isEmpty ?? true,
                           "\(op) needs a truthful human-readable reason")
            // Historical callers must still reach the original structured
            // refusal instead of an unrelated unknown_op.
            let result = AgentExec.parse(["op": op, "args": [:]])
            if case .failure(let error) = result {
                XCTAssertNotEqual(error.code, "unknown_op",
                                  "\(op) must keep its recognized refusal path")
            }
        }
    }

    func testCommandSearchChordsAndCheatSheetOnlyOfferExecutableCommands() {
        let registry = CommandRegistry()

        for command in CommandRegistry.launchableCommands {
            XCTAssertTrue(command.isExecutable,
                          "\(command.id) is searchable but has no dispatcher case")
            XCTAssertTrue(CommandRegistry.routableIDs.contains(command.id))
        }
        XCTAssertTrue(CommandRegistry.routableChordedCommands.allSatisfy { $0.isExecutable })
        XCTAssertTrue(CommandRegistry.cheatSheet.values.flatMap { $0 }.allSatisfy { $0.isExecutable })
        XCTAssertTrue(CommandRegistry.unroutedChordedCommands.allSatisfy { !$0.isExecutable })
        XCTAssertNil(registry.command(for: KeyChord("i")),
                     "sketch.image advertises i but has no dispatcher case")
        XCTAssertTrue(registry.command(for: KeyChord("e"))?.id == "model.extrude",
                      "a real chord still resolves through the executable filter")

        // The default search corpus is the executable launcher set; the named
        // planned entries must never appear even when their exact title is
        // typed. Each one retains a stable id and an explicit reason.
        for id in ["plane.angle", "plane.threePoints", "project.insertProject"] {
            let command = registry.command(id: id)
            XCTAssertNotNil(command, "\(id) keeps its stable catalog id")
            XCTAssertEqual(command?.isExecutable, false)
            XCTAssertNil(CommandRegistry.launchableCommands.first { $0.id == id })
            XCTAssertFalse(registry.search(command?.title ?? "").contains { $0.id == id })
            XCTAssertNotNil(CommandRegistry.unavailableReason(for: id))
        }
        for command in CommandRegistry.unavailableCommands {
            XCTAssertFalse(command.isExecutable)
            XCTAssertNotNil(CommandRegistry.unavailableReason(for: command.id))
        }
        XCTAssertNil(CommandRegistry.unavailableReason(for: "model.extrude"),
                     "an executable command has no unavailable reason")
    }
}
