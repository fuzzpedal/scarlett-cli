// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scarlett-audio",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "scarlett-audio", targets: ["ScarlettAudio"])
    ],
    targets: [
        .executableTarget(
            name: "ScarlettAudio",
            path: "Sources/ScarlettAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .testTarget(
            name: "ScarlettAudioTests",
            dependencies: ["ScarlettAudio"],
            path: "Tests/ScarlettAudioTests"
        )
    ]
)
