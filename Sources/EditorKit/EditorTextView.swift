import AppKit
import MarkdownSyntax

/// 마크다운 원문을 편집하는 `NSTextView`(TextKit 2).
///
/// 파싱(`MarkdownSyntaxMap`)과 정책(`LiveStyleApplier`)을 편집·커서 이벤트에 연결하는
/// 배선만 담당한다. 스타일 결정은 여기서 하지 않는다.
///
/// `MarkdownDocument`를 알지 못한다 — 조립은 상위(앱)에서 `onTextChange`로 한다.
public final class EditorTextView: NSTextView {

    /// 바꾸면 즉시 다시 스타일을 입힌다.
    public var theme: Theme {
        didSet { restyleNow() }
    }

    /// 사용자 편집으로 원문이 바뀔 때 불린다. `setMarkdown(_:)`으로 바뀔 때는 부르지 않는다.
    public var onTextChange: ((String) -> Void)?

    /// 마지막으로 스타일을 입힐 때의 활성 줄. 커서가 같은 줄 안에서 움직이면 마커 노출이
    /// 달라지지 않으므로 재스타일을 건너뛰는 기준이 된다.
    private var activeLine = NSRange(location: 0, length: 0)
    private var restyleScheduled = false
    /// 프로그램이 원문을 갈아끼우는 중. 이때의 변경은 사용자 편집이 아니다.
    private var isProgrammaticChange = false

    /// 합침이 실제로 일어나는지 테스트가 관찰할 수단. 다른 방법으로는 볼 수 없다.
    var restylePassCountForTesting = 0
    var hasPendingRestyleForTesting: Bool { restyleScheduled }

    public init(theme: Theme = .default) {
        self.theme = theme

        // TextKit 2 스택을 직접 조립한다. `NSTextView.init(usingTextLayoutManager:)`는
        // convenience 이니셜라이저라 서브클래스에서 `super.init`으로 부를 수 없다.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: container)

        container.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        allowsUndo = true

        // 마크다운 원문을 오염시킬 수 있는 자동 치환을 모두 끈다. 스마트 인용부호가
        // `"`를 `“`로 바꾸면 코드블록 안의 문자열이 깨지고, 대시 치환은 `---`(구분선)을
        // 망친다. 헤드리스에서는 발화하지 않아 자동 테스트가 불가능하므로 수동
        // 체크리스트에도 올려 두었다.
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false

        textStorage?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorTextView는 코드로만 만든다")
    }

    // MARK: - 원문 교체

    /// 원문을 통째로 갈아끼운다. 파일 열기와 외부 변경 리로드가 쓴다.
    ///
    /// `onTextChange`를 부르지 않는다. 부르면 리로드가 사용자 편집으로 보고되어
    /// 리로드 → dirty → 저장 → 파일 변경 → 리로드의 순환이 생긴다.
    public func setMarkdown(_ text: String) {
        guard let storage = textStorage else { return }
        isProgrammaticChange = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        isProgrammaticChange = false
        // 새 문서를 여는 것이므로 커서를 맨 앞으로 되돌린다.
        setSelectedRange(NSRange(location: 0, length: 0))
        restyleNow()
    }

    // MARK: - 커서 이동

    public override func setSelectedRanges(_ ranges: [NSValue],
                                          affinity: NSSelectionAffinity,
                                          stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)

        // 줄이 바뀌지 않았으면 마커 노출도 바뀌지 않는다. 화살표 연타마다 전체
        // 재파싱을 하면 큰 문서에서 커서가 끈적해진다 (325KB에서 키당 155ms).
        guard let storage = textStorage else { return }
        let line = lineRange(for: selectedRange(), in: storage)
        if line != activeLine { scheduleRestyle() }
    }

    // MARK: - 재스타일

    /// 예약을 취소하고 즉시 다시 스타일을 입힌다.
    func restyleNow() {
        restyleScheduled = false
        guard let storage = textStorage else { return }

        restylePassCountForTesting += 1
        let spans = MarkdownSyntaxMap.build(from: storage.string)
        LiveStyleApplier(theme: theme).apply(spans: spans,
                                            selection: selectedRange(),
                                            to: storage)
        activeLine = lineRange(for: selectedRange(), in: storage)
    }

    /// 다음 런루프로 재스타일을 합친다.
    ///
    /// 파싱이 병목이다 (32KB에서 키입력당 15ms, 이미 프레임 예산에 닿는다). 빠르게
    /// 타이핑할 때 글자마다 파싱하면 안 된다.
    private func scheduleRestyle() {
        guard !restyleScheduled else { return }
        restyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            // 그 사이 restyleNow()가 먼저 돌았으면 할 일이 없다.
            guard let self, self.restyleScheduled else { return }
            self.restyleNow()
        }
    }

    private func lineRange(for selection: NSRange, in storage: NSTextStorage) -> NSRange {
        let text = storage.string as NSString
        let location = max(0, min(selection.location, text.length))
        let length = min(selection.length, text.length - location)
        return text.lineRange(for: NSRange(location: location, length: length))
    }
}

// MARK: - NSTextStorageDelegate

extension EditorTextView: NSTextStorageDelegate {

    /// 스타일링 자체가 이 델리게이트를 다시 부르지만 `.editedAttributes`만 낸다.
    /// **`.editedCharacters`만 보면 재귀가 구조적으로 막힌다.**
    public func textStorage(_ storage: NSTextStorage,
                            didProcessEditing actions: NSTextStorageEditActions,
                            range: NSRange,
                            changeInLength delta: Int) {
        guard actions.contains(.editedCharacters) else { return }
        if !isProgrammaticChange {
            onTextChange?(storage.string)
        }
        // 여기서 바로 스타일을 입히지 않는다. 지금은 스토리지의 편집 처리 안이고,
        // 재스타일은 다시 begin/endEditing으로 묶기 때문이다.
        scheduleRestyle()
    }
}
