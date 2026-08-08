# EditorKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설계 문서의 컴포넌트 3(`LiveStyleApplier`)과 4(`EditorTextView`). `MarkdownSyntaxMap`이 낸 `[StyleSpan]`을 실제 텍스트 속성으로 바꿔 `NSTextView`(TextKit 2)에 입힌다. 마커를 숨길지 노출할지 결정하는 정책이 여기 산다.

**Architecture:** AD-2대로 `NSTextStorage`는 마크다운 원문을 그대로 보유하고 스타일링은 **속성만** 입힌다. 마커 숨김도 속성으로 한다 — 원문을 건드리지 않는다. 정책(`LiveStyleApplier`)과 배선(`EditorTextView`)을 분리해 정책을 순수하게 테스트한다.

**Tech Stack:** Swift 5.9+, macOS 14+, AppKit (TextKit 2), XCTest

## Global Constraints

- 최소 플랫폼: `.macOS(.v14)`
- **이 타깃은 AppKit을 import한다.** `MarkdownSyntax`/`DocumentCore`의 헤드리스 규칙은 그 타깃들에만 적용된다
- `MarkdownSyntax`에 의존한다. `DocumentCore`에는 의존하지 않는다 — 조립은 상위(앱)에서 한다
- 새 서드파티 의존성을 추가하지 않는다
- **원문을 변형하지 않는다.** 스타일링은 속성 적용뿐이다. 이 타깃에서 `replaceCharacters`를 호출하는 코드는 버그다
- 테스트 프레임워크는 XCTest. **앱 번들 없이 `swift test`로 전부 돌아야 한다** (아래 사실 1번)
- 라이선스: Apache-2.0

## 검증된 사실 (직접 프로브해서 확인 — 추측 아님)

### 1. 헤드리스 `swift test`에서 TextKit 2 `NSTextView`가 완전히 동작한다

`NSApplication`도, 앱 번들도, 창도 없이 다음이 모두 확인됐다:

```
NSTextView(usingTextLayoutManager: true) → textLayoutManager 살아 있음
레이아웃 (ensureLayout + enumerateTextLayoutFragments) 동작
insertText(_:replacementRange:)로 타이핑 재현 가능
textViewDidChangeSelection 발화 (2회 이동 → 2회)
typographicBounds로 글리프 폭·줄 높이 측정 가능
```

**결과: Plan 3에 Xcode 앱 타깃이 필요 없다.** 계획 초안에서는 필요하다고 적었는데 틀렸다.
SPM 타깃 하나로 충분하고, 마커 숨김 여부까지 폭을 재서 자동 검증할 수 있다.

**예외: `undoManager`는 헤드리스에서 nil이다** (`allowsUndo = true`여도). 언두 동작은 자동
테스트가 불가능하므로 수동 체크리스트로 넘긴다.

### 2. `layoutManager`를 한 번 읽으면 TextKit 2가 TextKit 1으로 영구 강등된다

```
갓 만든 상태              → textLayoutManager: true
textStorage 접근 후        → textLayoutManager: true   (안전)
textContentStorage 접근 후 → textLayoutManager: true   (안전)
string 설정 후             → textLayoutManager: true   (안전)
layoutManager 접근 후      → textLayoutManager: false  ← 강등
```

조용히 일어나고 예외도 경고도 없다. TextKit 1으로 떨어져도 앱은 그냥 동작하므로 **한참 뒤에
성능이나 레이아웃 이상으로만 드러난다.** 그래서 회귀 테스트로 못 박는다 (Task 3).

`textStorage`는 안전하다는 게 중요하다 — 스타일링 경로 전체가 `textStorage`를 쓴다.

### 3. 마커를 "숨기는" 세 방법 중 쓸 수 있는 것은 하나뿐이다

원문 `**굵게**`(6 유닛)에서 `**` 4개를 사라져 보이게 하는 실험. 목표 폭은 `굵게`만
그렸을 때의 24.22pt다.

| 방법 | 폭 | 판정 |
|---|---|---|
| `foregroundColor = .clear` | 50.03 | **폭이 그대로 남는다.** 숨김에 못 쓴다 (흐리게에만 쓴다) |
| `font = systemFont(ofSize: 0.01)` | 24.24 | 접힌다 |
| `NSTextContentStorageDelegate`로 표시용 문단에서 삭제 | 24.22 | 폭은 완벽하지만 **캐럿이 깨진다 (아래)** |

