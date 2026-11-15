// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

@main struct InteriorResearchFixture {
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw NSError(domain:"InteriorResearchFixture",code:1,
                          userInfo:[NSLocalizedDescriptionKey:"Usage: InteriorResearchFixture <new-output-directory>"])
        }
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:root.path) else {
            throw NSError(domain:"InteriorResearchFixture",code:2,
                          userInfo:[NSLocalizedDescriptionKey:"Output exists; preserve it and choose a new directory."])
        }
        let original=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        var resized=original.recipe; resized.widthMM=2600
        let updated=try CabinetBuilder.build(resized)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        for (name,assembly) in [("cabinet-2400",original),("cabinet-2600",updated)] {
            try encoder.encode(assembly).write(to:root.appendingPathComponent(name+".json"),options:.atomic)
            try encoder.encode(CabinetDerivations.nativeDrafts(assembly)).write(to:root.appendingPathComponent(name+"-native-drafts.json"),options:.atomic)
            try encoder.encode(CabinetDerivations.drawingPlans(assembly)).write(to:root.appendingPathComponent(name+"-drawing-plan.json"),options:.atomic)
            try CabinetDerivations.partsCSV(assembly).write(to:root.appendingPathComponent(name+"-parts.csv"),atomically:true,encoding:.utf8)
        }
        print("Created \(original.panels.count) stable panels at 2400/2600 mm. Manufacturing not validated.")
    }
}
