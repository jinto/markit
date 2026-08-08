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
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
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
        // 파일 상태 레이어. MarkdownSyntax에 의존하지 않는다 — 두 레이어는 독립이고
        // 조립은 상위(앱)에서 한다.
        .target(name: "DocumentCore"),
        .testTarget(
            name: "DocumentCoreTests",
            dependencies: ["DocumentCore"]
        ),
        // UI 레이어. AppKit을 쓰므로 위 두 타깃의 헤드리스 규칙이 적용되지 않는다.
        // 그래도 앱 번들 없이 `swift test`로 전부 검증된다 (계획서 사실 1번).
        .target(name: "EditorKit", dependencies: ["MarkdownSyntax"]),
        .testTarget(
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        ),
    ]
)
