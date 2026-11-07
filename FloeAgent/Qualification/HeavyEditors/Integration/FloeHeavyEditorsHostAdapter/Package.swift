// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package = Package(name:"FloeHeavyEditorsHostAdapter",platforms:[.iOS(.v26),.macOS(.v15)],
    products:[.library(name:"FloeHeavyEditorsHostAdapter",targets:["FloeHeavyEditorsHostAdapter"])],
    dependencies:[.package(path:"../../../../Modules/FloeHeavyEditorSupport"),.package(name:"FloeAgent",path:"../../../..")],
    targets:[.target(name:"FloeHeavyEditorsHostAdapter",dependencies:[.product(name:"FloeHeavyEditorSupport",package:"FloeHeavyEditorSupport"),.product(name:"FloeCore",package:"FloeAgent"),.product(name:"FloeModels",package:"FloeAgent"),.product(name:"FloeTools",package:"FloeAgent")])],swiftLanguageModes:[.v6])
