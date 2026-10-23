// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarPilot",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "BarPilot", targets: ["BarPilot"])],
    dependencies: [.package(path: "../Shared/AppLocalizationKit")],
    targets: [
        .target(name: "BarPilotCore", dependencies: [.product(name: "AppLocalizationKit", package: "AppLocalizationKit")], resources: [.process("Resources/Localization")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "BarPilotNative", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(
            name: "BarPilot", dependencies: ["BarPilotCore", "BarPilotNative"], exclude: ["Pro", "Automation"], swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "BarPilotCoreTests", dependencies: ["BarPilotCore"]),
        .testTarget(name: "BarPilotSessionTests", dependencies: ["BarPilot"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
