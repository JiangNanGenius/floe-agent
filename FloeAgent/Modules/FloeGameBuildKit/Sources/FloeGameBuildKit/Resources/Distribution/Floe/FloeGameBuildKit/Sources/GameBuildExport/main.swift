// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameBuildKit

/// Deterministic export of the validated CI workflow templates and native
/// packaging recipes. Hosts embed the emitted YAML; this tool never dispatches.
struct TemplateRecord: Encodable {
    let engine: String
    let fileName: String
    let yaml: String
    let requiredSecrets: [String]
    let inputs: [String]
    let documentation: [String]
    let actionReferences: [String]
    let notes: [String]
    let actuallyDispatched: Bool
}

struct RecipeRecord: Encodable {
    let engine: String
    let platform: String
    let configuration: String
    let format: String
    let toolCommand: String
    let notes: [String]
    let installableFromTemplate: Bool
}

struct Export: Encodable {
    let schemaVersion: Int
    let templates: [TemplateRecord]
    let recipes: [RecipeRecord]
}

let engines: [GameEngineID] = [.unity, .godot, .cocosCreator, .gdevelop, .phaser]
var templates: [TemplateRecord] = []
for engine in engines {
    guard let template = GameCIWorkflowTemplates.template(for: engine) else {
        FileHandle.standardError.write(Data("missing template for \(engine.rawValue)\n".utf8))
        exit(2)
    }
    do {
        try GameCIWorkflowTemplates.validate(template)
    } catch {
        FileHandle.standardError.write(Data("invalid template \(engine.rawValue): \(error)\n".utf8))
        exit(3)
    }
    templates.append(.init(engine: engine.rawValue, fileName: template.fileName, yaml: template.yaml,
                           requiredSecrets: template.requiredSecrets, inputs: template.inputs,
                           documentation: template.provenance.documentation.map(\.absoluteString),
                           actionReferences: template.provenance.actionReferences,
                           notes: template.provenance.notes,
                           actuallyDispatched: template.actuallyDispatched))
}
var recipes: [RecipeRecord] = []
for engine in GameEngineID.allCases {
    for recipe in GameNativePackaging.recipes(for: engine) {
        recipes.append(.init(engine: engine.rawValue, platform: recipe.platform.rawValue,
                             configuration: recipe.configuration, format: recipe.format.rawValue,
                             toolCommand: recipe.toolCommand, notes: recipe.notes,
                             installableFromTemplate: recipe.installableFromTemplate))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
FileHandle.standardOutput.write(try encoder.encode(Export(schemaVersion: 1, templates: templates, recipes: recipes)))
FileHandle.standardOutput.write(Data("\n".utf8))
