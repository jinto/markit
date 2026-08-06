import XCTest
import Markdown
@testable import MarkdownSyntax

final class SpanCollectorTests: XCTestCase {

    /// 테스트 헬퍼. 원문을 파싱해 스팬을 낸다.
    private func spans(_ source: String) -> [StyleSpan] {
        let doc = Document(parsing: source)
        var collector = SpanCollector(offsetMap: SourceOffsetMap(source: source), source: source)
        return collector.collect(from: doc)
    }

    private func span(_ spans: [StyleSpan], kind: StyleSpan.Kind, role: StyleSpan.Role) -> StyleSpan? {
        spans.first { $0.kind == kind && $0.role == role }
    }

    private func ranges(_ spans: [StyleSpan], where match: (StyleSpan) -> Bool) -> [Range<Int>] {
        spans.filter(match).map(\.range).sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: - 헤딩

    func testATXHeadingMarkerAndContent() {
        let result = spans("# Heading one")
        // "# " 가 마커, "Heading one" 이 내용
        XCTAssertEqual(span(result, kind: .heading(level: 1), role: .marker)?.range, 0..<2)
        XCTAssertEqual(span(result, kind: .heading(level: 1), role: .content)?.range, 2..<13)
    }

    func testHeadingLevelIsCaptured() {
        let result = spans("### Third")
        XCTAssertEqual(span(result, kind: .heading(level: 3), role: .marker)?.range, 0..<4)
        XCTAssertEqual(span(result, kind: .heading(level: 3), role: .content)?.range, 4..<9)
    }

    // MARK: - 인라인 강조

    func testStrongMarkersOnBothSides() {
        let result = spans("ab **cd** ef")
        XCTAssertEqual(ranges(result) { $0.kind == .strong && $0.role == .marker },
                       [3..<5, 7..<9])
        XCTAssertEqual(span(result, kind: .strong, role: .content)?.range, 5..<7)
    }

    func testEmphasis() {
        let result = spans("a *b* c")
        XCTAssertEqual(ranges(result) { $0.kind == .emphasis && $0.role == .marker },
                       [2..<3, 4..<5])
        XCTAssertEqual(span(result, kind: .emphasis, role: .content)?.range, 3..<4)
    }

    /// 회귀 방지의 핵심. 한글에서도 마커 범위가 UTF-16으로 정확해야 한다.
    func testKoreanStrongRangesAreUTF16() {
        let result = spans("한글 **볼드** 끝")
        XCTAssertEqual(ranges(result) { $0.kind == .strong && $0.role == .marker },
                       [3..<5, 7..<9])
        XCTAssertEqual(span(result, kind: .strong, role: .content)?.range, 5..<7)
    }

    func testNestedEmphasisInsideStrong() {
        let result = spans("**a *b* c**")
        XCTAssertEqual(result.filter { $0.kind == .strong && $0.role == .marker }.count, 2)
        XCTAssertEqual(result.filter { $0.kind == .emphasis && $0.role == .marker }.count, 2)
    }

    // MARK: - 링크

    func testLinkCapturesDestinationAndMarkers() {
        let result = spans("[link](https://example.com)")
        let content = result.first {
            if case .link = $0.kind, $0.role == .content { return true }
            return false
        }
        XCTAssertEqual(content?.range, 1..<5)  // "link"
        guard case .link(let dest)? = content?.kind else {
            return XCTFail("expected link kind with destination")
        }
        XCTAssertEqual(dest, "https://example.com")

        // "[" 와 "](https://example.com)"
        XCTAssertEqual(ranges(result) {
            if case .link = $0.kind, $0.role == .marker { return true }
            return false
        }, [0..<1, 5..<27])
    }

    // MARK: - 코드 (자식이 없는 노드)

    func testInlineCodeSingleBacktick() {
        let result = spans("a `code` b")
        XCTAssertEqual(ranges(result) { $0.kind == .inlineCode && $0.role == .marker },
                       [2..<3, 7..<8])
        XCTAssertEqual(span(result, kind: .inlineCode, role: .content)?.range, 3..<7)
    }

    func testInlineCodeDoubleBacktick() {
        let result = spans("a ``co`de`` b")
        XCTAssertEqual(ranges(result) { $0.kind == .inlineCode && $0.role == .marker },
                       [2..<4, 9..<11])
        XCTAssertEqual(span(result, kind: .inlineCode, role: .content)?.range, 4..<9)
    }

    func testFencedCodeBlockCapturesLanguageAndFences() {
        let result = spans("```swift\nlet x = 1\n```")
        let content = result.first {
            if case .codeBlock = $0.kind, $0.role == .content { return true }
            return false
        }
        guard case .codeBlock(let lang)? = content?.kind else {
            return XCTFail("expected codeBlock kind")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(content?.range, 9..<19)  // "let x = 1\n"

        // "```swift\n" 와 "```"
        XCTAssertEqual(ranges(result) {
            if case .codeBlock = $0.kind, $0.role == .marker { return true }
            return false
        }, [0..<9, 19..<22])
    }

    func testIndentedCodeBlockHasNoFenceMarkers() {
        let result = spans("    indented\n")
        XCTAssertTrue(ranges(result) {
            if case .codeBlock = $0.kind, $0.role == .marker { return true }
            return false
        }.isEmpty)
    }

    // MARK: - 일반

    /// 빈 마커 범위는 버려야 한다. Setext 헤딩은 여는 마커가 없다.
    func testEmptyMarkerRangesAreDropped() {
        let result = spans("Title\n=====")
        XCTAssertFalse(result.contains { $0.range.isEmpty })
    }

    func testPlainTextProducesNoSpans() {
        XCTAssertTrue(spans("just plain text").isEmpty)
    }
}
