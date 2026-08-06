import Markdown

/// 마크다운 원문을 라이브 스타일링용 범위 정보로 바꾼다.
///
/// 이 타입은 **원문을 읽기만 한다.** 파싱해서 다시 마크다운으로 쓰는 일은 절대 없다.
/// 설계 문서 AD-2에 따라 원문이 진실이고, 재직렬화는 정규화를 일으켜 무손실 왕복을
/// 깨뜨리기 때문이다.
public enum MarkdownSyntaxMap {

    /// 원문 전체에서 스팬을 만든다. 순수 함수 — 같은 입력이면 같은 출력.
    ///
    /// 결과는 오프셋 오름차순이고, 같은 오프셋에서는 넓은 범위가 먼저 온다.
    /// 소비자(`LiveStyleApplier`)가 순서대로 속성을 덮어쓰면 중첩 강조가
    /// 자연히 올바르게 겹친다.
    public static func build(from source: String) -> [StyleSpan] {
        guard !source.isEmpty else { return [] }

        let document = Document(parsing: source)
        var collector = SpanCollector(offsetMap: SourceOffsetMap(source: source), source: source)
        let spans = collector.collect(from: document)

        return spans.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            return a.range.upperBound > b.range.upperBound  // 넓은 것 먼저
        }
    }

    /// 변경 범위를 알 때 스팬을 다시 만든다.
    ///
    /// 지금은 전체를 다시 만든다. 이것이 **의도된 첫 구현**이다 — 등가성 테스트를
    /// 먼저 세워 두고, 나중에 블록 단위 재파싱으로 최적화할 때 그 테스트가
    /// 정확성을 지켜 준다. 최적화를 먼저 하면 검증할 기준이 없다.
    ///
    /// - Parameters:
    ///   - source: 변경이 **이미 적용된** 전체 원문
    ///   - changedUTF16Range: `source` 안에서 변경된 구간. 범위를 벗어나면 무시된다
    public static func rebuild(source: String, changedUTF16Range: Range<Int>) -> [StyleSpan] {
        _ = changedUTF16Range  // 블록 단위 최적화 단계에서 사용
        return build(from: source)
    }
}
