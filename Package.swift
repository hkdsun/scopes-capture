// swift-tools-version:5.10
// (5.10 tools ⇒ Swift 5 language mode; avoids strict-concurrency churn with ScreenCaptureKit callbacks.)
import PackageDescription

let package = Package(
    name: "ScopesCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScopesCapture",
            path: "Sources/ScopesCapture"
        )
    ]
)
