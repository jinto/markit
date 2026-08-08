import AppKit
import MarkdownSyntax

/// `[StyleSpan]`과 커서 위치를 `NSTextStorage` 속성으로 바꾼다.
///
/// **마커를 숨길지 노출할지 결정하는 정책이 이 타입에만 있다.** 그래서 정책을 바꾸려면
/// 여기만 고치면 되고, `NSTextView` 없이 맨 `NSTextStorage`로 테스트할 수 있다.
///
/// 원문은 절대 변형하지 않는다 (AD-2). 이 파일에 `replaceCharacters`가 등장하면 버그다.
public struct LiveStyleApplier {

    public let theme: Theme

    public init(theme: Theme = .default) {
        self.theme = theme
    }

    /// 커서가 있는 **줄**의 마커를 노출한다.
    ///
    /// 구문(construct) 단위가 아니라 줄 단위인 이유는 계획서에 적어 두었다: `StyleSpan`이
    /// 마커 자신의 범위만 들고 있어 구문 전체 범위를 복원할 수 없고, 줄 기준은 블록
    /// 마커까지 균일하게 다루면서 실사용감도 라이브 프리뷰 에디터들과 비슷하다.
    public func apply(spans: [StyleSpan], selection: NSRange, to storage: NSTextStorage) {
        // 속성 변경을 하나로 묶는다. 묶지 않으면 델리게이트가 스팬마다 불린다.
        storage.beginEditing()
        defer { storage.endEditing() }

        let length = storage.length
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: length))
        guard length > 0 else { return }

        let text = storage.string as NSString
        let activeLine = text.lineRange(for: clamp(selection, to: length))

        // 스팬은 (시작 오름차순, 끝 내림차순)으로 온다 — 넓은 것이 먼저다. 순서대로
        // 적용하면 좁은 스팬이 넓은 스팬을 덮어쓴다. 단 폰트는 덮어쓰지 않고 합성한다.
        for span in spans {
            guard let range = clamp(span.range, to: length) else { continue }
            switch span.role {
            case .content: applyContent(span.kind, range, to: storage)
            case .marker: applyMarker(span.kind, range, activeLine: activeLine, to: storage)
            }
        }
    }

    /// 늘 보이는 마커와 숨기는 마커.
    ///
    /// 블록 마커를 남기는 이유는 각각 다르다. 펜스는 언어 표시를 겸하고, 리스트 불릿은
    /// 그 자체가 시각적 내용이며, 인용 마커는 들여쓰기 표현이 없는 v1에서 유일한 단서다.
    public static func isHidable(_ kind: StyleSpan.Kind) -> Bool {
        switch kind {
        case .heading, .strong, .emphasis, .inlineCode:
            return true
        case .codeBlock, .listItemMarker, .blockQuote, .link:
            return false
        }
    }

    // MARK: - 적용

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.bodyFont,
         .foregroundColor: theme.textColor,
         .paragraphStyle: theme.paragraphStyle]
    }

    private func applyContent(_ kind: StyleSpan.Kind, _ range: NSRange, to storage: NSTextStorage) {
        switch kind {
        case .heading(let level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: range)
        case .strong:
            // 굵기는 한글에서도 살아남는다 (AppleSDGothicNeo-Bold로 치환된다). 대책이 필요 없다.
            compose(.bold, over: range, in: storage)
        case .emphasis:
            compose(.italic, over: range, in: storage,
                    fallbackForUncovered: [.obliqueness: Self.syntheticObliqueness])
        case .inlineCode, .codeBlock:
            storage.addAttributes([.font: theme.monoFont,
                                   .backgroundColor: theme.codeBackgroundColor], range: range)
        case .link:
            storage.addAttributes([.foregroundColor: theme.linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .listItemMarker, .blockQuote:
            // 수집기가 이 종류로는 마커 스팬만 낸다. 내용 스팬이 오면 손대지 않는다.
            break
        }
    }

    private func applyMarker(_ kind: StyleSpan.Kind, _ range: NSRange,
                             activeLine: NSRange, to storage: NSTextStorage) {
        let onActiveLine = NSIntersectionRange(range, activeLine).length > 0
        if Self.isHidable(kind) && !onActiveLine {
            // 글자를 지우지 않고 폭만 없앤다. 원문과 레이아웃에 남아 있어야 캐럿
            // 좌표계가 하나로 유지된다 (계획서 사실 4번).
            storage.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: Theme.hiddenFontSize),
                                 range: range)
        } else {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
        }
    }

    /// 한글 등 이탤릭 페이스가 없는 문자를 기울일 때 쓰는 전단(shear) 값.
    ///
    /// 한글에 이탤릭 폰트를 지정하면 **보통 글자와 픽셀까지 동일하게** 그려진다
    /// (비트맵 비교로 확인). 강조가 아무 표시도 없이 사라지는 것을 막으려면 직접 기울여야 한다.
    static let syntheticObliqueness = 0.2

    /// 폰트를 갈아치우지 않고 트레이트만 더한다.
    ///
    /// `## **굵은** 제목`에서 `strong`이 폰트를 그냥 설정하면 헤딩 크기가 사라진다.
    /// 이미 깔린 폰트를 읽어 트레이트를 union해야 한다.
    ///
    /// `fallbackForUncovered`는 합성한 폰트가 그 구간의 글자를 못 그릴 때 대신 넣을 속성이다.
    /// `NSTextStorage`는 글자를 못 그리는 폰트를 `endEditing`에서 조용히 다른 폰트로
    /// 치환하면서 트레이트를 버린다. 치환 후에 읽어서 보정할 수는 없으므로 (편집 블록
    /// 안에서는 치환이 아직 안 보인다) **커버리지를 미리 확인해서** 판단한다.
    private func compose(_ traits: NSFontDescriptor.SymbolicTraits,
                         over range: NSRange, in storage: NSTextStorage,
                         fallbackForUncovered fallback: [NSAttributedString.Key: Any]? = nil) {
        let text = storage.string as NSString
        var fonts: [(NSRange, NSFont)] = []
        var uncovered: [NSRange] = []

        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? theme.bodyFont
            let descriptor = current.fontDescriptor.withSymbolicTraits(
                current.fontDescriptor.symbolicTraits.union(traits))
            guard let composed = NSFont(descriptor: descriptor, size: current.pointSize) else { return }
            fonts.append((subrange, composed))
            if fallback != nil, !composed.coveredCharacterSet.isSuperset(
                of: CharacterSet(charactersIn: text.substring(with: subrange))) {
                uncovered.append(subrange)
            }
        }

        // 열거가 끝난 뒤에 적용한다. 열거 중에 스토리지를 고치면 안 된다.
        for (subrange, font) in fonts {
            storage.addAttribute(.font, value: font, range: subrange)
        }
        if let fallback {
            for subrange in uncovered { storage.addAttributes(fallback, range: subrange) }
        }
    }

    // MARK: - 범위 안전

    /// 스팬이 문서 밖을 가리켜도 예외로 죽지 않는다.
    ///
    /// 증분 갱신에서 스팬과 문자열이 한 프레임 어긋날 수 있다. 그때 `NSRange` 예외로
    /// 앱이 죽는 대신 그 스팬만 잘라내거나 버린다.
    private func clamp(_ range: Range<Int>, to length: Int) -> NSRange? {
        guard range.lowerBound >= 0, range.lowerBound < length else { return nil }
        let upper = min(range.upperBound, length)
        guard upper > range.lowerBound else { return nil }
        return NSRange(location: range.lowerBound, length: upper - range.lowerBound)
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: min(range.length, length - location))
    }
}
