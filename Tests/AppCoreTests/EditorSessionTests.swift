import XCTest
import AppKit
@testable import AppCore
@testable import DocumentCore
@testable import EditorKit

final class EditorSessionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markit-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 세션의 뷰는 스크롤 뷰가 프레임을 주기 전에는 폭이 0이다. 테스트에서는 직접 준다.
    private func session(_ mode: DisplayMode = .wysiwyg) -> EditorSession {
        let s = EditorSession()
        s.sourceView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.previewView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.mode = mode
        return s
    }

    private func file(_ name: String = "doc.md", contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func isHidden(_ v: EditorTextView, at i: Int) -> Bool {
        let f = v.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        return (f?.pointSize ?? 99) < 1.0
    }

    private func type(_ s: EditorSession, _ text: String) {
        for ch in text {
            s.sourceView.insertText(
                String(ch),
                replacementRange: NSRange(location: s.sourceView.string.utf16.count, length: 0))
        }
    }

    // MARK: - 모드 → 정책

    func testWysiwygModeHidesMarkers() {
        let s = session(.wysiwyg)
        s.text = "**굵게**\n둘째 줄"
        s.sourceView.setSelectedRange(NSRange(location: 8, length: 0))
        s.sourceView.restyleNow()
        XCTAssertTrue(isHidden(s.sourceView, at: 0))
    }

    func testSourceModeRevealsMarkers() {
        let s = session(.source)
        s.text = "**굵게**\n둘째 줄"
        s.sourceView.setSelectedRange(NSRange(location: 8, length: 0))
        s.sourceView.restyleNow()
        XCTAssertFalse(isHidden(s.sourceView, at: 0))
    }

    func testSplitModeRevealsInSourceAndHidesInPreview() {
        let s = session(.split)
        s.text = "**굵게**\n둘째 줄"
        s.sourceView.setSelectedRange(NSRange(location: 8, length: 0))
        s.sourceView.restyleNow()
        XCTAssertFalse(isHidden(s.sourceView, at: 0), "왼쪽은 원문이므로 마커가 보인다")
        XCTAssertTrue(isHidden(s.previewView, at: 0), "오른쪽은 프리뷰이므로 접혀 있다")
    }

    // MARK: - 타이핑이 문서에 닿는다 (Plan 2와의 연결)

    func testTypingUpdatesDocumentText() {
        let s = session()
        type(s, "# 제목")
        XCTAssertEqual(s.document.text, "# 제목")
    }

    func testTypingMakesDocumentDirty() {
        let s = session()
        XCTAssertFalse(s.isDirty)
        type(s, "x")
        XCTAssertTrue(s.isDirty)
    }

    func testSaveClearsDirty() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        try s.open(url)
        type(s, "추가")
        XCTAssertTrue(s.isDirty)
        _ = try s.save()
        XCTAssertFalse(s.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "처음\n추가")
    }

    /// 프로그램으로 내용을 바꾸는 정식 경로. `sourceView.setMarkdown`을 직접 부르면
    /// 문서가 따라오지 않아 저장이 옛 내용을 쓴다.
    func testSettingTextKeepsDocumentAndViewsConsistent() {
        let s = session(.split)
        s.text = "# 새 내용\n"
        XCTAssertEqual(s.document.text, "# 새 내용\n")
        XCTAssertEqual(s.sourceView.string, "# 새 내용\n")
        XCTAssertEqual(s.previewView.string, "# 새 내용\n")
    }

    func testSettingTextThenSavingWritesThatText() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        try s.open(url)
        s.text = "프로그램이 바꾼 내용\n"
        _ = try s.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "프로그램이 바꾼 내용\n")
    }

    // MARK: - 프리뷰 동기화

    func testPreviewMirrorsSourceTextInSplitMode() {
        let s = session(.split)
        type(s, "# 제목")
        XCTAssertEqual(s.previewView.string, "# 제목")
    }

    /// 분할 모드가 아니면 프리뷰를 갱신하지 않는다. 보이지도 않는 것을 위해 파싱을
    /// 한 번 더 하면 32KB 손익분기점이 그냥 절반으로 내려간다.
    func testPreviewIsNotSyncedOutsideSplitMode() {
        let s = session(.wysiwyg)
        type(s, "# 제목")
        XCTAssertEqual(s.previewView.string, "")
    }

    func testSwitchingToSplitSyncsPreviewImmediately() {
        let s = session(.wysiwyg)
        type(s, "# 제목")
        XCTAssertEqual(s.previewView.string, "")
        s.mode = .split
        XCTAssertEqual(s.previewView.string, "# 제목",
                       "분할로 들어오면 그때까지의 내용이 프리뷰에 있어야 한다")
    }

    func testPreviewEditsNeverReachDocument() {
        let s = session(.split)
        type(s, "원문")
        s.previewView.setMarkdown("프리뷰를 억지로 바꿈")
        XCTAssertEqual(s.document.text, "원문", "프리뷰는 파생물이다. 문서에 닿으면 안 된다")
    }

    // MARK: - 열기

    func testOpenLoadsFileIntoSourceViewAndDocument() throws {
        let url = try file(contents: "# 제목\n본문\n")
        let s = session()
        try s.open(url)
        XCTAssertEqual(s.sourceView.string, "# 제목\n본문\n")
        XCTAssertEqual(s.document.text, "# 제목\n본문\n")
        XCTAssertEqual(s.document.url, url)
    }

    func testOpenResetsDirty() throws {
        let s = session()
        type(s, "쓰던 것")
        XCTAssertTrue(s.isDirty)
        try s.open(try file(contents: "새 파일\n"))
        XCTAssertFalse(s.isDirty, "새로 열었으면 깨끗해야 한다")
    }

    func testOpenPlacesCaretAtDocumentStart() throws {
        let s = session()
        type(s, "쓰던 것")
        try s.open(try file(contents: "# 새 파일\n본문\n"))
        XCTAssertEqual(s.sourceView.selectedRange(), NSRange(location: 0, length: 0))
    }

    // MARK: - 무손실 왕복 (AD-2의 핵심 계약이 조립 후에도 유지되는가)

    private static let corpus: [(String, String)] = [
            ("한글", "# 한글 제목\n본문입니다.\n"),
            ("이모지", "🇰🇷 국기와 👨‍👩‍👧‍👦 가족\n"),
            ("CRLF", "첫 줄\r\n둘째 줄\r\n"),
            ("후행 공백", "줄 끝에 공백   \n다음 줄\n"),
            ("개행 없음", "마지막 개행이 없다"),
            ("빈 파일", ""),
            ("탭 들여쓰기", "\t탭으로 들여쓴 줄\n"),
            ("GFM 표", "| 가 | 나 |\n|---|---|\n| 1 | 2 |\n"),
            ("중첩 리스트", "- 하나\n  - 둘\n    - 셋\n"),
            ("코드 펜스", "```swift\nlet x = \"문자열\"\n```\n"),
            ("혼합 강조", "***굵고 기울임*** 그리고 _다른_ 마커\n"),
        ("연속 개행", "\n\n\n본문\n\n\n"),
    ]

    /// `open` → `save`가 문서 층에서 바이트 동일한가.
    ///
    /// **주의: 이것은 뷰를 거치지 않는다.** `save()`는 `document.text`를 쓰고 그것은
    /// 디스크에서 바로 온 값이다. `NSTextStorage`의 정규화 여부는 아래 테스트가 잡는다 —
    /// 이 테스트만 두고 "편집기를 왕복한다"고 믿었다가 변이 테스트에서 들켰다.
    func testOpenThenSaveIsByteIdentical() throws {
        for (label, contents) in Self.corpus {
            let url = try file("\(UUID().uuidString).md", contents: contents)
            let original = try Data(contentsOf: url)

            let s = session()
            try s.open(url)
            _ = try s.save()

            XCTAssertEqual(try Data(contentsOf: url), original,
                           "\(label): 문서 층에서 바이트가 바뀌었다")
        }
    }

    /// **텍스트가 실제로 `NSTextStorage`를 왕복하는 경로.**
    ///
    /// 한 글자를 입력하면 `onTextChange`가 뷰의 문자열 전체를 문서로 되돌려 보낸다.
    /// 그래서 `NSTextStorage`가 개행이나 유니코드를 정규화하면 **건드리지 않은 바이트까지**
    /// 바뀌어 여기서 드러난다. 사용자 편집이 지나는 진짜 경로가 이것이다.
    func testEditingThenSavingLeavesUntouchedBytesIdentical() throws {
        for (label, contents) in Self.corpus {
            let url = try file("\(UUID().uuidString).md", contents: contents)
            let original = try Data(contentsOf: url)

            let s = session()
            try s.open(url)
            s.sourceView.insertText(
                "가",
                replacementRange: NSRange(location: s.sourceView.string.utf16.count, length: 0))
            _ = try s.save()

            XCTAssertEqual(try Data(contentsOf: url), original + Data("가".utf8),
                           "\(label): 편집기를 왕복하면서 건드리지 않은 바이트가 바뀌었다")
        }
    }

    func testRoundTripSurvivesModeSwitching() throws {
        let contents = "# 제목\r\n**굵게** `코드`\r\n"
        let url = try file(contents: contents)
        let original = try Data(contentsOf: url)

        let s = session()
        try s.open(url)
        for mode in [DisplayMode.source, .split, .wysiwyg] { s.mode = mode }
        _ = try s.save()

        XCTAssertEqual(try Data(contentsOf: url), original,
                       "모드 전환은 표시 정책 변경일 뿐 문서 변환이 아니다")
    }

    // MARK: - 외부 변경 (Plan 2의 충돌 정책이 조립 후에도 동작하는가)

    func testExternalChangeReloadsSourceViewWhenClean() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        let watcher = FakeWatcher()
        try s.open(url, watcher: watcher)

        try Data("에이전트가 씀\n".utf8).write(to: url, options: .atomic)
        watcher.fire()

        XCTAssertEqual(s.sourceView.string, "에이전트가 씀\n", "버퍼가 깨끗하면 리로드한다")
        XCTAssertFalse(s.isDirty)
    }

    func testExternalChangeReportsConflictWhenDirty() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        let watcher = FakeWatcher()
        try s.open(url, watcher: watcher)
        type(s, "내가 쓴 것")

        var reported: ExternalChange?
        s.onExternalChange = { reported = $0 }
        try Data("에이전트가 씀\n".utf8).write(to: url, options: .atomic)
        watcher.fire()

        guard case .conflict(let diskText) = reported else {
            return XCTFail("dirty일 때는 충돌을 보고해야 한다. 받은 것: \(String(describing: reported))")
        }
        XCTAssertEqual(diskText, "에이전트가 씀\n")
        XCTAssertTrue(s.sourceView.string.hasSuffix("내가 쓴 것"), "버퍼를 건드리면 안 된다")
    }

    func testAcceptDiskVersionUpdatesSourceView() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        try s.open(url, watcher: FakeWatcher())
        type(s, "내가 쓴 것")

        s.acceptDiskVersion("디스크 내용\n")

        XCTAssertEqual(s.sourceView.string, "디스크 내용\n")
        XCTAssertEqual(s.document.text, "디스크 내용\n")
        XCTAssertFalse(s.isDirty)
    }

    /// 리로드가 사용자 편집으로 오인되면 리로드 → dirty → 저장 → 파일 변경 → 리로드의
    /// 순환이 생긴다. `setMarkdown`이 `onTextChange`를 부르지 않는 성질에 의존한다.
    func testReloadDoesNotMarkDocumentDirty() throws {
        let url = try file(contents: "처음\n")
        let s = session()
        let watcher = FakeWatcher()
        try s.open(url, watcher: watcher)

        try Data("에이전트가 씀\n".utf8).write(to: url, options: .atomic)
        watcher.fire()

        XCTAssertFalse(s.isDirty, "리로드는 사용자 편집이 아니다")
    }

    // MARK: - 명령

    func testModeCommandsSwitchMode() {
        let s = session(.wysiwyg)
        for (id, expected) in [("mode.source", DisplayMode.source),
                               ("mode.split", .split),
                               ("mode.wysiwyg", .wysiwyg)] {
            guard let command = s.commands.first(where: { $0.id == id }) else {
                return XCTFail("\(id) 명령이 없다")
            }
            s.run(command)
            XCTAssertEqual(s.mode, expected)
        }
    }

    func testSaveWithoutURLThrows() {
        let s = session()
        type(s, "저장할 곳이 없다")
        XCTAssertThrowsError(try s.save()) { error in
            XCTAssertEqual(error as? DocumentError, .noURL)
        }
    }

    func testCommandsAreStableAndUnique() {
        let ids = session().commands.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "명령 id가 중복되면 실행 대상이 모호해진다")
    }
}

/// 결정적 테스트를 위한 가짜 감시자. FSEvents는 OS가 발화 시점을 정하므로 쓸 수 없다.
final class FakeWatcher: FileWatching {
    private var onChange: (() -> Void)?
    func startWatching(_ url: URL, onChange: @escaping () -> Void) { self.onChange = onChange }
    func stopWatching() { onChange = nil }
    func fire() { onChange?() }
}
