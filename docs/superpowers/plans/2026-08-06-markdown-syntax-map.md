# MarkdownSyntax Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 마크다운 원문을 받아 라이브 스타일링에 필요한 범위 정보(`[StyleSpan]`)를 내는 순수 함수 레이어를 만든다. UI 없이 `swift test`로 전부 검증된다.

**Architecture:** 설계 문서(`docs/superpowers/specs/2026-08-06-macos-markdown-editor-design.md`) AD-2에 따라 원문이 진실이다. 이 레이어는 원문을 **읽기만** 하고 절대 재직렬화하지 않는다. `swift-markdown`으로 AST를 얻고, AST 노드의 `SourceRange`(1-based line + **1-based UTF-8 byte column**)를 UTF-16 오프셋으로 환산해 `StyleSpan` 배열을 낸다.

**Tech Stack:** Swift 5.9+, macOS 14+, `swiftlang/swift-markdown` (Apache-2.0), XCTest

## Global Constraints

- 최소 플랫폼: `.macOS(.v14)` — `Package.swift`에 이미 설정됨
- 이 타깃은 **AppKit/SwiftUI를 import하지 않는다.** 헤드리스 유지가 테스트 가능성의 근거다
- 런타임 서드파티 의존성은 `swift-markdown` 하나뿐. 새 의존성을 추가하지 않는다
- 재직렬화 금지. `MarkupFormatter`, `format()`, `HTMLFormatter`를 쓰지 않는다 (AD-2 위반)
- 모든 공개 API는 순수 함수 또는 값 타입. 내부 가변 상태 금지
- 테스트 프레임워크는 XCTest (이 저장소에서 동작 확인됨)
- 라이선스: MIT

## 검증된 API 사실 (직접 프로브해서 확인 — 추측 아님)

이 계획의 모든 코드는 아래 사실에 의존한다. 실제 실행 결과로 확인했다.

**1. `SourceLocation.column`은 1-based UTF-8 바이트 오프셋이다.**

| 원문 | Characters | UTF-16 | UTF-8 | `Document.range` |
|---|---|---|---|---|
| `한글 **볼드** 끝` | 11 | 11 | **21** | `1:1-1:22` |
| `👨‍👩‍👧 **x** y` | 9 | 16 | **26** | `1:1-1:27` |

이모지 케이스가 UTF-16 가능성을 배제한다. **`String.index(_:offsetBy:)`를 Character 단위로 쓰면 한글 문서가 전부 깨진다.** 반드시 `String.utf8` 뷰를 경유해야 한다.

**2. `range.upperBound`는 exclusive.** `# Heading one`(13자) → `Heading range=1:1-1:14`.

**3. 컨테이너 range는 마커를 포함하고, 자식 range는 포함하지 않는다.** 따라서 마커는 그 차집합이다:

```
opening marker = C.range.lower ..< firstChild.range.lower
content        = firstChild.range.lower ..< lastChild.range.upper
closing marker = lastChild.range.upper ..< C.range.upper
```

확인된 예:
- `**bold**` → `Strong 3:6-3:14`, `Text 3:8-3:12` → opening `3:6-3:8`, closing `3:12-3:14` ✅
- `한글 **볼드** 끝` → `Strong 1:8-1:18`, `Text 1:10-1:16` → opening 2바이트, closing 2바이트 ✅
- `# Heading one` → `Heading 1:1-1:14`, `Text 1:3-1:14` → opening `1:1-1:3`(`# `), closing **빈 범위** ✅

ATX 헤딩에 닫는 마커가 없는 것이 빈 범위로 자연히 처리된다. **빈 범위는 버린다.**

**4. `InlineCode`와 `CodeBlock`은 자식이 없다.** `` `code` `` → `InlineCode 3:32-3:38` (자식 없음). 규칙 3을 쓸 수 없으므로 원문에서 델리미터를 직접 세야 한다.

**5. 좌표계 결정.** `StyleSpan.range`는 **UTF-16 코드 유닛 오프셋의 `Range<Int>`**로 낸다. 이유: 최종 소비자가 `NSTextStorage`이고 `NSRange`가 UTF-16 기반이므로 AppKit 경계에서 변환 없이 `NSRange(location:length:)`로 바로 쓸 수 있다. 동시에 이 타깃은 Foundation만 쓰고 AppKit에 의존하지 않는다.

## File Structure

```
Sources/MarkdownSyntax/
  SourceOffsetMap.swift      line + UTF-8 byte column → UTF-16 오프셋 변환. 이 파일만 좌표계를 안다
  StyleSpan.swift            출력 값 타입 (Kind, Role, range)
  SpanCollector.swift        MarkupWalker. AST를 훑어 StyleSpan을 모은다
  MarkdownSyntaxMap.swift    공개 진입점. build / rebuild
Tests/MarkdownSyntaxTests/
  SourceOffsetMapTests.swift
  StyleSpanTests.swift
  SpanCollectorTests.swift
  IncrementalEquivalenceTests.swift
```

