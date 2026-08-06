import XCTest
@testable import MarkdownSyntax

final class SourceOffsetMapTests: XCTestCase {

    func testASCIISingleLine() {
        let map = SourceOffsetMap(source: "ab **cd** ef")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 4), 3)   // '*' 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 13), 12) // 문서 끝
    }

    /// 회귀 방지의 핵심. column은 UTF-8 바이트인데 결과는 UTF-16이어야 한다.
    /// "한글 " = 7 UTF-8 바이트지만 UTF-16으로는 3 유닛이다.
    func testKoreanColumnIsUTF8ButResultIsUTF16() {
        let map = SourceOffsetMap(source: "한글 **볼드** 끝")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 8), 3)   // Strong 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 10), 5)  // 내부 Text 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 16), 7)  // 내부 Text 끝
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 18), 9)  // Strong 끝
    }

    /// 👨‍👩‍👧 = 1 Character, 8 UTF-16 유닛, 18 UTF-8 바이트.
    /// Character 단위 오프셋으로 구현하면 여기서 무너진다.
    func testEmojiGrapheme() {
        let map = SourceOffsetMap(source: "👨‍👩‍👧 **x** y")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 20), 9)  // Strong 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 22), 11) // 내부 Text 시작
    }

    func testMultipleLines() {
        let map = SourceOffsetMap(source: "one\ntwo\nthree")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 4)
        XCTAssertEqual(map.utf16Offset(line: 3, utf8Column: 1), 8)
        XCTAssertEqual(map.utf16Offset(line: 3, utf8Column: 6), 13)
    }

    func testMultilineWithKorean() {
        let map = SourceOffsetMap(source: "제목\n본문 텍스트")
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 3)  // "제목\n" = UTF-16 3
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 7), 5)  // "본문 " 뒤
    }

    func testCRLFLineEndings() {
        let map = SourceOffsetMap(source: "one\r\ntwo")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 5)  // "one\r\n" = 5 유닛
    }

    func testOutOfRangeReturnsNil() {
        let map = SourceOffsetMap(source: "abc")
        XCTAssertNil(map.utf16Offset(line: 0, utf8Column: 1))   // line은 1-based
        XCTAssertNil(map.utf16Offset(line: 99, utf8Column: 1))
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 0))   // column은 1-based
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 99))
    }

    /// 스칼라 중간을 가리키면 유효한 인덱스가 아니므로 nil이어야 한다.
    /// "한"은 3바이트이므로 column 2는 그 중간이다.
    func testMidScalarReturnsNil() {
        let map = SourceOffsetMap(source: "한글")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 2))
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 3))
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 4), 1)  // "글" 시작
    }

    func testEmptySource() {
        let map = SourceOffsetMap(source: "")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
    }
}
