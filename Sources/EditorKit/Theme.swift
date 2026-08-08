import AppKit

/// 에디터가 쓰는 폰트와 색.
///
/// 값 타입이라 테스트가 원하는 조합을 만들어 넣을 수 있고, 나중에 사용자 테마를 얹을 때도
/// 이 구조체를 교체하면 된다.
public struct Theme {

    public var bodyFont: NSFont
    public var monoFont: NSFont

    public var textColor: NSColor
    /// 노출된 마커의 색. 본문보다 흐려야 마커가 내용을 방해하지 않는다.
    public var markerColor: NSColor
    public var linkColor: NSColor
    public var codeBackgroundColor: NSColor

    /// 모든 문단에 넣는 최소 줄 높이.
    ///
    /// 일관된 줄 간격을 위해서이기도 하지만, **줄 전체가 숨겨진 마커인 경우
    /// (예: ``` 펜스 줄) 줄 높이가 0으로 붕괴하는 것을 막는 역할이 더 크다.**
    /// 프로브로 확인: 이것이 없으면 17.00 → 0.00이 된다.
    public var minimumLineHeight: CGFloat

    /// 숨긴 마커에 입히는 폰트 크기.
    ///
    /// 0이 아니라 0.01인 이유: 글자를 원문과 레이아웃 양쪽에 그대로 남겨 두어야 캐럿
    /// 좌표계가 하나로 유지된다. 표시용 문단에서 글자를 지우는 방식은 캐럿을 깨뜨린다
    /// (계획서 사실 4번).
    static let hiddenFontSize: CGFloat = 0.01

    /// 헤딩 레벨별 폰트 크기. 인덱스 0이 h1이다.
    private let headingSizes: [CGFloat]

    public init(
        bodyFont: NSFont = .systemFont(ofSize: 15),
        monoFont: NSFont = .monospacedSystemFont(ofSize: 13.5, weight: .regular),
        textColor: NSColor = .labelColor,
        markerColor: NSColor = .tertiaryLabelColor,
        linkColor: NSColor = .linkColor,
        codeBackgroundColor: NSColor = .unemphasizedSelectedContentBackgroundColor,
        headingSizes: [CGFloat] = [28, 23, 20, 18, 17, 16]
    ) {
        self.bodyFont = bodyFont
        self.monoFont = monoFont
        self.textColor = textColor
        self.markerColor = markerColor
        self.linkColor = linkColor
        self.codeBackgroundColor = codeBackgroundColor
        self.headingSizes = headingSizes
        self.minimumLineHeight =
            (bodyFont.ascender - bodyFont.descender + bodyFont.leading).rounded(.up) * 1.35
    }

    public static let `default` = Theme()

    /// 레벨을 1...6으로 고정한다. 파서가 그 범위만 낸다고 믿지 않는다.
    public func headingFont(level: Int) -> NSFont {
        let size = headingSizes[max(1, min(headingSizes.count, level)) - 1]
        return .boldSystemFont(ofSize: size)
    }

    /// 문단 스타일. 모든 문단이 같은 것을 쓴다.
    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = minimumLineHeight
        return style
    }
}