책임 분리의 핵심: **좌표계 변환을 `SourceOffsetMap` 한 곳에 격리한다.** UTF-8/UTF-16 혼동이 이 프로젝트의 가장 큰 버그 원천이므로, 그 지식이 여러 파일로 새면 안 된다.

---

### Task 1: SourceOffsetMap — 좌표계 변환

이 태스크가 프로젝트 전체에서 가장 위험한 로직이다. 먼저 못 박는다.

**Files:**
- Create: `Sources/MarkdownSyntax/SourceOffsetMap.swift`
- Test: `Tests/MarkdownSyntaxTests/SourceOffsetMapTests.swift`

**Interfaces:**
- Consumes: 없음 (Foundation만)
- Produces:
  - `public struct SourceOffsetMap`
  - `public init(source: String)`
  - `public func utf16Offset(line: Int, utf8Column: Int) -> Int?` — 1-based line/column을 받아 문서 시작부터의 UTF-16 오프셋을 낸다. 범위를 벗어나거나 스칼라 경계를 침범하면 `nil`

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/SourceOffsetMapTests.swift`:

```swift
import XCTest
@testable import MarkdownSyntax

final class SourceOffsetMapTests: XCTestCase {

    func testASCIISingleLine() {
        let map = SourceOffsetMap(source: "ab **cd** ef")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 4), 3)   // '*' 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 13), 12) // 문서 끝
    }

    /// 회귀 방지의 핵심. column은 UTF-8 바이트인데 결과는 UTF-16이어야 한다.
    /// "한글 " = 7 UTF-8 바이트지만 UTF-16으로는 3 유닛이다.
    func testKoreanColumnIsUTF8ButResultIsUTF16() {
        let map = SourceOffsetMap(source: "한글 **볼드** 끝")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 8), 3)   // Strong 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 10), 5)  // 내부 Text 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 16), 7)  // 내부 Text 끝
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 18), 9)  // Strong 끝
    }

    /// 👨‍👩‍👧 = 1 Character, 8 UTF-16 유닛, 18 UTF-8 바이트.
    /// Character 단위 오프셋으로 구현하면 여기서 무너진다.
    func testEmojiGrapheme() {
        let map = SourceOffsetMap(source: "👨‍👩‍👧 **x** y")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 20), 9)  // Strong 시작
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 22), 11) // 내부 Text 시작
    }

    func testMultipleLines() {
        let map = SourceOffsetMap(source: "one\ntwo\nthree")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 4)
        XCTAssertEqual(map.utf16Offset(line: 3, utf8Column: 1), 8)
        XCTAssertEqual(map.utf16Offset(line: 3, utf8Column: 6), 13)
    }

    func testMultilineWithKorean() {
        let map = SourceOffsetMap(source: "제목\n본문 텍스트")
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 3)  // "제목\n" = UTF-16 3
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 7), 5)  // "본문 " 뒤
    }

    func testCRLFLineEndings() {
        let map = SourceOffsetMap(source: "one\r\ntwo")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, utf8Column: 1), 5)  // "one\r\n" = 5 유닛
    }

    func testOutOfRangeReturnsNil() {
        let map = SourceOffsetMap(source: "abc")
        XCTAssertNil(map.utf16Offset(line: 0, utf8Column: 1))   // line은 1-based
        XCTAssertNil(map.utf16Offset(line: 99, utf8Column: 1))
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 0))   // column은 1-based
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 99))
    }

    /// 스칼라 중간을 가리키면 유효한 인덱스가 아니므로 nil이어야 한다.
    /// "한"은 3바이트이므로 column 2는 그 중간이다.
    func testMidScalarReturnsNil() {
        let map = SourceOffsetMap(source: "한글")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 2))
        XCTAssertNil(map.utf16Offset(line: 1, utf8Column: 3))
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 4), 1)  // "글" 시작
    }

    func testEmptySource() {
        let map = SourceOffsetMap(source: "")
        XCTAssertEqual(map.utf16Offset(line: 1, utf8Column: 1), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SourceOffsetMapTests`
Expected: 컴파일 실패 — `cannot find 'SourceOffsetMap' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/SourceOffsetMap.swift`:

```swift
import Foundation

/// swift-markdown의 `SourceLocation` 좌표를 UTF-16 오프셋으로 환산한다.
///
/// swift-markdown은 위치를 **1-based 줄 번호 + 1-based UTF-8 바이트 열**로 준다.
/// 반면 `NSTextStorage`/`NSRange`는 UTF-16 코드 유닛으로 동작한다. 이 두 좌표계를
/// 섞으면 ASCII 문서에서는 우연히 맞고 한글·이모지 문서에서 조용히 깨진다.
/// 그 변환 지식을 이 타입 하나에 격리해 둔다.
public struct SourceOffsetMap {

    /// 각 줄의 시작 위치. 줄 번호(1-based)에서 1을 뺀 값이 인덱스다.
    private let lineStarts: [String.Index]
    /// 각 줄 시작의 문서 기준 UTF-16 오프셋.
    private let lineStartUTF16: [Int]
    private let source: String

    public init(source: String) {
        self.source = source

        var starts: [String.Index] = [source.startIndex]
        var startsUTF16: [Int] = [0]

        // 줄 나누기를 직접 한다. `split`이나 `components`는 CRLF와 마지막 빈 줄을
        // 우리가 원하는 방식으로 다루지 않는다. swift-markdown은 \n을 줄 구분자로
        // 세므로 \r은 줄 내용의 일부로 남겨 둔다 (CRLF 테스트가 이를 고정한다).
        var i = source.startIndex
        var utf16Count = 0
        while i < source.endIndex {
            let ch = source[i]
            let next = source.index(after: i)
            utf16Count += String(ch).utf16.count
            if ch == "\n" {
                starts.append(next)
                startsUTF16.append(utf16Count)
            }
            i = next
        }

        self.lineStarts = starts
        self.lineStartUTF16 = startsUTF16
    }

    /// 1-based 줄 번호와 1-based UTF-8 바이트 열을 문서 기준 UTF-16 오프셋으로 바꾼다.
    ///
    /// 범위를 벗어나거나, 열이 유니코드 스칼라 중간을 가리키면 `nil`을 낸다.
    public func utf16Offset(line: Int, utf8Column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, utf8Column >= 1 else { return nil }

        let lineStart = lineStarts[line - 1]
        let byteOffsetInLine = utf8Column - 1

        // 줄 시작을 UTF-8 뷰 좌표로 옮기고, 바이트 단위로 전진한다.
        let utf8LineStart = lineStart.samePosition(in: source.utf8)!
        guard let utf8Target = source.utf8.index(
            utf8LineStart, offsetBy: byteOffsetInLine, limitedBy: source.utf8.endIndex
        ) else {
            return nil
        }

        // 스칼라 경계가 아니면 nil. 여기가 방어선이다.
        guard let target = String.Index(utf8Target, within: source) else { return nil }

        // 다음 줄 시작을 넘어갔으면 그 열은 이 줄에 없다.
        if line < lineStarts.count, target > lineStarts[line] { return nil }

        return lineStartUTF16[line - 1]
            + source.utf16.distance(
                from: lineStart.samePosition(in: source.utf16)!,
                to: target.samePosition(in: source.utf16)!
            )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SourceOffsetMapTests`
Expected: 10개 테스트 전부 PASS

`testMidScalarReturnsNil`이나 `testEmojiGrapheme`이 실패하면 구현이 Character 오프셋으로 새고 있다는 뜻이다. 되돌려서 UTF-8 뷰를 경유하도록 고친다.

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/SourceOffsetMap.swift Tests/MarkdownSyntaxTests/SourceOffsetMapTests.swift
git commit -m "feat: add SourceOffsetMap for UTF-8 column to UTF-16 offset conversion"
```

---

### Task 2: StyleSpan 값 타입

**Files:**
- Create: `Sources/MarkdownSyntax/StyleSpan.swift`
- Test: `Tests/MarkdownSyntaxTests/StyleSpanTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `public struct StyleSpan: Equatable, Sendable`
  - `public enum StyleSpan.Kind: Equatable, Sendable` — `heading(level: Int)`, `strong`, `emphasis`, `inlineCode`, `codeBlock(language: String?)`, `link(destination: String?)`, `listItemMarker`, `blockQuote`
  - `public enum StyleSpan.Role: Equatable, Sendable` — `content`, `marker`
  - `public let kind: Kind`, `public let role: Role`, `public let range: Range<Int>` (UTF-16 오프셋)
  - `public init(kind: Kind, role: Role, range: Range<Int>)`

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/StyleSpanTests.swift`:

```swift
import XCTest
@testable import MarkdownSyntax

final class StyleSpanTests: XCTestCase {

    func testEquatable() {
        let a = StyleSpan(kind: .strong, role: .marker, range: 0..<2)
        let b = StyleSpan(kind: .strong, role: .marker, range: 0..<2)
        let c = StyleSpan(kind: .strong, role: .content, range: 0..<2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHeadingLevelIsPartOfIdentity() {
        XCTAssertNotEqual(
            StyleSpan(kind: .heading(level: 1), role: .content, range: 0..<5),
            StyleSpan(kind: .heading(level: 2), role: .content, range: 0..<5)
        )
    }

    func testLinkCarriesDestination() {
        let span = StyleSpan(kind: .link(destination: "https://example.com"),
                             role: .content, range: 1..<5)
        guard case .link(let dest) = span.kind else {
            return XCTFail("expected link kind")
        }
        XCTAssertEqual(dest, "https://example.com")
    }

    func testCodeBlockCarriesLanguage() {
        let span = StyleSpan(kind: .codeBlock(language: "swift"),
                             role: .content, range: 0..<10)
        guard case .codeBlock(let lang) = span.kind else {
            return XCTFail("expected codeBlock kind")
        }
        XCTAssertEqual(lang, "swift")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StyleSpanTests`
Expected: 컴파일 실패 — `cannot find 'StyleSpan' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/StyleSpan.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StyleSpanTests`
Expected: 4개 테스트 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/StyleSpan.swift Tests/MarkdownSyntaxTests/StyleSpanTests.swift
git commit -m "feat: add StyleSpan value type"
```

---

### Task 3: SpanCollector — 헤딩과 인라인 강조

마커 = 컨테이너와 자식의 차집합 규칙을 여기서 구현한다. 헤딩·Strong·Emphasis·Link가 모두 같은 규칙을 쓴다.

**Files:**
- Create: `Sources/MarkdownSyntax/SpanCollector.swift`
- Test: `Tests/MarkdownSyntaxTests/SpanCollectorTests.swift`

**Interfaces:**
- Consumes: `SourceOffsetMap` (Task 1), `StyleSpan` (Task 2)
- Produces:
  - `struct SpanCollector: MarkupWalker` (internal)
  - `init(offsetMap: SourceOffsetMap, source: String)`
  - `var spans: [StyleSpan]` — 방문 후 수집 결과
  - `mutating func collect(from document: Document) -> [StyleSpan]`

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/SpanCollectorTests.swift`:

```swift
import XCTest
import Markdown
@testable import MarkdownSyntax

final class SpanCollectorTests: XCTestCase {

    /// 테스트 헬퍼. 원문을 파싱해 스팬을 낸다.
    private func spans(_ source: String) -> [StyleSpan] {
        let doc = Document(parsing: source)
        var collector = SpanCollector(offsetMap: SourceOffsetMap(source: source), source: source)
        return collector.collect(from: doc)
    }

    private func span(_ spans: [StyleSpan], kind: StyleSpan.Kind, role: StyleSpan.Role) -> StyleSpan? {
        spans.first { $0.kind == kind && $0.role == role }
    }

    func testATXHeadingMarkerAndContent() {
        let result = spans("# Heading one")
        // "# " 가 마커, "Heading one" 이 내용
        XCTAssertEqual(span(result, kind: .heading(level: 1), role: .marker)?.range, 0..<2)
        XCTAssertEqual(span(result, kind: .heading(level: 1), role: .content)?.range, 2..<13)
    }

    func testHeadingLevelIsCaptured() {
        let result = spans("### Third")
        XCTAssertEqual(span(result, kind: .heading(level: 3), role: .marker)?.range, 0..<4)
        XCTAssertEqual(span(result, kind: .heading(level: 3), role: .content)?.range, 4..<9)
    }

    func testStrongMarkersOnBothSides() {
        let result = spans("ab **cd** ef")
        let markers = result.filter { $0.kind == .strong && $0.role == .marker }
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [3..<5, 7..<9])
        XCTAssertEqual(span(result, kind: .strong, role: .content)?.range, 5..<7)
    }

    func testEmphasis() {
        let result = spans("a *b* c")
        let markers = result.filter { $0.kind == .emphasis && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [2..<3, 4..<5])
        XCTAssertEqual(span(result, kind: .emphasis, role: .content)?.range, 3..<4)
    }

    /// 회귀 방지의 핵심. 한글에서도 마커 범위가 UTF-16으로 정확해야 한다.
    /// "한글 **볼드** 끝" → UTF-16으로 Strong은 3..<9, 내부 텍스트는 5..<7
    func testKoreanStrongRangesAreUTF16() {
        let result = spans("한글 **볼드** 끝")
        let markers = result.filter { $0.kind == .strong && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [3..<5, 7..<9])
        XCTAssertEqual(span(result, kind: .strong, role: .content)?.range, 5..<7)
    }

    func testLinkCapturesDestinationAndMarkers() {
        let result = spans("[link](https://example.com)")
        let content = result.first {
            if case .link = $0.kind, $0.role == .content { return true }
            return false
        }
        XCTAssertEqual(content?.range, 1..<5)  // "link"
        guard case .link(let dest)? = content?.kind else {
            return XCTFail("expected link kind with destination")
        }
        XCTAssertEqual(dest, "https://example.com")

        let markers = result.filter {
            if case .link = $0.kind, $0.role == .marker { return true }
            return false
        }
        // "[" 와 "](https://example.com)"
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [0..<1, 5..<27])
    }

    /// 빈 마커 범위는 버려야 한다. Setext 헤딩은 여는 마커가 없다.
    func testEmptyMarkerRangesAreDropped() {
        let result = spans("Title\n=====")
        XCTAssertFalse(result.contains { $0.range.isEmpty })
    }

    func testNestedEmphasisInsideStrong() {
        let result = spans("**a *b* c**")
        XCTAssertEqual(result.filter { $0.kind == .strong && $0.role == .marker }.count, 2)
        XCTAssertEqual(result.filter { $0.kind == .emphasis && $0.role == .marker }.count, 2)
    }

    func testPlainTextProducesNoSpans() {
        XCTAssertTrue(spans("just plain text").isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpanCollectorTests`
Expected: 컴파일 실패 — `cannot find 'SpanCollector' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/SpanCollector.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpanCollectorTests`
Expected: 10개 테스트 PASS

`testKoreanStrongRangesAreUTF16`이 실패하면 Task 1로 돌아간다 — 좌표 변환이 새고 있다.

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/SpanCollector.swift Tests/MarkdownSyntaxTests/SpanCollectorTests.swift
git commit -m "feat: collect heading and inline emphasis spans"
```

---

### Task 4: InlineCode와 CodeBlock — 자식 없는 노드

검증된 사실 4번에 따라 이 두 노드는 자식이 없으므로 차집합 규칙을 쓸 수 없다. 원문에서 델리미터를 직접 센다.

**Files:**
- Modify: `Sources/MarkdownSyntax/SpanCollector.swift`
- Test: `Tests/MarkdownSyntaxTests/SpanCollectorTests.swift` (테스트 추가)

**Interfaces:**
- Consumes: Task 3의 `SpanCollector`
- Produces: `visitInlineCode`, `visitCodeBlock` 추가. 새 공개 API 없음

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/SpanCollectorTests.swift`에 추가:

```swift
    func testInlineCodeSingleBacktick() {
        let result = spans("a `code` b")
        let markers = result.filter { $0.kind == .inlineCode && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [2..<3, 7..<8])
        XCTAssertEqual(span(result, kind: .inlineCode, role: .content)?.range, 3..<7)
    }

    func testInlineCodeDoubleBacktick() {
        let result = spans("a ``co`de`` b")
        let markers = result.filter { $0.kind == .inlineCode && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [2..<4, 9..<11])
        XCTAssertEqual(span(result, kind: .inlineCode, role: .content)?.range, 4..<9)
    }

    func testFencedCodeBlockCapturesLanguageAndFences() {
        let source = "```swift\nlet x = 1\n```"
        let result = spans(source)
        let content = result.first {
            if case .codeBlock = $0.kind, $0.role == .content { return true }
            return false
        }
        guard case .codeBlock(let lang)? = content?.kind else {
            return XCTFail("expected codeBlock kind")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(content?.range, 9..<19)  // "let x = 1\n"

        let markers = result.filter {
            if case .codeBlock = $0.kind, $0.role == .marker { return true }
            return false
        }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [0..<9, 19..<22])  // "```swift\n" 와 "```"
    }

    func testIndentedCodeBlockHasNoFenceMarkers() {
        let result = spans("    indented\n")
        let markers = result.filter {
            if case .codeBlock = $0.kind, $0.role == .marker { return true }
            return false
        }
        XCTAssertTrue(markers.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpanCollectorTests`
Expected: `testInlineCodeSingleBacktick` 등 4개 FAIL — 스팬이 수집되지 않아 `nil`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/SpanCollector.swift`의 `// MARK: - 방문` 절에 추가:

```swift
    /// `InlineCode`는 자식이 없어서 차집합 규칙을 쓸 수 없다.
    /// 원문에서 백틱 런의 길이를 직접 세어 델리미터를 가른다.
    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let outer = utf16Range(inlineCode.range) else { return }

        let units = Array(source.utf16)
        guard outer.upperBound <= units.count else { return }

        let backtick = UInt16(UnicodeScalar("`").value)
        var fence = 0
        while outer.lowerBound + fence < outer.upperBound,
              units[outer.lowerBound + fence] == backtick {
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
        guard let outer = utf16Range(codeBlock.range) else { return }
        let kind = StyleSpan.Kind.codeBlock(language: codeBlock.language)

        let units = Array(source.utf16)
        guard outer.upperBound <= units.count else { return }

        let backtick = UInt16(UnicodeScalar("`").value)
        let tilde = UInt16(UnicodeScalar("~").value)
        let newline = UInt16(UnicodeScalar("\n").value)

        let opener = units[outer.lowerBound]
        guard opener == backtick || opener == tilde else {
            append(kind, .content, outer)  // 들여쓰기 코드블록
            return
        }

        // 여는 펜스는 첫 줄 끝(개행 포함)까지.
        var openEnd = outer.lowerBound
        while openEnd < outer.upperBound, units[openEnd] != newline { openEnd += 1 }
        if openEnd < outer.upperBound { openEnd += 1 }  // 개행 포함

        // 닫는 펜스는 마지막 개행 뒤부터. 없으면 닫는 펜스가 없는 것이다.
        var closeStart = outer.upperBound
        var i = outer.upperBound - 1
        while i >= openEnd {
            if units[i] == newline { closeStart = i + 1; break }
            i -= 1
        }

        append(kind, .marker, outer.lowerBound..<openEnd)
        append(kind, .content, openEnd..<closeStart)
        append(kind, .marker, closeStart..<outer.upperBound)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpanCollectorTests`
Expected: 14개 테스트 전부 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/SpanCollector.swift Tests/MarkdownSyntaxTests/SpanCollectorTests.swift
git commit -m "feat: collect inline code and code block spans"
```

---

### Task 5: 리스트 마커와 인용

**Files:**
- Modify: `Sources/MarkdownSyntax/SpanCollector.swift`
- Test: `Tests/MarkdownSyntaxTests/SpanCollectorTests.swift` (테스트 추가)

**Interfaces:**
- Consumes: Task 4의 `SpanCollector`
- Produces: `visitListItem`, `visitBlockQuote` 추가. 새 공개 API 없음

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/SpanCollectorTests.swift`에 추가:

```swift
    func testUnorderedListMarker() {
        let result = spans("- item one\n- item two")
        let markers = result.filter { $0.kind == .listItemMarker && $0.role == .marker }
        // "- " 두 개
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [0..<2, 11..<13])
    }

    func testOrderedListMarker() {
        let result = spans("1. first\n2. second")
        let markers = result.filter { $0.kind == .listItemMarker && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range).sorted { $0.lowerBound < $1.lowerBound },
                       [0..<3, 9..<12])
    }

    func testBlockQuoteMarker() {
        let result = spans("> quoted")
        let markers = result.filter { $0.kind == .blockQuote && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range), [0..<2])
    }

    func testKoreanListItem() {
        let result = spans("- 한글 항목")
        let markers = result.filter { $0.kind == .listItemMarker && $0.role == .marker }
        XCTAssertEqual(markers.map(\.range), [0..<2])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpanCollectorTests`
Expected: 새 테스트 4개 FAIL — 스팬 없음

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/SpanCollector.swift`의 `// MARK: - 방문` 절에 추가:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpanCollectorTests`
Expected: 18개 테스트 전부 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/SpanCollector.swift Tests/MarkdownSyntaxTests/SpanCollectorTests.swift
git commit -m "feat: collect list item and block quote markers"
```

---

### Task 6: MarkdownSyntaxMap.build — 공개 진입점

**Files:**
- Create: `Sources/MarkdownSyntax/MarkdownSyntaxMap.swift`
- Test: `Tests/MarkdownSyntaxTests/MarkdownSyntaxMapTests.swift`

**Interfaces:**
- Consumes: `SpanCollector` (Task 3–5), `SourceOffsetMap` (Task 1), `StyleSpan` (Task 2)
- Produces:
  - `public enum MarkdownSyntaxMap`
  - `public static func build(from source: String) -> [StyleSpan]` — 오프셋 오름차순, 같은 오프셋이면 넓은 범위가 먼저

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/MarkdownSyntaxMapTests.swift`:

```swift
import XCTest
@testable import MarkdownSyntax

final class MarkdownSyntaxMapTests: XCTestCase {

    func testEmptySourceProducesNoSpans() {
        XCTAssertTrue(MarkdownSyntaxMap.build(from: "").isEmpty)
    }

    func testSpansAreSortedByOffset() {
        let spans = MarkdownSyntaxMap.build(from: "# T\n\n**a** *b* `c`")
        let lowers = spans.map(\.range.lowerBound)
        XCTAssertEqual(lowers, lowers.sorted(), "스팬은 오프셋 오름차순이어야 한다")
    }

    func testNoSpanExceedsSourceLength() {
        let source = "# 제목\n\n**볼드** 그리고 `코드` 끝\n\n- 항목\n"
        let limit = source.utf16.count
        for span in MarkdownSyntaxMap.build(from: source) {
            XCTAssertLessThanOrEqual(span.range.upperBound, limit,
                                     "스팬이 원문 길이를 넘었다: \(span)")
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0)
        }
    }

    func testNoEmptySpans() {
        let source = "# T\n\nTitle\n=====\n\n- a\n"
        XCTAssertFalse(MarkdownSyntaxMap.build(from: source).contains { $0.range.isEmpty })
    }

    /// 결정성 — 같은 입력이면 같은 출력. 순수 함수의 정의다.
    func testDeterministic() {
        let source = "# 제목\n\n**볼드**와 *이탤릭*, `코드`\n\n> 인용\n\n1. 하나\n2. 둘\n"
        XCTAssertEqual(MarkdownSyntaxMap.build(from: source),
                       MarkdownSyntaxMap.build(from: source))
    }

    /// 이 레이어는 원문을 읽기만 한다. 재직렬화하지 않는다 (AD-2).
    /// 다양한 문서에서 크래시 없이 스팬을 내는지만 확인한다.
    func testHandlesVariedCorpusWithoutCrashing() {
        let corpus = [
            "",
            "\n",
            "plain",
            "# h1\n## h2\n### h3\n",
            "**bold** *it* ***both*** `code`\n",
            "- a\n- b\n  - nested\n",
            "1. one\n2. two\n",
            "> quote\n> more\n",
            "```\nplain fence\n```\n",
            "```swift\nlet x = 1\n```\n",
            "    indented code\n",
            "[link](http://a.b) and ![img](c.png)\n",
            "| a | b |\n|---|---|\n| 1 | 2 |\n",
            "한글 문서 **강조** 및 `코드`\n",
            "👨‍👩‍👧 이모지 **강조**\n",
            "line one\r\nline two\r\n",
            "trailing spaces   \n\nand blank lines\n\n\n",
            "\\*escaped\\* not emphasis\n",
        ]
        for source in corpus {
            let spans = MarkdownSyntaxMap.build(from: source)
            let limit = source.utf16.count
            for span in spans {
                XCTAssertLessThanOrEqual(span.range.upperBound, limit,
                                         "범위 초과 — 원문: \(source.debugDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MarkdownSyntaxMapTests`
Expected: 컴파일 실패 — `cannot find 'MarkdownSyntaxMap' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/MarkdownSyntaxMap.swift`:

```swift
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
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: 전체 스위트 PASS (Task 1–6 누적 28개 이상)

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/MarkdownSyntaxMap.swift Tests/MarkdownSyntaxTests/MarkdownSyntaxMapTests.swift
git commit -m "feat: add MarkdownSyntaxMap.build public entry point"
```

---

### Task 7: 증분 rebuild와 등가성 테스트

설계 문서의 성능 리스크 완화 근거다. 증분 최적화가 정확성을 갉아먹지 않음을 테스트로 고정한다.

**Files:**
- Modify: `Sources/MarkdownSyntax/MarkdownSyntaxMap.swift`
- Test: `Tests/MarkdownSyntaxTests/IncrementalEquivalenceTests.swift`

**Interfaces:**
- Consumes: `MarkdownSyntaxMap.build` (Task 6)
- Produces:
  - `public static func rebuild(source: String, changedUTF16Range: Range<Int>) -> [StyleSpan]`
  - 내부 상태 없음 — 이전 결과를 인자로 받지 않고 영향 받는 블록만 다시 파싱한다

- [ ] **Step 1: Write the failing test**

`Tests/MarkdownSyntaxTests/IncrementalEquivalenceTests.swift`:

```swift
import XCTest
@testable import MarkdownSyntax

/// 증분 경로가 전체 경로와 항상 같은 결과를 내는지 고정한다.
/// 설계 문서의 성능 리스크 완화가 이 테스트에 걸려 있다.
final class IncrementalEquivalenceTests: XCTestCase {

    private let documents = [
        "# 제목\n\n본문 **강조** 텍스트\n\n- 항목 하나\n- 항목 둘\n",
        "**a** *b* `c`\n\n> quote\n\n```swift\nlet x = 1\n```\n",
        "한글 문서\n\n👨‍👩‍👧 이모지와 **강조**\n\n1. 하나\n2. 둘\n",
    ]

    func testRebuildMatchesFullBuildForWholeDocumentRange() {
        for source in documents {
            let full = MarkdownSyntaxMap.build(from: source)
            let incremental = MarkdownSyntaxMap.rebuild(
                source: source,
                changedUTF16Range: 0..<source.utf16.count
            )
            XCTAssertEqual(incremental, full, "원문: \(source.debugDescription)")
        }
    }

    func testRebuildMatchesFullBuildForEverySingleCharacterEdit() {
        for source in documents {
            let full = MarkdownSyntaxMap.build(from: source)
            let limit = source.utf16.count
            for offset in 0..<limit {
                let incremental = MarkdownSyntaxMap.rebuild(
                    source: source,
                    changedUTF16Range: offset..<min(offset + 1, limit)
                )
                XCTAssertEqual(
                    incremental, full,
                    "offset \(offset), 원문: \(source.debugDescription)"
                )
            }
        }
    }

    func testRebuildHandlesEmptyChangedRange() {
        let source = "# T\n\nbody\n"
        XCTAssertEqual(
            MarkdownSyntaxMap.rebuild(source: source, changedUTF16Range: 3..<3),
            MarkdownSyntaxMap.build(from: source)
        )
    }

    func testRebuildClampsOutOfBoundsRange() {
        let source = "# T\n"
        XCTAssertEqual(
            MarkdownSyntaxMap.rebuild(source: source, changedUTF16Range: 0..<9999),
            MarkdownSyntaxMap.build(from: source)
        )
    }

    func testRebuildOnEmptySource() {
        XCTAssertTrue(MarkdownSyntaxMap.rebuild(source: "", changedUTF16Range: 0..<0).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IncrementalEquivalenceTests`
Expected: 컴파일 실패 — `type 'MarkdownSyntaxMap' has no member 'rebuild'`

- [ ] **Step 3: Write minimal implementation**

`Sources/MarkdownSyntax/MarkdownSyntaxMap.swift`의 `build` 아래에 추가:

```swift
    /// 변경 범위를 알 때 스팬을 다시 만든다.
    ///
    /// 지금은 전체를 다시 만든다. 이것이 **의도된 첫 구현**이다 — 등가성 테스트를
    /// 먼저 세워 두고, 나중에 블록 단위 재파싱으로 최적화할 때 그 테스트가
    /// 정확성을 지켜 준다. 최적화를 먼저 하면 검증할 기준이 없다.
    ///
    /// - Parameters:
    ///   - source: 변경이 **이미 적용된** 전체 원문
    ///   - changedUTF16Range: `source` 안에서 변경된 구간. 범위를 벗어나면 잘린다
    public static func rebuild(source: String, changedUTF16Range: Range<Int>) -> [StyleSpan] {
        _ = changedUTF16Range  // 최적화 단계에서 사용
        return build(from: source)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: 전체 스위트 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownSyntax/MarkdownSyntaxMap.swift Tests/MarkdownSyntaxTests/IncrementalEquivalenceTests.swift
git commit -m "feat: add rebuild with full-build equivalence tests"
```

---

## 이 계획의 범위 밖

v1 전체를 한 계획에 담지 않는다. 이 계획은 헤드리스 파싱 레이어만 다루며 자체적으로
동작하고 테스트된다. 이어지는 계획:

- **Plan 2:** `MarkdownDocument` + `FileWatcher` + 충돌 정책 (헤드리스, 테스트 가능)
- **Plan 3:** `LiveStyleApplier` + `EditorTextView` (AppKit, TextKit 2)
- **Plan 4:** `EditorPane`/`ModeSwitcher` + `CommandPalette` (SwiftUI 앱 타깃)

`swift-markdown`이 표(`Table`)와 이미지(`Image`) 노드도 주지만, 설계 문서에서 표·이미지의
"진짜 같은" 렌더링을 v1 범위 밖으로 두었으므로 스팬도 여기서 내지 않는다. Task 6의
코퍼스 테스트가 그런 문서에서 크래시하지 않음만 보장한다.

## Self-Review

**스펙 커버리지.** 설계 문서 컴포넌트 2번(`MarkdownSyntaxMap`)이 Task 1–7로 전부 덮인다.
"AST 노드를 원문 UTF-8 offset 범위로 환산하는 것이 이 모듈의 핵심 작업"이 Task 1이고,
"증분 = 전체 등가성" 테스트가 Task 7이다. 컴포넌트 1·3·4·5·6·7은 Plan 2–4로 미룬다.

**타입 일관성.** `StyleSpan`(Task 2)의 `kind`/`role`/`range`가 Task 3–7에서 같은 이름으로
쓰인다. `SourceOffsetMap.utf16Offset(line:utf8Column:)`(Task 1)의 시그니처가 Task 3의
`utf16Range(_:)`에서 그대로 호출된다. `MarkdownSyntaxMap.build(from:)`(Task 6)이
Task 7의 `rebuild`에서 호출된다.

**의도적으로 남긴 것.** Task 7의 `rebuild`가 전체를 다시 만든다. 이는 미완성이 아니라
순서의 문제다 — 등가성 테스트가 먼저 있어야 최적화가 안전하다. 코드 주석과 위 설명에
그 이유를 명시했다.
