import XCTest
@testable import AppCore

final class CommandMatcherTests: XCTestCase {

    private let commands = [
        Command(id: "mode.wysiwyg", title: "WYSIWYG 모드"),
        Command(id: "mode.source", title: "소스 모드"),
        Command(id: "mode.split", title: "분할 모드"),
        Command(id: "file.open", title: "파일 열기"),
        Command(id: "file.save", title: "저장"),
        Command(id: "file.saveAs", title: "다른 이름으로 저장"),
    ]

    private func titles(_ query: String) -> [String] {
        CommandMatcher.match(query: query, in: commands).map(\.command.title)
    }

    func testEmptyQueryReturnsEverythingInOriginalOrder() {
        XCTAssertEqual(titles(""), commands.map(\.title))
    }

    func testMatchesSubsequenceNotOnlyPrefix() {
        XCTAssertTrue(titles("모드").contains("소스 모드"))
    }

    func testFiltersOutNonMatches() {
        XCTAssertEqual(titles("zzz"), [])
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(titles("wys").contains("WYSIWYG 모드"))
        XCTAssertTrue(titles("WYS").contains("WYSIWYG 모드"))
    }

    /// 짧고 정확한 것이 위로 와야 한다. "저장"을 치면 "저장"이 "다른 이름으로 저장"보다
    /// 먼저 나와야 쓸 만하다.
    func testExactShorterTitleRanksHigher() {
        XCTAssertEqual(titles("저장").first, "저장")
    }

    /// 붙어 있는 매치가 흩어진 매치보다 위여야 한다.
    func testContiguousMatchBeatsScattered() {
        let cs = [Command(id: "a", title: "분산 항 목"), Command(id: "b", title: "항목")]
        XCTAssertEqual(CommandMatcher.match(query: "항목", in: cs).first?.command.title, "항목")
    }

    func testReportsMatchedOffsetsForHighlighting() {
        let cs = [Command(id: "a", title: "저장")]
        XCTAssertEqual(CommandMatcher.match(query: "저장", in: cs)[0].matchedOffsets, [0, 1])
    }

    /// 한글·이모지가 섞여도 오프셋이 제목 안을 가리켜야 한다. 어긋나면 하이라이트가
    /// 엉뚱한 글자에 붙거나 앱이 죽는다 — Plan 1과 같은 좌표계 위험이다.
    func testMatchedOffsetsAreUTF16OffsetsIntoTitle() {
        let cs = [Command(id: "a", title: "🇰🇷 저장하기")]
        let match = CommandMatcher.match(query: "저장", in: cs)[0]
        let title = cs[0].title as NSString
        for offset in match.matchedOffsets {
            XCTAssertLessThan(offset, title.length)
        }
        let matched = match.matchedOffsets
            .map { title.substring(with: NSRange(location: $0, length: 1)) }
            .joined()
        XCTAssertEqual(matched, "저장")
    }

    func testQueryLongerThanTitleDoesNotMatch() {
        XCTAssertEqual(CommandMatcher.match(query: "저장하기입니다",
                                            in: [Command(id: "a", title: "저장")]).count, 0)
    }

    func testWhitespaceOnlyQueryReturnsEverything() {
        XCTAssertEqual(titles("   "), commands.map(\.title))
    }

    /// 동점이면 원래 등록 순서를 지켜야 한다. 순서가 흔들리면 같은 질의에 결과가
    /// 매번 달라 보인다.
    func testTiesKeepRegistrationOrder() {
        let cs = [Command(id: "a", title: "가나"), Command(id: "b", title: "가나")]
        XCTAssertEqual(CommandMatcher.match(query: "가나", in: cs).map(\.command.id), ["a", "b"])
    }
}