### 4. 표시용 문단 치환(`NSTextContentStorageDelegate`)은 캐럿을 깨뜨린다 — 배제

TextKit 2의 정공법처럼 보이고 폭도 정확히 맞지만, 쓸 수 없다:

```
캐럿 순회 (오른쪽 화살표를 계속 누를 때 지나는 원문 오프셋)
  마커를 그대로 표시   : [0, 1, 2, 3, 4, 5, 6]   정상
  표시용 문단에서 삭제 : [0, 6]                   ← 한 번에 튄다

히트테스트 (문단을 클릭한 x좌표 → 원문 오프셋)
  x=13 → 0
  x=20 → 1     ← 보이는 글자 끝을 클릭하면 캐럿이 숨긴 `**` 사이에 앉는다
  x=100 → 1
```

`굵게` 안에 커서를 놓을 방법이 **아예 없다.** 그리고 보이는 텍스트 뒤를 클릭한 뒤 타이핑하면
`*X*굵게**`가 된다.

원인은 표시 문자열이 백킹 문자열보다 짧아지면서 두 좌표계가 갈라지는 것이다.
`documentRange` 길이는 6으로 유지되지만(백킹 좌표계) 실제 레이아웃은 4글자뿐이라
매핑이 단사(injective)가 아니게 되고, **TextKit 2는 이 둘을 화해시켜 주지 않는다.**

**결론: 작은 폰트(0.01pt)로 접는다.** 글자가 백킹에도 레이아웃에도 그대로 남아 있으므로
좌표계가 하나로 유지된다. 대가는 숨긴 마커 위에서 화살표를 누르면 캐럿이 제자리처럼 보이는
것인데, 이것은 라이브 프리뷰 에디터들이 공통으로 받아들이는 절충이다.

### 5. 줄 전체가 마커면 줄 높이가 0으로 붕괴한다 — `minimumLineHeight`로 구제된다

```
보통 줄                        : 17.00
``` 숨김, minimumLineHeight 없음 :  0.00   ← 줄이 사라진다
``` 숨김, minimumLineHeight=17   : 17.00   구제됨
마커 섞인 줄 (**굵게**)          : 17.00   보통 줄과 같음 — 작은 폰트가 줄 높이를 안 건드린다
```

**결과: 모든 문단에 `minimumLineHeight`를 넣는다.** 이건 어차피 일관된 줄 간격을 위해 필요한
것이고, 부수적으로 이 붕괴를 막아 준다. 이게 있으면 "줄 전체가 마커인 경우는 숨기면 안 된다"는
제약이 메커니즘 차원에서 사라지고, 펜스 줄을 보일지 말지는 순수한 제품 선택이 된다.

### 6. 속성만 바꾸는 편집은 `.editedCharacters`를 발화하지 않는다 — 재귀가 막힌다

```
글자 삽입 1회   → editedCharacters +1, editedAttributes 0
속성 적용 1회   → editedCharacters  0, editedAttributes +1
begin/endEditing으로 묶은 속성 5회 → 델리게이트 호출 1회 (배칭됨)
```

**결과: `didProcessEditing`에서 `.editedCharacters`만 보고 재스타일하면 무한 재귀가 없다.**
프로브에서 15글자를 타이핑하니 스타일 패스가 정확히 15회, 재진입 0회였다.
그리고 `beginEditing`/`endEditing`으로 묶으면 델리게이트가 한 번만 불린다 — 반드시 묶는다.

### 7. 속성 적용은 싸고, 파싱이 비싸다

`NSTextStorage` 속성 적용 (275K UTF-16 유닛, 13,745개 스팬, 배칭):

```
setAttributedString      :  0.4 ms
전체 재스타일            :  5.9 ms
앞 3000자 레이아웃        :  7.0 ms   (레이아웃은 게으르다 — 보이는 곳만 한다)
```

`MarkdownSyntaxMap.build` (실제 코드로 측정):

| 문서 크기 | 스팬 수 | build | 키입력당 |
|---|---|---|---|
| 3 KB | 260 | 2.3 ms | 1.6 ms |
| 32 KB | 2,600 | 16.2 ms | 15.5 ms |
| 325 KB | 26,000 | 158.3 ms | **154.6 ms** |

