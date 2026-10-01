// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Text structure — retraction, spoken commands, lists, email shape, and the guard
        // for the grammar-repair pass. Platform-neutral for the same reason the dictionary
        // is: the behaviour is a contract, the vectors in shared/ are the contract, and a
        // pass that can only be exercised by talking into a Mac is a pass nothing checks.
        .target(
            name: "MurmurFormatting",
            path: "Sources/MurmurFormatting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Microphone and system-audio capture. Its own target so the device-recovery logic
        // can be checked without the app, and so `MurmurAudioCheck` can drive the real
        // capture against real hardware — the only way a Bluetooth bug is ever reproduced.
        .target(
            name: "MurmurAudio",
            path: "Sources/MurmurAudio",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // `swift run MurmurAudioCheck` — the device-recovery checks (no hardware, runs in
        // CI) and, with `--hardware`, live capture against the Mac's actual devices.
        // An executable rather than a test target because swift-testing ships with Xcode,
        // and this has to run on a machine with only the Command Line Tools.
        .executableTarget(
            name: "MurmurAudioCheck",
            dependencies: ["MurmurAudio"],
            path: "Sources/MurmurAudioCheck",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurDictionary",
                "MurmurFormatting",
                "MurmurAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MurmurDictionaryTests",
            dependencies: ["MurmurDictionary"],
            path: "Tests/MurmurDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurFormattingTests",
            dependencies: ["MurmurFormatting"],
            path: "Tests/MurmurFormattingTests",
            resources: [.copy("formatting-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
