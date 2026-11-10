// SPDX-License-Identifier: MPL-2.0
use std::env;
fn main() {
    let target = env::var("TARGET").expect("TARGET");
    assert!(
        target.contains("apple-ios"),
        "This product is the Apple iOS XDV backend"
    );
    let includes =
        env::var("DEP_FREETYPE2_INCLUDE_PATH").expect("Actual FreeType dependency headers");
    let mut legacy = cc::Build::new();
    for p in includes.split(';') {
        legacy.include(p);
    }
    legacy
        .include("../apple")
        .file("../apple/FloeTeXLegacyOutline.c")
        .compile("floe_tex_legacy_outline");
    cc::Build::new()
        .include("../apple")
        .file("../apple/FloeTeXAppleMetadata.m")
        .flag("-fobjc-arc")
        .compile("floe_tex_apple_metadata");
    for framework in ["Foundation", "CoreGraphics", "CoreText", "ImageIO"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    for file in [
        "FloeTeXLegacyOutline.h",
        "FloeTeXLegacyOutline.c",
        "FloeTeXAppleMetadata.h",
        "FloeTeXAppleMetadata.m",
    ] {
        println!("cargo:rerun-if-changed=../apple/{file}");
    }
}