**병목은 속성 적용이 아니라 파싱이다** (5.9ms vs 155ms). 이것이 두 가지를 정한다:

1. **v1은 전체 재파싱으로 간다.** 일반적인 마크다운 파일(1~20KB)에서 키입력당 10ms 이하다.
   `MarkdownSyntaxMap.rebuild`를 블록 단위로 최적화하는 것은 여전히 옳지만 지금은 아니다.
2. **재스타일은 반드시 합쳐야(coalesce) 한다.** 32KB에서 이미 16ms 프레임 예산에 닿는다.
   빠르게 타이핑할 때 글자마다 파싱하면 안 된다. 다음 런루프로 합친다 (Task 3).

임계값을 숫자로 남겨 둔다: **이 표에서 32KB가 손익분기점이다.** 증분 재파싱을 언제 해야
하는지 묻는 미래의 우리에게 답이 된다.

## 마커 노출 정책: 줄 기준

커서가 어디 있을 때 마커를 보여줄 것인가. **커서가 있는 줄의 마커를 모두 노출한다.**

검토한 대안은 "커서가 그 구문(construct) 범위 안에 있을 때"인데, `StyleSpan`은 마커 자신의
범위만 들고 있어서 `**굵게**` 전체 범위를 복원할 수 없다. 같은 `kind`의 인접 스팬을 짝지어
추측할 수는 있지만 깨지기 쉽다. `StyleSpan`에 구문 범위를 추가하는 방법도 있으나 Plan 1의
커밋된 타입을 넓히는 대가를 치른다.

줄 기준은 추가 정보가 필요 없고(문자열에서 줄 범위를 계산하면 된다), 블록 마커(`#`, `>`, `-`)를
자연스럽게 다루고, 한 줄에 여러 구문이 있어도 균일하게 동작한다. 실제 사용감도 Bear/Obsidian과
비슷하다 — 줄을 편집하면 그 줄의 문법이 드러난다. 한계는 여러 줄에 걸친 구문인데
(`**여러\n줄**`) 드물고, 그 경우에도 현재 줄의 마커만 노출하는 동작은 합리적이다.

정책이 `LiveStyleApplier` 한 곳에 있으므로 나중에 구문 기준으로 바꾸려면 함수 하나만 고친다.

**숨기는 마커 / 늘 보이는 마커:**

| kind | 처리 | 이유 |
|---|---|---|
| `heading` | 숨김 | `# `이 사라지면 큰 제목만 남는다 |
| `strong`, `emphasis` | 숨김 | 라이브 프리뷰의 핵심 |
| `inlineCode` | 숨김 | 백틱 없이 고정폭 배경만 |
| `link` | 흐리게 | v1은 숨기지 않는다. `](url)`을 접는 건 별도 처리가 필요하다 |
| `codeBlock` (펜스) | 흐리게 | 언어 표시를 겸하고 구조적 손잡이다 |
| `listItemMarker` | 흐리게 | 불릿 자체가 시각적 내용이다 |
| `blockQuote` | 흐리게 | 들여쓰기 표현이 v1에 없으므로 마커가 유일한 단서다 |

## 스팬 겹침과 폰트 합성

`MarkdownSyntaxMap.build`는 스팬을 `(시작 오름차순, 끝 내림차순)`으로 정렬해 낸다 — **넓은 것이
먼저 온다.** 순서대로 적용하면 좁은 스팬이 넓은 스팬을 덮어쓴다. 이 정렬이 여기서 값을 한다.

단, 폰트는 덮어쓰면 안 되고 **합성**해야 한다. `## **굵은** 제목`에서 `strong`이 폰트를
그냥 갈아치우면 헤딩 크기가 사라진다. 따라서 `strong`/`emphasis`는 `enumerateAttribute(.font:)`로
현재 폰트를 읽어 트레이트만 더한다.

## File Structure

```
Sources/EditorKit/
  Theme.swift              폰트·색·줄높이 값 타입
  LiveStyleApplier.swift   [StyleSpan] + 선택 → NSTextStorage 속성 (정책이 여기)
  EditorTextView.swift     NSTextView(TextKit 2) 조립

Tests/EditorKitTests/
  LiveStyleApplierTests.swift
  EditorTextViewTests.swift

docs/manual-test-checklist.md   한글 IME·언두 (자동화 불가)
```

