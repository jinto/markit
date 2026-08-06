import XCTest
@testable import MarkdownSyntax

final class MarkdownSyntaxMapTests: XCTestCase {

    func testEmptySourceProducesNoSpans() {
        XCTAssertTrue(MarkdownSyntaxMap.build(from: "").isEmpty)
    }

    func testSpansAreSortedByOffset() {
        let spans = MarkdownSyntaxMap.build(from: "# T\n\n**a** *b* `c`")
        let lowers = spans.map(\.range.lowerBound)
        XCTAssertEqual(lowers, lowers.sorted(), "스팬은 오프셋 오름차순이어야 한다")
    }

    func testNoSpanExceedsSourceLength() {
        let source = "# 제목\n\n**볼드** 그리고 `코드` 끝\n\n- 항목\n"
        let limit = source.utf16.count
        for span in MarkdownSyntaxMap.build(from: source) {
            XCTAssertLessThanOrEqual(span.range.upperBound, limit,
                                     "스팬이 원문 길이를 넘었다: \(span)")
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0)
        }
    }

    func testNoEmptySpans() {
        let source = "# T\n\nTitle\n=====\n\n- a\n"
        XCTAssertFalse(MarkdownSyntaxMap.build(from: source).contains { $0.range.isEmpty })
    }

    /// 결정성 — 같은 입력이면 같은 출력. 순수 함수의 정의다.
    func testDeterministic() {
        let source = "# 제목\n\n**볼드**와 *이탤릭*, `코드`\n\n> 인용\n\n1. 하나\n2. 둘\n"
        XCTAssertEqual(MarkdownSyntaxMap.build(from: source),
                       MarkdownSyntaxMap.build(from: source))
    }

    /// 이 레이어는 원문을 읽기만 한다. 재직렬화하지 않는다 (AD-2).
    /// 다양한 문서에서 크래시 없이, 범위를 넘지 않는 스팬을 내는지 확인한다.
    func testHandlesVariedCorpusWithoutCrashing() {
        let corpus = [
            "",
            "\n",
            "plain",
            "# h1\n## h2\n### h3\n",
            "**bold** *it* ***both*** `code`\n",
            "- a\n- b\n  - nested\n",
            "1. one\n2. two\n",
            "> quote\n> more\n",
            "```\nplain fence\n```\n",
            "```swift\nlet x = 1\n```\n",
            "    indented code\n",
            "[link](http://a.b) and ![img](c.png)\n",
            "| a | b |\n|---|---|\n| 1 | 2 |\n",
            "한글 문서 **강조** 및 `코드`\n",
            "👨‍👩‍👧 이모지 **강조**\n",
            "line one\r\nline two\r\n",
            "trailing spaces   \n\nand blank lines\n\n\n",
            "\\*escaped\\* not emphasis\n",
        ]
        for source in corpus {
            let spans = MarkdownSyntaxMap.build(from: source)
            let limit = source.utf16.count
            for span in spans {
                XCTAssertLessThanOrEqual(span.range.upperBound, limit,
                                         "범위 초과 — 원문: \(source.debugDescription)")
                XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0,
                                            "음수 오프셋 — 원문: \(source.debugDescription)")
            }
        }
    }
}
