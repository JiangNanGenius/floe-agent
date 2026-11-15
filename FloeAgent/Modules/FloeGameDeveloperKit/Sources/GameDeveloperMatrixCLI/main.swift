// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameDeveloperCore

let data = GameDeveloperEngineCatalog.matrixJSON
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