---

## Task 1: Theme — 스타일 값 모음

**Files:**
- Modify: `Package.swift`
- Create: `Sources/EditorKit/Theme.swift`
- Test: `Tests/EditorKitTests/ThemeTests.swift`

**Interfaces:**
- Consumes: AppKit
- Produces:
  - `public struct Theme`
    - `public var bodyFont: NSFont`, `monoFont: NSFont`
    - `public var textColor: NSColor`, `markerColor: NSColor`, `linkColor: NSColor`, `codeBackgroundColor: NSColor`
    - `public var minimumLineHeight: CGFloat`
    - `public func headingFont(level: Int) -> NSFont`
    - `public static let `default`: Theme`
  - `internal static let hiddenFontSize: CGFloat = 0.01` (사실 3번)

- [ ] **Step 1: Write the failing test**

`Package.swift`에 타깃을 추가한다:

```swift
        .library(name: "EditorKit", targets: ["EditorKit"]),
```
를 `products`에, `targets`에:
```swift
        // UI 레이어. AppKit을 쓰므로 헤드리스 규칙이 적용되지 않는다.
        .target(name: "EditorKit", dependencies: ["MarkdownSyntax"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
```

`Tests/EditorKitTests/ThemeTests.swift`:

```swift
import XCTest
import AppKit
@testable import EditorKit

final class ThemeTests: XCTestCase {

    func testHeadingFontsDecreaseByLevel() {
        let theme = Theme.default
        let sizes = (1...6).map { theme.headingFont(level: $0).pointSize }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "레벨이 깊어질수록 작아져야 한다")
        XCTAssertGreaterThan(sizes[5], theme.bodyFont.pointSize,
                             "h6도 본문보다는 커야 한다")
    }

    func testHeadingFontIsBold() {
        let f = Theme.default.headingFont(level: 1)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testHeadingLevelIsClampedNotCrashing() {
        // 파서가 1...6만 낸다고 믿지 않는다. 방어적으로 고정한다.
        XCTAssertEqual(Theme.default.headingFont(level: 0).pointSize,
                       Theme.default.headingFont(level: 1).pointSize)
        XCTAssertEqual(Theme.default.headingFont(level: 99).pointSize,
                       Theme.default.headingFont(level: 6).pointSize)
    }

    func testMonoFontIsFixedPitch() {
        XCTAssertTrue(Theme.default.monoFont.isFixedPitch)
    }
}
```

`swift test --filter ThemeTests` → 컴파일 실패 (Theme 없음).

- [ ] **Step 2: Implement**

`Sources/EditorKit/Theme.swift`. `headingFont(level:)`은 `max(1, min(6, level))`로 고정한다.
고정폭 폰트는 `NSFont.monospacedSystemFont(ofSize:weight:)`를 쓴다.

- [ ] **Step 3: Verify** — `swift test --filter ThemeTests` 초록.

---

## Task 2: LiveStyleApplier — 스팬 + 선택 → 속성

정책 전부가 여기 있다. `NSTextView` 없이 맨 `NSTextStorage`로 테스트한다.

**Files:**
- Create: `Sources/EditorKit/LiveStyleApplier.swift`
- Test: `Tests/EditorKitTests/LiveStyleApplierTests.swift`

**Interfaces:**
- Consumes: `MarkdownSyntax.StyleSpan`, `Theme`, AppKit
- Produces:
  - `public struct LiveStyleApplier`
    - `public init(theme: Theme = .default)`
    - `public func apply(spans: [StyleSpan], selection: NSRange, to storage: NSTextStorage)`
    - `public static func isHidable(_ kind: StyleSpan.Kind) -> Bool` (위 표. 테스트가 직접 찌른다)

- [ ] **Step 1: Write the failing test**

`Tests/EditorKitTests/LiveStyleApplierTests.swift`:

