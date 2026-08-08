import XCTest
import AppKit
@testable import EditorKit

final class EditorTextViewTests: XCTestCase {

    private func view(_ text: String = "") -> EditorTextView {
        let v = EditorTextView()
        v.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        if !text.isEmpty { v.setMarkdown(text) }
        return v
    }

    private func isHidden(_ v: EditorTextView, at i: Int) -> Bool {
        let f = v.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        return (f?.pointSize ?? 99) < 1.0
    }

    private func appendTyping(_ v: EditorTextView, _ text: String) {
        for ch in text {
            v.insertText(String(ch),
                         replacementRange: NSRange(location: v.string.utf16.count, length: 0))
        }
    }

    private func offset(of needle: String, in source: String) -> Int {
        (source as NSString).range(of: needle).location
    }

    // MARK: - TextKit 2 회귀 방어

    /// `layoutManager`를 어디선가 읽으면 조용히 TextKit 1으로 강등된다. 예외도 경고도
    /// 없이 일어나고 앱은 그냥 동작하므로 한참 뒤에 성능·레이아웃 이상으로만 드러난다.
    func testUsesTextKit2AfterConstruction() {
        XCTAssertNotNil(view().textLayoutManager)
    }

    func testUsesTextKit2AfterTypingAndRestyling() {
        let v = view("# 제목\n")
        appendTyping(v, "본문")
        v.restyleNow()
        XCTAssertNotNil(v.textLayoutManager, "타이핑/재스타일 경로가 TextKit 1으로 떨어뜨렸다")
    }

    // MARK: - 편집이 스타일을 갱신한다

