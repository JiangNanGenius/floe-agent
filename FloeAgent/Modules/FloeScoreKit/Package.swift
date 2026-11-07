// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package=Package(name:"FloeScoreKit",platforms:[.iOS(.v26),.macOS(.v15)],
    products:[.library(name:"FloeScoreKit",targets:["FloeScoreKit"])],
    dependencies:[.package(path:"../FloeHeavyEditorSupport")],
    targets:[.target(name:"FloeScoreKit",dependencies:["FloeHeavyEditorSupport"],resources:[.copy("Resources/Web")]),.executableTarget(name:"ScoreWebQualification",dependencies:["FloeScoreKit"],path:"Qualification"),.testTarget(name:"FloeScoreKitTests",dependencies:["FloeScoreKit"],path:"Tests/Native")],swiftLanguageModes:[.v6])