```swift
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

    // MARK: - 원문 불변 (AD-2의 핵심 계약)

    func testSourceTextIsNeverModified() {
        let source = "# 제목\n**굵게** 그리고 `코드`\n- 항목\n> 인용\n"
        let storage = styled(source, caretAt: 0)
        XCTAssertEqual(storage.string, source,
                       "스타일링은 속성만 입힌다. 원문이 바뀌면 무손실 왕복이 깨진다")
    }

    // MARK: - 마커 노출 정책 (줄 기준)

    func testMarkersHiddenWhenCaretOnAnotherLine() {
        //  0123456789
        // "**굵게**\n둘째 줄"
        let storage = styled("**굵게**\n둘째 줄", caretAt: 8)  // 둘째 줄
        XCTAssertTrue(isHidden(storage, at: 0), "다른 줄에 커서가 있으면 앞 ** 숨김")
        XCTAssertTrue(isHidden(storage, at: 5), "뒤 ** 도 숨김")
        XCTAssertFalse(isHidden(storage, at: 2), "내용은 숨기지 않는다")
    }

    func testMarkersRevealedWhenCaretOnSameLine() {
        let storage = styled("**굵게**\n둘째 줄", caretAt: 3)  // 첫째 줄 안
        XCTAssertFalse(isHidden(storage, at: 0), "같은 줄이면 마커를 보여준다")
        XCTAssertFalse(isHidden(storage, at: 5))
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
        let thirdLineStart = (source as NSString).range(of: "**셋**").location
        XCTAssertTrue(isHidden(storage, at: thirdLineStart), "닿지 않은 줄은 숨김")
    }

    // MARK: - 늘 보이는 마커

    func testCodeFenceMarkerIsNeverHidden() {
        let source = "```swift\nlet x = 1\n```\n\n본문"
        let storage = styled(source, caretAt: (source as NSString).range(of: "본문").location)
        XCTAssertFalse(isHidden(storage, at: 0),
                       "펜스는 커서가 멀어도 보인다 — 언어 표시를 겸한다")
    }

    func testListAndQuoteMarkersAreNeverHidden() {
        let source = "- 항목\n> 인용\n\n본문"
        let storage = styled(source, caretAt: (source as NSString).range(of: "본문").location)
        XCTAssertFalse(isHidden(storage, at: 0), "리스트 마커는 보인다")
        let quote = (source as NSString).range(of: ">").location
        XCTAssertFalse(isHidden(storage, at: quote), "인용 마커는 보인다")
    }

    // MARK: - 내용 스타일

    func testHeadingContentIsLargerThanBody() {
        let source = "# 제목\n\n본문"
        let storage = styled(source, caretAt: (source as NSString).range(of: "본문").location)
        let titleSize = fontSize(storage, at: (source as NSString).range(of: "제목").location)
        let bodySize = fontSize(storage, at: (source as NSString).range(of: "본문").location)
        XCTAssertGreaterThan(titleSize, bodySize)
    }

    func testStrongInsideHeadingKeepsHeadingSize() {
        // 폰트를 덮어쓰지 않고 합성하는지 — 겹침 처리의 핵심
        let source = "## **굵은** 제목"
        let storage = styled(source, caretAt: 0)
        let strongAt = (source as NSString).range(of: "굵은").location
        let plainAt = (source as NSString).range(of: "제목").location
        let strongFont = storage.attribute(.font, at: strongAt, effectiveRange: nil) as! NSFont
        XCTAssertEqual(strongFont.pointSize, fontSize(storage, at: plainAt),
                       "strong이 헤딩 크기를 덮어쓰면 안 된다")
        XCTAssertTrue(strongFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testEmphasisIsItalic() {
        let source = "*기울임*"
        let storage = styled(source, caretAt: 20)
        let f = storage.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testInlineCodeUsesMonospacedFont() {
        let source = "`코드`"
        let storage = styled(source, caretAt: 20)
        let f = storage.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.isFixedPitch)
    }

    // MARK: - 줄 높이 붕괴 방지 (사실 5번)

    func testEveryParagraphHasMinimumLineHeight() {
        let storage = styled("# 제목\n\n본문\n```\n코드\n```\n", caretAt: 0)
        storage.enumerateAttribute(.paragraphStyle,
                                   in: NSRange(location: 0, length: storage.length),
                                   options: []) { value, range, _ in
            let ps = value as? NSParagraphStyle
            XCTAssertNotNil(ps, "range \(range)에 문단 스타일이 없다")
            XCTAssertEqual(ps?.minimumLineHeight, Theme.default.minimumLineHeight,
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
        applier.apply(spans: spans, selection: NSRange(location: 8, length: 0), to: storage)
        XCTAssertTrue(isHidden(storage, at: 0), "이전 패스의 노출 상태가 남으면 안 된다")
    }

    // MARK: - 좌표계 안전 (Plan 1과 같은 위험)

    func testHandlesKoreanAndEmojiWithoutRangeError() {
        // 한글·이모지가 섞여도 NSRange 예외 없이 끝나야 한다.
        let source = "# 한글 제목 🇰🇷\n**굵게** 이모지 👨‍👩‍👧‍👦 그리고 `코드`\n"
        let storage = NSTextStorage(string: source)
        applier.apply(spans: MarkdownSyntaxMap.build(from: source),
                      selection: NSRange(location: 0, length: 0), to: storage)
        XCTAssertEqual(storage.string, source)
    }

    func testEmptyDocumentDoesNotCrash() {
        let storage = NSTextStorage(string: "")
        applier.apply(spans: [], selection: NSRange(location: 0, length: 0), to: storage)
        XCTAssertEqual(storage.length, 0)
    }
}
```

