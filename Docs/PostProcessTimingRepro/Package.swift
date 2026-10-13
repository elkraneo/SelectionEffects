// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PostProcessTimingRepro",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "PostProcessTimingRepro")]
)
