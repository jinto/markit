import XCTest
import AppKit
@testable import EditorKit
@testable import MarkdownSyntax

final class LiveStyleApplierTests: XCTestCase {

    private let applier = LiveStyleApplier()

    /// 원문을 넣고 실제 스팬으로 스타일을 입힌 스토리지를 돌려준다.
    private func styled(_ source: String, caretAt caret: Int) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        applier.apply(spans: MarkdownSyntaxMap.build(from: source),
                      selection: NSRange(location: caret, length: 0),
                      to: storage)
        return storage
    }

    private func fontSize(_ storage: NSTextStorage, at i: Int) -> CGFloat {
        (storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
    }

    private func isHidden(_ storage: NSTextStorage, at i: Int) -> Bool {
        fontSize(storage, at: i) < 1.0
    }

    private func offset(of needle: String, in source: String) -> Int {
        (source as NSString).range(of: needle).location
    }

    // MARK: - 원문 불변 (AD-2의 핵심 계약)

    func testSourceTextIsNeverModified() {
        let source = "# 제목\n**굵게** 그리고 `코드`\n- 항목\n> 인용\n"
        let storage = styled(source, caretAt: 0)
        XCTAssertEqual(storage.string, source,
                       "스타일링은 속성만 입힌다. 원문이 바뀌면 무손실 왕복이 깨진다")
    }

    // MARK: - 마커 노출 정책 (줄 기준)

    func testMarkersHiddenWhenCaretOnAnotherLine() {
        let source = "**굵게**\n둘째 줄"
        let storage = styled(source, caretAt: offset(of: "둘째", in: source))
        XCTAssertTrue(isHidden(storage, at: 0), "다른 줄에 커서가 있으면 앞 ** 숨김")
        XCTAssertTrue(isHidden(storage, at: 4), "뒤 ** 도 숨김")
        XCTAssertFalse(isHidden(storage, at: 2), "내용은 숨기지 않는다")
    }

    func testMarkersRevealedWhenCaretOnSameLine() {
        let storage = styled("**굵게**\n둘째 줄", caretAt: 3)
        XCTAssertFalse(isHidden(storage, at: 0), "같은 줄이면 마커를 보여준다")
        XCTAssertFalse(isHidden(storage, at: 4))
    }

    func testRevealedMarkerIsDimmedNotPlain() {
        let storage = styled("**굵게**", caretAt: 1)
        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, Theme.default.markerColor,
                       "노출된 마커는 흐린 색이어야 한다 — 본문색이면 안 된다")
    }

    func testMultiLineSelectionRevealsAllTouchedLines() {
        let source = "**하나**\n**둘**\n**셋**"
        let storage = NSTextStorage(string: source)
        // 첫째~둘째 줄에 걸친 선택
        applier.apply(spans: MarkdownSyntaxMap.build(from: source),
                      selection: NSRange(location: 2, length: 8), to: storage)
        XCTAssertFalse(isHidden(storage, at: 0), "선택이 닿은 줄은 노출")
        XCTAssertTrue(isHidden(storage, at: offset(of: "**셋**", in: source)),
                      "닿지 않은 줄은 숨김")
    }

    // MARK: - 늘 보이는 마커

    func testCodeFenceMarkerIsNeverHidden() {
        let source = "```swift\nlet x = 1\n```\n\n본문"
        let storage = styled(source, caretAt: offset(of: "본문", in: source))
        XCTAssertFalse(isHidden(storage, at: 0),
                       "펜스는 커서가 멀어도 보인다 — 언어 표시를 겸한다")
    }

    func testListAndQuoteMarkersAreNeverHidden() {
        let source = "- 항목\n> 인용\n\n본문"
        let storage = styled(source, caretAt: offset(of: "본문", in: source))
        XCTAssertFalse(isHidden(storage, at: 0), "리스트 마커는 보인다")
        XCTAssertFalse(isHidden(storage, at: offset(of: ">", in: source)),
                       "인용 마커는 보인다")
    }

    // MARK: - 내용 스타일

    func testHeadingContentIsLargerThanBody() {
        let source = "# 제목\n\n본문"
        let storage = styled(source, caretAt: offset(of: "본문", in: source))
        XCTAssertGreaterThan(fontSize(storage, at: offset(of: "제목", in: source)),
                             fontSize(storage, at: offset(of: "본문", in: source)))
    }

    func testStrongInsideHeadingKeepsHeadingSize() {
        // 폰트를 덮어쓰지 않고 합성하는지 — 겹침 처리의 핵심
        let source = "## **굵은** 제목"
        let storage = styled(source, caretAt: 0)
        let strongFont = storage.attribute(
            .font, at: offset(of: "굵은", in: source), effectiveRange: nil) as! NSFont
        XCTAssertEqual(strongFont.pointSize, fontSize(storage, at: offset(of: "제목", in: source)),
                       "strong이 헤딩 크기를 덮어쓰면 안 된다")
        XCTAssertTrue(strongFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testEmphasisIsItalicForLatinText() {
        let source = "*slanted*"
        let storage = styled(source, caretAt: 0)
        let f = storage.attribute(
            .font, at: offset(of: "slanted", in: source), effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.italic))
    }

    /// 한글에는 이탤릭 페이스가 없다. 비트맵으로 확인했다 — 한글에 이탤릭 폰트를 지정하면
    /// 보통 글자와 **픽셀까지 동일하게** 그려진다. 강조가 아무 표시 없이 사라지는 것을
    /// 막으려면 기울기를 직접 줘야 한다.
    func testEmphasisFallsBackToObliquenessForKorean() {
        let source = "*기울임*"
        let storage = styled(source, caretAt: 0)
        let obliqueness = storage.attribute(
            .obliqueness, at: offset(of: "기울임", in: source), effectiveRange: nil) as? Double
        XCTAssertEqual(obliqueness, LiveStyleApplier.syntheticObliqueness,
                       "한글 강조가 시각적으로 구분되지 않으면 강조가 아니다")
    }

    func testEmphasisDoesNotDoubleSlantLatinText() {
        let source = "*slanted*"
        let storage = styled(source, caretAt: 0)
        XCTAssertNil(storage.attribute(.obliqueness,
                                       at: offset(of: "slanted", in: source),
                                       effectiveRange: nil),
                     "진짜 이탤릭이 있는 글자에 기울기를 덧붙이면 두 번 기울어진다")
    }

    func testInlineCodeUsesMonospacedFontForLatinText() {
        let source = "`let x = 1`"
        let storage = styled(source, caretAt: 0)
        let f = storage.attribute(
            .font, at: offset(of: "let", in: source), effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.isFixedPitch)
    }

    /// macOS에는 한글을 그릴 수 있는 고정폭 시스템 폰트가 없다 (Menlo·Monaco는 한글
    /// 미포함, Apple SD Gothic Neo는 고정폭 아님). `NSTextStorage`가 폰트를 치환하므로
    /// **한글 코드는 고정폭으로 보이지 않는다.** 배경색이 유일한 신호이므로 그것을 고정한다.
    func testInlineCodeIsMarkedByBackgroundColor() {
        let source = "`코드`"
        let storage = styled(source, caretAt: 0)
        let background = storage.attribute(
            .backgroundColor, at: offset(of: "코드", in: source), effectiveRange: nil) as? NSColor
        XCTAssertEqual(background, Theme.default.codeBackgroundColor)
    }

    func testStrongSurvivesForKoreanText() {
        // 굵기는 한글에서도 살아남는다 (AppleSDGothicNeo-Bold로 치환된다).
        // 이탤릭과 달리 대책이 필요 없다는 것을 못 박아 둔다.
        let source = "**굵게**"
        let storage = styled(source, caretAt: 0)
        let f = storage.attribute(
            .font, at: offset(of: "굵게", in: source), effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: - 줄 높이 붕괴 방지

    func testEveryParagraphHasMinimumLineHeight() {
        let storage = styled("# 제목\n\n본문\n```\n코드\n```\n", caretAt: 0)
        storage.enumerateAttribute(.paragraphStyle,
                                   in: NSRange(location: 0, length: storage.length),
                                   options: []) { value, range, _ in
            guard let ps = value as? NSParagraphStyle else {
                return XCTFail("range \(range)에 문단 스타일이 없다")
            }
            XCTAssertEqual(ps.minimumLineHeight, Theme.default.minimumLineHeight,
                           "마커만 있는 줄이 높이 0으로 붕괴하는 것을 막는다")
        }
    }

    // MARK: - 다시 적용해도 잔여물이 없어야 한다

    func testReapplyingClearsPreviousStyling() {
        let source = "**굵게**\n둘째 줄"
        let storage = NSTextStorage(string: source)
        let spans = MarkdownSyntaxMap.build(from: source)
        // 커서를 첫 줄에 두어 마커를 노출시킨 뒤
        applier.apply(spans: spans, selection: NSRange(location: 1, length: 0), to: storage)
        XCTAssertFalse(isHidden(storage, at: 0))
        // 둘째 줄로 옮기면 다시 숨어야 한다
        applier.apply(spans: spans,
                      selection: NSRange(location: offset(of: "둘째", in: source), length: 0),
                      to: storage)
        XCTAssertTrue(isHidden(storage, at: 0), "이전 패스의 노출 상태가 남으면 안 된다")
    }

    // MARK: - 좌표계 안전 (Plan 1과 같은 위험)

    func testHandlesKoreanAndEmojiWithoutRangeError() {
        let source = "# 한글 제목 🇰🇷\n**굵게** 이모지 👨‍👩‍👧‍👦 그리고 `코드`\n"
        let storage = NSTextStorage(string: source)
        applier.apply(spans: MarkdownSyntaxMap.build(from: source),
                      selection: NSRange(location: 0, length: 0), to: storage)
        XCTAssertEqual(storage.string, source)
    }

    // MARK: - 정책 교체 (소스 모드)

    func testRevealAllPolicyNeverHidesMarkers() {
        let source = "**굵게**\n둘째 줄"
        let storage = NSTextStorage(string: source)
        LiveStyleApplier(markerPolicy: .revealAll).apply(
            spans: MarkdownSyntaxMap.build(from: source),
            selection: NSRange(location: offset(of: "둘째", in: source), length: 0),
            to: storage)
        XCTAssertFalse(isHidden(storage, at: 0), "소스 모드에서는 커서가 멀어도 마커가 보인다")
        XCTAssertFalse(isHidden(storage, at: 4))
    }

    /// 노출한다고 본문색으로 두면 마커가 내용을 방해한다. 구문 색은 유지해야 한다.
    func testRevealAllStillDimsMarkers() {
        let source = "**굵게**"
        let storage = NSTextStorage(string: source)
        LiveStyleApplier(markerPolicy: .revealAll).apply(
            spans: MarkdownSyntaxMap.build(from: source),
            selection: NSRange(location: 100, length: 0), to: storage)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       Theme.default.markerColor)
    }

    func testEmptyDocumentDoesNotCrash() {
        let storage = NSTextStorage(string: "")
        applier.apply(spans: [], selection: NSRange(location: 0, length: 0), to: storage)
        XCTAssertEqual(storage.length, 0)
    }

    /// 스팬 범위가 문서를 넘어가도 예외로 죽지 않아야 한다. 증분 갱신을 넣으면 스팬과
    /// 문자열이 한 프레임 어긋날 수 있는데, 그때 NSRange 예외로 앱이 죽으면 안 된다.
    func testOutOfBoundsSpansAreIgnored() {
        let storage = NSTextStorage(string: "짧다")
        let bogus = [
            StyleSpan(kind: .strong, role: .marker, range: 100..<200),
            StyleSpan(kind: .heading(level: 1), role: .content, range: 0..<999),
        ]
        applier.apply(spans: bogus, selection: NSRange(location: 0, length: 0), to: storage)
        XCTAssertEqual(storage.string, "짧다")
    }
}
