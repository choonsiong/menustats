// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MenuStats",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "MenuStats",
            path: "Sources/MenuStats",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
