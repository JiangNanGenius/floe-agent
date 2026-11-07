// swift-tools-version: 6.2
import PackageDescription
// Internal qualification only: includes GPL-bearing PDF backend source.
// This product must not be added to the MPL-2.0 App distribution.
let package=Package(name:"FloeLaTeXNativeExperiment",platforms:[.iOS(.v26),.macOS(.v15)],products:[.library(name:"FloeLaTeXNativeExperiment",type:.dynamic,targets:["FloeLaTeXNativeExperiment"])],dependencies:[.package(name:"FloeLaTeXKit",path:"../..")],targets:[
    .binaryTarget(name:"FloeTeXNative",path:"Vendor/FloeTeXNative.xcframework"),
    .target(name:"FloeLaTeXNativeExperiment",dependencies:[.product(name:"FloeLaTeXKit",package:"FloeLaTeXKit"),.target(name:"FloeTeXNative",condition:.when(platforms:[.iOS]))],linkerSettings:[.linkedLibrary("c++",.when(platforms:[.iOS])),.linkedLibrary("iconv",.when(platforms:[.iOS])),.linkedLibrary("z",.when(platforms:[.iOS])),.linkedFramework("CoreText",.when(platforms:[.iOS])),.linkedFramework("CoreGraphics",.when(platforms:[.iOS])),.linkedFramework("Security",.when(platforms:[.iOS])),.linkedFramework("SystemConfiguration",.when(platforms:[.iOS]))])
],swiftLanguageModes:[.v6])
