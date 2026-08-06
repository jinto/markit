import XCTest
@testable import MarkdownSyntax

final class StyleSpanTests: XCTestCase {

    func testEquatable() {
        let a = StyleSpan(kind: .strong, role: .marker, range: 0..<2)
        let b = StyleSpan(kind: .strong, role: .marker, range: 0..<2)
        let c = StyleSpan(kind: .strong, role: .content, range: 0..<2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHeadingLevelIsPartOfIdentity() {
        XCTAssertNotEqual(
            StyleSpan(kind: .heading(level: 1), role: .content, range: 0..<5),
            StyleSpan(kind: .heading(level: 2), role: .content, range: 0..<5)
        )
    }

    func testLinkCarriesDestination() {
        let span = StyleSpan(kind: .link(destination: "https://example.com"),
                             role: .content, range: 1..<5)
        guard case .link(let dest) = span.kind else {
            return XCTFail("expected link kind")
        }
        XCTAssertEqual(dest, "https://example.com")
    }

    func testCodeBlockCarriesLanguage() {
        let span = StyleSpan(kind: .codeBlock(language: "swift"),
                             role: .content, range: 0..<10)
        guard case .codeBlock(let lang) = span.kind else {
            return XCTFail("expected codeBlock kind")
        }
        XCTAssertEqual(lang, "swift")
    }
}
