import AppKit
import DocumentCore
import EditorKit

/// 조립 루트. `MarkdownDocument`(파일 상태)와 `EditorTextView`(편집)를 잇는 유일한 곳이다.
///
/// `EditorKit`과 `DocumentCore`는 서로를 모른다. 그 독립을 지키면서 조립을 테스트 가능하게
/// 두려고 이 타입을 별도 타깃에 뒀다. **SwiftUI를 import하지 않는다** — 세션 전체가
/// `swift test`로 검증된다.
public final class EditorSession {

    /// 편집하는 뷰. 원문이 진실이고 이것이 그 원문을 들고 있다.
    ///
    /// **뷰를 화면에 얹기 위해 공개한다.** 텍스트를 프로그램으로 교체할 때는 이 뷰의
    /// `setMarkdown`이 아니라 `text`를 쓴다 — 뷰만 바꾸면 문서가 따라오지 않아 저장이
    /// 옛 내용을 쓴다.
    public let sourceView: EditorTextView
    /// 분할 모드 오른쪽의 읽기 전용 프리뷰. 파생물이며 저장 경로에 닿지 않는다.
    public let previewView: EditorTextView

    public private(set) var document: MarkdownDocument

    /// 원문. 설정하면 문서와 두 뷰가 함께 갱신된다.
    ///
    /// 프로그램으로 내용을 바꾸는 정식 경로다. 커서는 문서 맨 앞으로 돌아간다.
    public var text: String {
        get { document.text }
        set {
            document.text = newValue
            syncViewsFromDocument()
        }
    }

    public var isDirty: Bool { document.isDirty }

    /// 자동 리로드로 처리되지 않은 외부 변경. 충돌과 파일 소실을 상위가 사용자에게 묻는다.
    public var onExternalChange: ((ExternalChange) -> Void)?

    public var mode: DisplayMode = .wysiwyg {
        didSet { applyMode() }
    }

    public init(theme: Theme = .default) {
        sourceView = EditorTextView(theme: theme)
        previewView = EditorTextView.makePreview(theme: theme)
        document = MarkdownDocument()

        sourceView.onTextChange = { [weak self] text in
            self?.handleSourceTextChange(text)
        }
        applyMode()
    }

    // MARK: - 모드

    private func applyMode() {
        sourceView.markerPolicy = mode.sourceMarkerPolicy
        // 분할로 들어온 순간 그때까지의 내용이 프리뷰에 있어야 한다.
        if mode.showsPreview { previewView.setMarkdown(sourceView.string) }
    }

    // MARK: - 편집

    private func handleSourceTextChange(_ text: String) {
        document.text = text
        // 보이지 않는 프리뷰를 갱신하면 파싱을 한 번 더 하는 셈이다. 분할 모드에서만 한다.
        if mode.showsPreview { previewView.setMarkdown(text) }
    }

    // MARK: - 파일

    /// 파일을 열고 감시를 시작한다.
    ///
    /// `watcher`를 받는 이유는 테스트다. FSEvents는 OS가 발화 시점을 정하므로 결정적
    /// 테스트가 불가능하다 (Plan 2와 같은 이유).
    public func open(_ url: URL, watcher: FileWatching = FSEventsFileWatcher()) throws {
        let loaded = try MarkdownDocument(loadingFrom: url)

        document.stopWatching()
        document = loaded
        document.onExternalChange = { [weak self] change in
            self?.handleExternalChange(change)
        }

        // setMarkdown은 onTextChange를 부르지 않으므로 (Plan 3) 파일 열기가 사용자
        // 편집으로 오인되지 않는다. 그 성질에 의존하고 있다.
        sourceView.setMarkdown(loaded.text)
        if mode.showsPreview { previewView.setMarkdown(loaded.text) }

        document.beginWatching(with: watcher)
    }

    @discardableResult
    public func save() throws -> SaveOutcome {
        try document.save()
    }

    @discardableResult
    public func save(to url: URL) throws -> SaveOutcome {
        try document.save(to: url)
    }

    /// 충돌 대화에서 사용자가 디스크 버전을 택했을 때.
    public func acceptDiskVersion(_ text: String) {
        document.acceptDiskVersion(text)
        syncViewsFromDocument()
    }

    private func handleExternalChange(_ change: ExternalChange) {
        // 자동 리로드된 경우에만 버퍼를 따라가게 한다. 충돌과 소실은 판단이 필요하므로
        // 버퍼를 그대로 두고 상위에 넘긴다.
        if case .reloaded = change { syncViewsFromDocument() }
        onExternalChange?(change)
    }

    private func syncViewsFromDocument() {
        sourceView.setMarkdown(document.text)
        if mode.showsPreview { previewView.setMarkdown(document.text) }
    }

    // MARK: - 명령

    public var commands: [Command] {
        [
            Command(id: "mode.wysiwyg", title: "WYSIWYG 모드", shortcut: "⌘1"),
            Command(id: "mode.source", title: "소스 모드", shortcut: "⌘2"),
            Command(id: "mode.split", title: "분할 모드", shortcut: "⌘3"),
            Command(id: "file.save", title: "저장", shortcut: "⌘S"),
        ]
    }

    /// 명령을 실행한다. 파일 선택이 필요한 명령(열기·다른 이름으로 저장)은 여기 없다 —
    /// 패널은 UI의 일이므로 상위가 URL을 얻어 `open(_:)`/`save(to:)`를 부른다.
    public func run(_ command: Command) {
        switch command.id {
        case "mode.wysiwyg": mode = .wysiwyg
        case "mode.source": mode = .source
        case "mode.split": mode = .split
        case "file.save": try? save()
        default: break
        }
    }
}
