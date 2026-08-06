// swift-tools-version: 5.9
import PackageDescription

// Markit — a native macOS Markdown editor.
//
// The headless layers live here as library targets so they can be tested from
// the command line with `swift test`, with no UI in the loop. The AppKit/SwiftUI
// app target is added later (see docs/superpowers/specs) and depends on these.
let package = Package(
    name: "Markit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownSyntax", targets: ["MarkdownSyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "MarkdownSyntax",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(
            name: "MarkdownSyntaxTests",
            dependencies: ["MarkdownSyntax"]
        ),
    ]
)
