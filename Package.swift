// swift-tools-version:5.9
import PackageDescription

// PeterCore is Peter's logic (reading requests into templates, his model, Tool Mac Tool Run over
// HTTP, following runs, the schedule, the HTTP API): Foundation only, so it's tested on any
// machine (swift test). The menu bar app is only on the Mac.
var targets: [Target] = [
    .target(name: "PeterCore"),
    .testTarget(name: "PeterCoreTests", dependencies: ["PeterCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "Peter", dependencies: ["PeterCore"]))
#endif

let package = Package(name: "Peter", platforms: [.macOS(.v14)], targets: targets)
