// swift-tools-version: 6.2
import PackageDescription

// Independent biology workbench. Hosts supply authorization, task/model services
// and the existing Linux execution transport; no host interpreter is exposed.
let package = Package(
    name: "FloeBiologyKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeBiologyCore", targets: ["FloeBiologyCore"]),
        .library(name: "FloeBiologyEngine", targets: ["FloeBiologyEngine"]),
        .library(name: "FloeBiologyUI", targets: ["FloeBiologyUI"]),
        .library(name: "FloeBiologyWorkerResources", targets: ["FloeBiologyWorkerResources"]),
        .library(name: "FloeBiologySamples", targets: ["FloeBiologySamples"])
    ],
    targets: [
        .target(name: "FloeBiologyCore"),
        .target(name: "FloeBiologyEngine", dependencies: ["FloeBiologyCore", "FloeBiologyWorkerResources"]),
        .target(name: "FloeBiologyUI", dependencies: ["FloeBiologyCore", "FloeBiologyEngine", "FloeBiologySamples"]),
        .target(name:"FloeBiologyWorkerResources",dependencies:["FloeBiologyCore"],path:"Backends",exclude:["README.md","test_science.py","test_extensions.py"],sources:["BiologyWorkerResources.swift"],resources:[
            .copy("biology_worker.py"),.copy("bio_common.py"),.copy("bio_sequence_structure.py"),.copy("bio_image_omics.py"),.copy("bio_network.py"),.copy("bio_sbml.py"),.copy("bio_tiff.py"),
            .copy("requirements.lock"),.copy("dependency-licenses.json"),.copy("verify_backend.py"),.copy("worker-manifest.json")
        ]),
        .target(
            name: "FloeBiologySamples",
            path: "Samples",
            exclude: ["README.md"],
            sources: ["BiologySamples.swift"],
            resources: [
                .copy("sample-index.json"),
                .copy("1ubq.pdb"),
                .copy("1ubq.cif"),
                .copy("synthetic-dna.fasta"),
                .copy("synthetic-counts.csv"),
                .copy("synthetic-microscopy.json"),
                .copy("synthetic-microscopy.pgm"),
                .copy("synthetic-network.json"),.copy("synthetic-tree.newick"),.copy("synthetic-density.mrc")
            ]
        ),
        .testTarget(name: "FloeBiologyCoreTests", dependencies: ["FloeBiologyCore", "FloeBiologySamples"]),
        .testTarget(name: "FloeBiologyEngineTests", dependencies: ["FloeBiologyEngine", "FloeBiologyCore", "FloeBiologySamples", "FloeBiologyWorkerResources"])
    ],
    swiftLanguageModes: [.v6]
)
