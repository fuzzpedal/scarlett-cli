// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scarlett-audio",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "scarlett-audio", targets: ["ScarlettAudio"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "ScarlettAudio",
            dependencies: ["CLibUSB"],
            path: "Sources/ScarlettAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .testTarget(
            name: "ScarlettAudioTests",
            dependencies: ["ScarlettAudio", "CLibUSB"],
            path: "Tests/ScarlettAudioTests"
        )
    ]
)