`swift test --filter LiveStyleApplierTests` → 컴파일 실패.

- [ ] **Step 2: Implement**

`Sources/EditorKit/LiveStyleApplier.swift`. 순서가 중요하다:

1. `storage.beginEditing()` / `defer { storage.endEditing() }` — 사실 6번대로 반드시 묶는다
2. 전체를 기본 속성으로 초기화 (`setAttributes`) — 폰트, 본문색, `minimumLineHeight`를 담은
   문단 스타일. 이것이 재적용 시 잔여물을 없앤다
3. 활성 줄 범위 = `(storage.string as NSString).lineRange(for: selection)`
4. 스팬을 받은 순서대로 적용 (이미 넓은 것이 먼저다):
   - `.content` → kind별 폰트/색. `strong`/`emphasis`는 `enumerateAttribute(.font:)`로 합성
   - `.marker` → 숨김 대상이고 활성 줄과 겹치지 않으면 `Theme.hiddenFontSize` 폰트,
     그 외에는 `markerColor`
5. 빈 스토리지는 2번에서 곧바로 빠져나온다

- [ ] **Step 3: Verify** — `swift test --filter LiveStyleApplierTests` 초록.

- [ ] **Step 4: Commit**

```
feat: add LiveStyleApplier with line-based marker reveal policy
```

---

## Task 3: EditorTextView — NSTextView 조립

**Files:**
- Create: `Sources/EditorKit/EditorTextView.swift`
- Test: `Tests/EditorKitTests/EditorTextViewTests.swift`

**Interfaces:**
- Consumes: `LiveStyleApplier`, `MarkdownSyntax.MarkdownSyntaxMap`, AppKit
- Produces:
  - `public final class EditorTextView: NSTextView`
    - `public init(theme: Theme = .default)`
    - `public var theme: Theme` (설정 시 재스타일)
    - `public func setMarkdown(_ text: String)` — 문서 교체 (파일 열기·외부 리로드용)
    - `public var onTextChange: ((String) -> Void)?` — 상위가 `MarkdownDocument`에 연결한다
    - `internal func restyleNow()` — 테스트가 합침(coalescing)을 건너뛰게 해 준다

- [ ] **Step 1: Write the failing test**

`Tests/EditorKitTests/EditorTextViewTests.swift`:

