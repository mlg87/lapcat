// swift-tools-version: 6.2
import PackageDescription

let rpath: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]

let libraries: [Target.Dependency] = ["LapCatCore", "LapCatSpeech", "LapCatLLM", "LapCatAudio"]

let package = Package(
    name: "LapCat",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "LapCat", targets: ["LapCatApp"]),
        .executable(name: "lapcat-dev", targets: ["lapcat-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4", traits: []),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
        .target(
            name: "LapCatCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/Templates"), .copy("Resources/Recipes.json")]
        ),
        .target(
            name: "LapCatSpeech",
            dependencies: ["whisper", .product(name: "FluidAudio", package: "FluidAudio"), "LapCatCore", "LapCatAudio"]
        ),
        .target(name: "LapCatAudio"),
        .target(name: "LapCatLLM", dependencies: ["LapCatCore"]),
        .executableTarget(name: "LapCatApp", dependencies: libraries, linkerSettings: rpath),
        .executableTarget(
            name: "lapcat-dev",
            dependencies: libraries,
            linkerSettings: rpath + [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"]),
            ]
        ),
        .testTarget(name: "LapCatCoreTests", dependencies: ["LapCatCore"]),
        .testTarget(name: "LapCatSpeechTests", dependencies: ["LapCatSpeech"]),
        .testTarget(name: "LapCatAudioTests", dependencies: ["LapCatAudio"]),
        .testTarget(name: "LapCatLLMTests", dependencies: ["LapCatLLM", "LapCatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