    func testTypingAppliesStyling() {
        let v = view()
        appendTyping(v, "# 제목")
        v.restyleNow()
        let titleSize = (v.textStorage?.attribute(
            .font, at: offset(of: "제목", in: v.string), effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        XCTAssertGreaterThan(titleSize, Theme.default.bodyFont.pointSize,
                             "타이핑한 헤딩이 커져야 한다")
    }

    func testSetMarkdownReplacesTextAndStyles() {
        let v = view("# 처음\n")
        v.setMarkdown("**나중**\n둘째 줄")
        v.restyleNow()
        XCTAssertEqual(v.string, "**나중**\n둘째 줄")
        // setMarkdown은 선택을 문서 맨 앞으로 되돌린다 (파일을 새로 여는 것이므로).
        // 따라서 첫 줄이 활성이고 그 줄의 마커는 노출된다.
        XCTAssertEqual(v.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(isHidden(v, at: 0), "활성 줄의 마커는 보인다")
        XCTAssertTrue(isHidden(v, at: offset(of: "**나중**", in: v.string)) == false)
    }

    func testOnTextChangeFiresOnTyping() {
        let v = view()
        var seen: [String] = []
        v.onTextChange = { seen.append($0) }
        v.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(seen.last, "x")
    }

    func testOnTextChangeDoesNotFireForStylingOnly() {
        // 속성 적용은 .editedCharacters를 안 낸다. 여기서 못 박는다 —
        // 스타일링이 문서 변경으로 보고되면 dirty 플래그가 오염되고 저장 표시가 거짓이 된다.
        let v = view("# 제목\n")
        var count = 0
        v.onTextChange = { _ in count += 1 }
        v.restyleNow()
        v.restyleNow()
        XCTAssertEqual(count, 0)
    }

    func testSetMarkdownDoesNotReportAsUserEdit() {
        // 외부 리로드로 버퍼를 갈아끼울 때 onTextChange가 불리면 무한 루프가 된다:
        // 리로드 → onTextChange → 문서가 dirty → 저장 → 파일 변경 → 리로드.
        let v = view("처음")
        var count = 0
        v.onTextChange = { _ in count += 1 }
        v.setMarkdown("에이전트가 쓴 내용")
        XCTAssertEqual(count, 0, "프로그램이 바꾼 내용은 사용자 편집이 아니다")
    }

    // MARK: - 커서 이동이 마커 노출을 바꾼다

    func testMovingCaretRevealsAndHidesMarkers() {
        let source = "**굵게**\n둘째 줄"
        let v = view(source)
        v.setSelectedRange(NSRange(location: offset(of: "둘째", in: source), length: 0))
        v.restyleNow()
        XCTAssertTrue(isHidden(v, at: 0))

        v.setSelectedRange(NSRange(location: 1, length: 0))
        v.restyleNow()
        XCTAssertFalse(isHidden(v, at: 0), "커서가 온 줄의 마커가 드러나야 한다")
    }

    /// 같은 줄 안에서 커서만 움직이면 재스타일이 필요 없다. 화살표 연타마다 전체
    /// 재파싱을 하면 큰 문서에서 커서가 끈적해진다.
    ///
    /// 패스 횟수만 보면 이 테스트는 공허하다 — 재스타일은 어차피 비동기라 동기적으로는
    /// 늘지 않는다. 그래서 **예약되었는지**를 본다.
    func testCaretMoveWithinSameLineSchedulesNothing() {
        let v = view("**굵게** 그리고 더 긴 첫 줄\n둘째 줄")
        v.setSelectedRange(NSRange(location: 2, length: 0))
        v.restyleNow()
        XCTAssertFalse(v.hasPendingRestyleForTesting, "출발점이 깨끗해야 한다")

        v.setSelectedRange(NSRange(location: 3, length: 0))
        v.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertFalse(v.hasPendingRestyleForTesting,
                       "같은 줄 안 이동은 마커 노출을 바꾸지 않는다")
    }

    func testCaretMoveToAnotherLineSchedulesRestyle() {
        let source = "**굵게**\n둘째 줄"
        let v = view(source)
        v.restyleNow()
        XCTAssertFalse(v.hasPendingRestyleForTesting)

        v.setSelectedRange(NSRange(location: offset(of: "둘째", in: source), length: 0))
        XCTAssertTrue(v.hasPendingRestyleForTesting, "줄이 바뀌면 재스타일해야 한다")
    }

    // MARK: - 합침

    func testRapidTypingDefersRestyleInsteadOfSkippingIt() {
        let v = view("# 제목\n")
        v.restyleNow()
        let passes = v.restylePassCountForTesting

        appendTyping(v, "abcdefghij")

        XCTAssertEqual(v.restylePassCountForTesting, passes,
                       "글자마다 즉시 재스타일하면 안 된다 — 32KB에서 키당 15ms다")
        XCTAssertTrue(v.hasPendingRestyleForTesting,
                      "미루기만 하고 예약이 없으면 화면이 영원히 갱신되지 않는다")
    }

    func testScheduledRestyleEventuallyRuns() {
        let v = view("# 제목\n")
        v.restyleNow()
        let passes = v.restylePassCountForTesting
        appendTyping(v, "**굵게**")

        // 예약된 재스타일은 다음 런루프에 돈다. 실제로 도는지 확인한다 —
        // 합침이 "영원히 미룸"이 되면 화면이 갱신되지 않는다.
        let ran = expectation(description: "예약된 재스타일 실행")
        DispatchQueue.main.async {
            DispatchQueue.main.async { ran.fulfill() }
        }
        wait(for: [ran], timeout: 2)
        XCTAssertGreaterThan(v.restylePassCountForTesting, passes)
    }

    // MARK: - 원문 불변

    func testStylingNeverChangesText() {
        let source = "# 한글 제목\n**굵게** `코드` 🇰🇷\n- 항목\n"
        let v = view(source)
        v.restyleNow()
        v.setSelectedRange(NSRange(location: 3, length: 0))
        v.restyleNow()
        XCTAssertEqual(v.string, source)
    }

    /// 상위(앱)가 델리게이트를 쓸 수 있어야 한다. 자기 자신을 델리게이트로 삼으면
    /// `MarkdownDocument`를 연결할 자리가 없어진다.
    func testDelegateIsAvailableToOwner() {
        let v = view("# 제목")
        XCTAssertNil(v.delegate, "델리게이트 자리는 상위에게 비워 둬야 한다")
    }
}
