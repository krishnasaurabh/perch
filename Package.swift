// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "PlannerCore", targets: ["PlannerCore"]),
    .library(name: "PerchMCP", targets: ["PerchMCP"]),
    .library(name: "PerchUI", targets: ["PerchUI"]),
    .executable(name: "perch-cli", targets: ["PerchCLI"]),
]
let localizationResources: [Resource] = [.copy("Resources/Localizable.json")]
let localizationExcludes = ["Resources/Localizable.xcstrings"]

var targets: [Target] = [
    // Dependencies flow inward: neither storage nor domain rules know about transport or presentation.
    .target(name: "PlannerCore"),
    .target(name: "PerchMCP", dependencies: ["PlannerCore"]),
    .target(
        name: "PerchUI", dependencies: ["PlannerCore"],
        exclude: localizationExcludes,
        resources: localizationResources + [.copy("Resources/Fonts")]
    ),
    .target(name: "PerchReminders", dependencies: ["PlannerCore"]),
    .testTarget(name: "PerchRemindersTests", dependencies: ["PerchReminders", "PlannerCore"]),
    .executableTarget(name: "PerchCLI", dependencies: ["PlannerCore", "PerchMCP"]),
    .target(name: "PlannerTestSupport", dependencies: ["PlannerCore"], path: "Tests/PlannerTestSupport"),
    .testTarget(name: "PlannerCoreTests", dependencies: ["PlannerCore", "PlannerTestSupport"]),
    .testTarget(name: "PerchMCPTests", dependencies: ["PlannerCore", "PerchMCP", "PlannerTestSupport"]),
    .testTarget(name: "PerchUITests", dependencies: ["PlannerCore", "PerchUI", "PlannerTestSupport"]),
]

#if os(macOS)
    products.append(.library(name: "PerchApp", targets: ["PerchApp"]))
    products.append(.executable(name: "Perch", targets: ["Perch"]))
    targets.append(
        .target(
            name: "PerchApp",
            dependencies: ["PlannerCore", "PerchMCP", "PerchUI", "PerchReminders"],
            exclude: localizationExcludes,
            resources: localizationResources,
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("EventKit"),
                .linkedFramework("Speech"), .linkedFramework("AVFoundation"), .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"), .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        )
    )
    targets.append(.executableTarget(name: "Perch", dependencies: ["PerchApp"]))
    targets.append(
        .testTarget(name: "PerchAppTests", dependencies: ["PerchApp", "PerchUI", "PlannerCore"]))
#endif

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
