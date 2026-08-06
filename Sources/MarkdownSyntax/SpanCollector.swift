import Markdown

/// AST를 훑어 `StyleSpan`을 모은다.
///
/// 핵심 규칙: swift-markdown의 컨테이너 노드 range는 구문 마커를 **포함**하고,
/// 자식 노드 range는 포함하지 않는다. 따라서 마커는 그 차집합이다.
///
///     opening = container.lower ..< firstChild.lower
///     content = firstChild.lower ..< lastChild.upper
///     closing = lastChild.upper ..< container.upper
///
/// 이 규칙 하나로 헤딩·Strong·Emphasis·Link가 전부 처리된다. ATX 헤딩처럼 닫는
/// 마커가 없는 경우는 빈 범위가 되어 자연히 걸러진다.
struct SpanCollector: MarkupWalker {

    private let offsetMap: SourceOffsetMap
    private let source: String
    private(set) var spans: [StyleSpan] = []

    init(offsetMap: SourceOffsetMap, source: String) {
        self.offsetMap = offsetMap
        self.source = source
    }

    mutating func collect(from document: Document) -> [StyleSpan] {
        spans = []
        visit(document)
        return spans
    }

    // MARK: - 좌표 변환

    /// 노드의 `SourceRange`를 UTF-16 오프셋 범위로 바꾼다.
    private func utf16Range(_ range: SourceRange?) -> Range<Int>? {
        guard let range,
              let lower = offsetMap.utf16Offset(line: range.lowerBound.line,
                                                utf8Column: range.lowerBound.column),
              let upper = offsetMap.utf16Offset(line: range.upperBound.line,
                                                utf8Column: range.upperBound.column),
              lower <= upper
        else { return nil }
        return lower..<upper
    }

    private mutating func append(_ kind: StyleSpan.Kind, _ role: StyleSpan.Role, _ range: Range<Int>?) {
        guard let range, !range.isEmpty else { return }  // 빈 범위는 버린다
        spans.append(StyleSpan(kind: kind, role: role, range: range))
    }

    /// 컨테이너와 자식의 차집합으로 마커·내용 스팬을 낸다.
    private mutating func appendContainer(_ kind: StyleSpan.Kind, _ markup: any Markup) {
        guard let outer = utf16Range(markup.range) else { return }

        let childRanges = markup.children.compactMap { utf16Range($0.range) }
        guard let first = childRanges.first, let last = childRanges.last else {
            // 자식이 없으면 전체를 내용으로 본다.
            append(kind, .content, outer)
            return
        }

        append(kind, .marker, outer.lowerBound..<first.lowerBound)
        append(kind, .content, first.lowerBound..<last.upperBound)
        append(kind, .marker, last.upperBound..<outer.upperBound)
    }

    // MARK: - 방문

    mutating func visitHeading(_ heading: Heading) {
        appendContainer(.heading(level: heading.level), heading)
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        appendContainer(.strong, strong)
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        appendContainer(.emphasis, emphasis)
        descendInto(emphasis)
    }

    mutating func visitLink(_ link: Link) {
        appendContainer(.link(destination: link.destination), link)
        descendInto(link)
    }
}
