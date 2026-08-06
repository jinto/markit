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
    /// 원문의 UTF-16 코드 유닛. `InlineCode`/`CodeBlock`의 델리미터를 세는 데 쓴다.
    /// 방문할 때마다 `Array(source.utf16)`를 만들면 노드 수에 비례해 O(n²)이 되므로
    /// 한 번만 만들어 둔다.
    private let utf16Units: [UInt16]
    private(set) var spans: [StyleSpan] = []

    init(offsetMap: SourceOffsetMap, source: String) {
        self.offsetMap = offsetMap
        self.utf16Units = Array(source.utf16)
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

    /// `InlineCode`는 자식이 없어서 차집합 규칙을 쓸 수 없다.
    /// 원문에서 백틱 런의 길이를 직접 세어 델리미터를 가른다.
    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let outer = utf16Range(inlineCode.range),
              outer.upperBound <= utf16Units.count else { return }

        var fence = 0
        while outer.lowerBound + fence < outer.upperBound,
              utf16Units[outer.lowerBound + fence] == Self.backtick {
            fence += 1
        }
        guard fence > 0, outer.count > fence * 2 else {
            append(.inlineCode, .content, outer)
            return
        }

        append(.inlineCode, .marker, outer.lowerBound..<(outer.lowerBound + fence))
        append(.inlineCode, .content, (outer.lowerBound + fence)..<(outer.upperBound - fence))
        append(.inlineCode, .marker, (outer.upperBound - fence)..<outer.upperBound)
    }

    /// `CodeBlock`도 자식이 없다. 펜스가 있으면 첫 줄과 마지막 줄이 마커다.
    /// 들여쓰기 코드블록에는 펜스가 없으므로 전체가 내용이다.
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let outer = utf16Range(codeBlock.range),
              outer.upperBound <= utf16Units.count,
              !outer.isEmpty else { return }
        let kind = StyleSpan.Kind.codeBlock(language: codeBlock.language)

        let opener = utf16Units[outer.lowerBound]
        guard opener == Self.backtick || opener == Self.tilde else {
            append(kind, .content, outer)  // 들여쓰기 코드블록
            return
        }

        // 여는 펜스는 첫 줄 끝(개행 포함)까지.
        var openEnd = outer.lowerBound
        while openEnd < outer.upperBound, utf16Units[openEnd] != Self.newline { openEnd += 1 }
        if openEnd < outer.upperBound { openEnd += 1 }  // 개행 포함

        // 닫는 펜스는 마지막 개행 뒤부터. 없으면 닫는 펜스가 없는 것이다.
        var closeStart = outer.upperBound
        var i = outer.upperBound - 1
        while i >= openEnd {
            if utf16Units[i] == Self.newline { closeStart = i + 1; break }
            i -= 1
        }

        append(kind, .marker, outer.lowerBound..<openEnd)
        append(kind, .content, openEnd..<closeStart)
        append(kind, .marker, closeStart..<outer.upperBound)
    }

    /// 리스트 항목의 마커(`- `, `1. `)는 항목 range 시작부터 첫 자식 시작까지다.
    /// 내용 스팬은 내지 않는다 — 리스트 항목의 본문은 그냥 문단이므로
    /// 별도 스타일이 필요 없다.
    mutating func visitListItem(_ listItem: ListItem) {
        if let outer = utf16Range(listItem.range),
           let firstChild = listItem.children.compactMap({ utf16Range($0.range) }).first {
            append(.listItemMarker, .marker, outer.lowerBound..<firstChild.lowerBound)
        }
        descendInto(listItem)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let outer = utf16Range(blockQuote.range),
           let firstChild = blockQuote.children.compactMap({ utf16Range($0.range) }).first {
            append(.blockQuote, .marker, outer.lowerBound..<firstChild.lowerBound)
        }
        descendInto(blockQuote)
    }

    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let tilde = UInt16(UnicodeScalar("~").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
}
