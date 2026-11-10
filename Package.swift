// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "PlannerCore", targets: ["PlannerCore"]),
    .executable(name: "perch-cli", targets: ["PerchCLI"]),
]
var targets: [Target] = [
    .target(name: "PlannerCore", path: "Sources/PlannerCore"),
    .executableTarget(name: "PerchCLI", dependencies: ["PlannerCore"], path: "Sources/PerchCLI"),
    .testTarget(name: "PlannerCoreTests", dependencies: ["PlannerCore"], path: "Tests/PlannerCoreTests"),
]

#if os(macOS)
    products.append(.executable(name: "Perch", targets: ["Perch"]))
    targets.append(
        .executableTarget(
            name: "Perch",
            dependencies: ["PlannerCore"],
            path: "Sources/Perch",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("EventKit"),
                .linkedFramework("Speech"), .linkedFramework("AVFoundation"), .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"), .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        )
    )
#endif

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