```swift
import XCTest
import AppKit
@testable import EditorKit

final class EditorTextViewTests: XCTestCase {

    private func view(_ text: String = "") -> EditorTextView {
        let v = EditorTextView()
        v.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        if !text.isEmpty { v.setMarkdown(text) }
        return v
    }

    private func isHidden(_ v: EditorTextView, at i: Int) -> Bool {
        let f = v.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        return (f?.pointSize ?? 99) < 1.0
    }

    // MARK: - TextKit 2 회귀 방어 (사실 2번)

    /// `layoutManager`를 어디선가 읽으면 조용히 TextKit 1으로 강등된다.
    /// 예외도 경고도 없이 일어나므로 테스트로 못 박는다.
    func testUsesTextKit2AfterConstruction() {
        XCTAssertNotNil(view().textLayoutManager)
    }

    func testUsesTextKit2AfterTypingAndRestyling() {
        let v = view("# 제목\n")
        v.insertText("본문", replacementRange: NSRange(location: v.string.utf16.count, length: 0))
        v.restyleNow()
        XCTAssertNotNil(v.textLayoutManager, "타이핑/재스타일 경로가 TextKit 1으로 떨어뜨렸다")
    }

    // MARK: - 편집이 스타일을 갱신한다

    func testTypingAppliesStyling() {
        let v = view()
        for ch in "# 제목" {
            v.insertText(String(ch),
                         replacementRange: NSRange(location: v.string.utf16.count, length: 0))
        }
        v.restyleNow()
        let titleSize = (v.textStorage?.attribute(
            .font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        XCTAssertGreaterThan(titleSize, Theme.default.bodyFont.pointSize,
                             "타이핑한 헤딩이 커져야 한다")
    }

    func testSetMarkdownReplacesTextAndStyles() {
        let v = view("# 처음\n")
        v.setMarkdown("**나중**\n")
        v.restyleNow()
        XCTAssertEqual(v.string, "**나중**\n")
        XCTAssertTrue(isHidden(v, at: 0), "커서가 0인데 0번 줄이면 노출... 아래 주석 참고")
    }

    func testOnTextChangeFiresOnTyping() {
        let v = view()
        var seen: [String] = []
        v.onTextChange = { seen.append($0) }
        v.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(seen.last, "x")
    }

    func testOnTextChangeDoesNotFireForStylingOnly() {
        // 사실 6번: 속성 적용은 .editedCharacters를 안 낸다. 여기서 못 박는다.
        let v = view("# 제목\n")
        var count = 0
        v.onTextChange = { _ in count += 1 }
        v.restyleNow()
        v.restyleNow()
        XCTAssertEqual(count, 0, "스타일링이 문서 변경으로 보고되면 dirty 플래그가 오염된다")
    }

    // MARK: - 커서 이동이 마커 노출을 바꾼다

    func testMovingCaretRevealsAndHidesMarkers() {
        let v = view("**굵게**\n둘째 줄")
        v.setSelectedRange(NSRange(location: 8, length: 0))   // 둘째 줄
        v.restyleNow()
        XCTAssertTrue(isHidden(v, at: 0))

        v.setSelectedRange(NSRange(location: 1, length: 0))   // 첫째 줄
        v.restyleNow()
        XCTAssertFalse(isHidden(v, at: 0), "커서가 온 줄의 마커가 드러나야 한다")
    }

    // MARK: - 합침 (사실 7번)

    func testRapidTypingCoalescesRestyles() {
        let v = view("# 제목\n")
        let passes = v.restylePassCountForTesting
        for ch in "abcdefghij" {
            v.insertText(String(ch),
                         replacementRange: NSRange(location: v.string.utf16.count, length: 0))
        }
        XCTAssertEqual(v.restylePassCountForTesting, passes,
                       "합침 전에는 즉시 재스타일하지 않는다 — 32KB에서 글자마다 155ms를 낼 수 없다")
    }

    // MARK: - 원문 불변

    func testStylingNeverChangesText() {
        let source = "# 한글 제목\n**굵게** `코드` 🇰🇷\n- 항목\n"
        let v = view(source)
        v.restyleNow()
        v.setSelectedRange(NSRange(location: 3, length: 0))
        v.restyleNow()
        XCTAssertEqual(v.string, source)
    }
}
```

두 가지를 구현 중에 확정해야 한다:

- `testSetMarkdownReplacesTextAndStyles`의 마지막 단정은 `setMarkdown` 이후 선택을 어디에
  두는지에 달렸다. **`setMarkdown`은 선택을 0으로 초기화한다**고 정하고 (파일을 새로 여는
  것이므로 문서 맨 앞이 맞다), 그러면 0번 줄이 활성이므로 마커가 **노출**된다.
  단정을 `XCTAssertFalse`로 고치고 주석을 정리한다.
- `restylePassCountForTesting`은 `internal var`로 노출한다. 프로덕션 코드에 테스트용 카운터를
  두는 것은 대가가 있지만, 합침은 이 계획에서 성능의 핵심이고 다른 방법으로는 관찰할 수 없다.

`swift test --filter EditorTextViewTests` → 컴파일 실패.

- [ ] **Step 2: Implement**

`Sources/EditorKit/EditorTextView.swift`:

