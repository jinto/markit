import XCTest
@testable import MarkdownSyntax

/// 증분 경로가 전체 경로와 항상 같은 결과를 내는지 고정한다.
/// 설계 문서의 성능 리스크 완화가 이 테스트에 걸려 있다 — 블록 단위 재파싱으로
/// 최적화할 때 정확성을 지켜 주는 안전망이다.
final class IncrementalEquivalenceTests: XCTestCase {

    private let documents = [
        "# 제목\n\n본문 **강조** 텍스트\n\n- 항목 하나\n- 항목 둘\n",
        "**a** *b* `c`\n\n> quote\n\n```swift\nlet x = 1\n```\n",
        "한글 문서\n\n👨‍👩‍👧 이모지와 **강조**\n\n1. 하나\n2. 둘\n",
    ]

    func testRebuildMatchesFullBuildForWholeDocumentRange() {
        for source in documents {
            let full = MarkdownSyntaxMap.build(from: source)
            let incremental = MarkdownSyntaxMap.rebuild(
                source: source,
                changedUTF16Range: 0..<source.utf16.count
            )
            XCTAssertEqual(incremental, full, "원문: \(source.debugDescription)")
        }
    }

    func testRebuildMatchesFullBuildForEverySingleCharacterEdit() {
        for source in documents {
            let full = MarkdownSyntaxMap.build(from: source)
            let limit = source.utf16.count
            for offset in 0..<limit {
                let incremental = MarkdownSyntaxMap.rebuild(
                    source: source,
                    changedUTF16Range: offset..<min(offset + 1, limit)
                )
                XCTAssertEqual(
                    incremental, full,
                    "offset \(offset), 원문: \(source.debugDescription)"
                )
            }
        }
    }

    func testRebuildHandlesEmptyChangedRange() {
        let source = "# T\n\nbody\n"
        XCTAssertEqual(
            MarkdownSyntaxMap.rebuild(source: source, changedUTF16Range: 3..<3),
            MarkdownSyntaxMap.build(from: source)
        )
    }

    func testRebuildClampsOutOfBoundsRange() {
        let source = "# T\n"
        XCTAssertEqual(
            MarkdownSyntaxMap.rebuild(source: source, changedUTF16Range: 0..<9999),
            MarkdownSyntaxMap.build(from: source)
        )
    }

    func testRebuildOnEmptySource() {
        XCTAssertTrue(MarkdownSyntaxMap.rebuild(source: "", changedUTF16Range: 0..<0).isEmpty)
    }
}
