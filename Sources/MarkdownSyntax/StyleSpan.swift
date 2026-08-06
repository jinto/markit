/// 라이브 스타일링이 필요한 원문의 한 구간.
///
/// `range`는 **UTF-16 코드 유닛 오프셋**이다. 최종 소비자가 `NSTextStorage`이고
/// `NSRange`가 UTF-16 기반이므로, AppKit 경계에서 변환 없이
/// `NSRange(location: range.lowerBound, length: range.count)`로 바로 쓸 수 있다.
public struct StyleSpan: Equatable, Sendable {

    /// 구간이 어떤 마크다운 구성물에 속하는지.
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case strong
        case emphasis
        case inlineCode
        case codeBlock(language: String?)
        case link(destination: String?)
        case listItemMarker
        case blockQuote
    }

    /// 구간이 보여줄 내용인지, 숨기거나 흐리게 할 구문 기호인지.
    ///
    /// 이 구분이 AD-2(소스가 진실)의 핵심이다. 원문에서 마커를 지우는 게 아니라
    /// 마커에 다른 표시 정책을 적용할 뿐이다.
    public enum Role: Equatable, Sendable {
        case content
        case marker
    }

    public let kind: Kind
    public let role: Role
    public let range: Range<Int>

    public init(kind: Kind, role: Role, range: Range<Int>) {
        self.kind = kind
        self.role = role
        self.range = range
    }
}