- `init`은 `super.init(usingTextLayoutManager: true)` 경로를 타야 한다.
  `NSTextView`의 지정 이니셜라이저 사정 때문에 `usingTextLayoutManager:`가
  `init(frame:textContainer:)`로 우회될 수 있으니, TextKit 2가 살아 있는지
  Task 3의 첫 테스트로 확인한다 (이미 있다)
- **`layoutManager`를 절대 읽지 않는다.** 사실 2번
- `textStorage.delegate = self`, `didProcessEditing`에서 `.editedCharacters`만 보고
  재스타일을 예약 + `onTextChange` 호출
- `textViewDidChangeSelection`이 아니라 `setSelectedRanges` 오버라이드로 커서 이동을 잡는다
  (자기 자신의 델리게이트가 되면 상위가 델리게이트를 못 쓴다)
- 재스타일 예약은 다음 런루프로 합친다 (`DispatchQueue.main.async` + 예약 플래그).
  활성 줄이 안 바뀐 커서 이동은 재스타일을 건너뛴다
- `restyleNow()`는 예약을 취소하고 즉시 수행한다
- 재스타일 = `MarkdownSyntaxMap.build(from: string)` → `LiveStyleApplier.apply(...)`

- [ ] **Step 3: Verify** — `swift test --filter EditorTextViewTests` 초록. 그다음 전체
  `swift test`로 Plan 1·2의 72개가 여전히 초록인지 확인한다.

- [ ] **Step 4: Commit**

```
feat: add EditorTextView wiring TextKit 2 to live styling
```

---

## Task 4: 수동 테스트 체크리스트

자동화할 수 없는 것들을 문서로 남긴다. 설계 문서 테스트 전략의 마지막 행이 요구한 것이다.

**Files:**
- Create: `docs/manual-test-checklist.md`

- [ ] **Step 1: 작성**

내용:

- **한글 IME 조합** (자동화 불가 — 이 프로젝트에서 자동 검증이 안 되는 유일한 핵심 영역)
  - 조합 중(`ㅎ` → `하` → `한`) 재스타일 패스가 조합을 끊지 않는가
  - 조합 중 커서가 조합 문자 뒤에 머무는가
  - 조합을 마치지 않은 상태로 화살표를 눌렀을 때
  - `**굵게` 를 조합 중일 때 마커가 깜빡이지 않는가
  - 조합 중 외부 파일 변경이 들어왔을 때 (에이전트 협업 경로)
- **언두** (`undoManager`가 헤드리스에서 nil — 사실 1번의 예외)
  - 타이핑 후 ⌘Z가 글자만 되돌리고 스타일이 따라오는가
  - 스타일링 패스가 언두 스택에 별도 항목을 쌓지 않는가 (쌓이면 ⌘Z가 두 번 필요해진다)
- **숨긴 마커 위 캐럿 이동** (사실 4번의 절충이 실제로 견딜 만한가)
  - 숨긴 `**` 위에서 →를 누르면 캐럿이 두 번 제자리처럼 보이는가. 참을 만한가
  - 숨긴 마커를 가로질러 드래그 선택
  - 줄 끝을 클릭했을 때 캐럿이 숨긴 마커 뒤로 가는가
- **큰 문서** (사실 7번의 임계값)
  - 32KB에서 타이핑 지연이 느껴지는가
  - 325KB에서 (측정값 155ms/키) 실제로 못 쓸 정도인가 — 증분 재파싱 착수 근거

- [ ] **Step 2: Commit**

```
docs: add manual test checklist for IME, undo, and hidden-marker caret
```

---

## 이 계획이 남기는 것

- **증분 재파싱은 여전히 미룬다.** 사실 7번이 손익분기점을 32KB로 못 박았다.
  `MarkdownSyntaxMap.rebuild`의 등가성 테스트가 이미 안전망으로 있다
- **링크 마커 접기**는 v1에서 흐리게로 남긴다. `](url)`을 접으려면 `StyleSpan`이 구문
  범위를 알아야 하고, 그건 노출 정책을 구문 기준으로 바꾸는 것과 같은 작업이다
- **표·이미지 블록 위젯**은 설계 문서대로 v1 이후 `NSTextAttachment`로 간다
- Plan 4(SwiftUI 3-모드 + 커맨드 팔레트)에서 처음 Xcode 앱 타깃이 필요해진다
