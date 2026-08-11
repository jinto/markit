# AppCore + 앱 껍데기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설계 문서의 컴포넌트 5(`EditorPane`/`ModeSwitcher`)와 6(`CommandPalette`). 그리고 Plan 1·2·3의 부품을 **처음으로 조립해 실행 가능한 앱**을 만든다. 여기서부터 직접 타이핑해 볼 수 있다.

**Architecture:** 조립을 새 타깃 `AppCore`에 둔다. `EditorKit`과 `DocumentCore`는 서로를 모른 채 남고(설계 문서의 레이어 독립 규칙), 둘을 아는 곳은 `AppCore` 하나다. `AppCore`는 AppKit만 쓰고 SwiftUI를 쓰지 않으므로 **조립 전체가 `swift test`로 검증된다.** SwiftUI 층(`MarkitApp`)은 로직 없는 껍데기로 유지한다.

**Tech Stack:** Swift 5.9+, macOS 14+, AppKit, SwiftUI (껍데기만), XCTest

## Global Constraints

- 최소 플랫폼: `.macOS(.v14)`
- **`AppCore`는 SwiftUI를 import하지 않는다.** 테스트 가능성의 근거다
- `MarkitApp`(실행 타깃)에는 로직을 두지 않는다. 뷰 구성과 이벤트 전달만 한다
- 새 서드파티 의존성을 추가하지 않는다
- 프리뷰는 **절대 저장 경로에 닿지 않는다** (아래 참조)
- 라이선스: MIT

## 검증된 사실 (직접 프로브해서 확인 — 추측 아님)

### 1. 하나의 `NSTextContentStorage`에 붙은 두 뷰는 스타일을 다르게 줄 수 없다

분할 모드를 "같은 스토리지에 뷰 둘"로 만들 수 있는지 확인했다. 못 만든다.

```
두 NSTextLayoutManager를 한 NSTextContentStorage에 붙임 → textLayoutManagers.count = 2
앞 ** 만 0.01pt로 접어 봄
  v1 오프셋0 폰트 : 0.01
  v2 오프셋0 폰트 : 0.01      ← 한쪽만 접을 수 없다
  같은 textStorage 인스턴스 : true
  lm1 첫 줄 폭 39.64 / lm2 첫 줄 폭 39.64
```

속성은 `NSTextStorage`에 사는데 그것이 공유되기 때문이다. 레이아웃은 나눌 수 있어도
**스타일은 나눌 수 없다.**

**결과: 분할 모드의 프리뷰는 자기 스토리지를 가진 별도의 뷰다.** 원문(왼쪽, 편집 가능)의
텍스트를 프리뷰(오른쪽, 읽기 전용)에 밀어 넣어 동기화한다.

이것이 AD-2 위반이 아닌 이유: 프리뷰는 **파생물이고 읽기 전용이며 저장 경로에 닿지 않는다.**
진실은 여전히 원문 버퍼 하나다. 다만 코드로 못 박아야 한다 — 프리뷰가 편집 가능해지거나
저장 대상이 되는 순간 무손실 왕복이 깨진다. Task 1의 테스트가 이것을 지킨다.

**대가:** 파싱이 두 번 일어난다. 사실 7번(Plan 3)의 32KB 손익분기점이 분할 모드에서는
**대략 16KB로 내려간다.** 증분 재파싱을 앞당길 근거가 필요하면 여기다.

### 2. `NSTextContainer` 폭 0은 "무제한"이고, `widthTracksTextView`는 초기 폭을 정해 주지 않는다

Plan 3이 만든 `EditorTextView`의 줄바꿈을 확인하다가 나왔다.

```
컨테이너 0  + tracks=true  (Plan 3 구현)  → 줄 1, 최대폭 2522  ✗
컨테이너 0  + tracks=false                → 줄 1, 최대폭 2522  ✗
컨테이너 600 + tracks=true                → 줄 5, 최대폭 586   ✓
컨테이너 0  + tracks=true + 나중에 size 지정 → 줄 5             ✓
```

`widthTracksTextView`는 **프레임 변경은 제대로 추적한다** (초기 0이어도 나중에
`frame`을 주면 따라온다. 600→900에서 5줄→3줄, 900→300에서 9줄).
`NSScrollView` 안에서도 동작한다 (폭 300→700에서 9줄→4줄).

실제 `EditorTextView`로 확인:

```
프레임 미지정 : 줄 1, 최대폭 3140, 컨테이너폭 0     ← 한 줄로 눕는다
프레임 600    : 줄 6, 최대폭 583, 컨테이너폭 600    ← 정상
```

앱에서는 스크롤 뷰가 프레임을 주므로 문제가 되지 않는다. 그러나 **줄바꿈을 지키는 테스트가
하나도 없다** — Plan 3의 테스트는 속성만 봤고 기하는 보지 않았다. 컨테이너 설정을 누가
"정리"하면 조용히 깨진다. Task 1에서 회귀 테스트를 넣는다.

### 3. SPM 실행 타깃만으로 SwiftUI 앱이 뜬다 — 단, 활성화 정책을 직접 세워야 한다

Xcode 프로젝트 없이 `swift run`으로 창이 뜨는지 확인했다. 뜬다.

```
@main + SwiftUI App (executableTarget) → 동작
창 개수 2 (하나는 SwiftUI 내부용 비표시)
창 "프로브" visible=true frame=(459, 317, 900, 450)
메뉴바 있음: true, 항목 6개
```

**함정: 번들이 없으면 `activationPolicy`가 `.prohibited`(2)로 시작한다.**

```
그냥 실행                              → activationPolicy 2, 키보드 포커스 못 받음
App.init()에서 setActivationPolicy(.regular) → activationPolicy 0, isActive true, keyWindow 잡힘
```

`.prohibited`면 창은 보이지만 **앱이 활성화되지 않아 키 입력이 들어오지 않는다.** 한글 IME
체크리스트를 실행하는 것이 이 앱의 첫 목적이므로 이걸 놓치면 목적을 잃는다.

**남는 한계 (번들이 없어서):** `Bundle.main.bundleIdentifier`가 `nil`이다. `UserDefaults`
영속성과 문서 타입 등록이 신뢰할 수 없으므로 **모드 기억 같은 영속 상태를 v1에서 만들지
않는다.** 제대로 된 `.app` 번들은 Xcode 앱 타깃에서 온다.

## 세 모드

세 모드가 **같은 원문 버퍼를 공유한다.** 모드 전환은 표시 정책 변경일 뿐 문서 변환이 아니다.

| 모드 | 구성 | 마커 정책 |
|---|---|---|
| WYSIWYG | 편집 뷰 하나 | 커서가 없는 줄의 마커를 접는다 |
| 소스 | 편집 뷰 하나 | 모든 마커를 노출한다 (구문 색만 입힌 원문) |
| 분할 | `HSplitView`: 소스(편집) \| WYSIWYG(읽기 전용) | 왼쪽 노출, 오른쪽 접음 |

## File Structure

```
Sources/EditorKit/
  LiveStyleApplier.swift     MarkerPolicy 추가
  EditorTextView.swift       markerPolicy, isPreview 추가

Sources/AppCore/             ← 새 타깃. EditorKit + DocumentCore 조립
  DisplayMode.swift
  Command.swift              명령 정의
  CommandMatcher.swift        퍼지 매처 (순수 함수)
  EditorSession.swift        조립 루트

Sources/MarkitApp/           ← 새 실행 타깃. SwiftUI 껍데기
  MarkitApp.swift
  EditorPane.swift           NSViewRepresentable
  ModeSwitcher.swift
  CommandPaletteView.swift

Tests/EditorKitTests/  (추가)
Tests/AppCoreTests/    (새로)
```

---

## Task 1: 마커 정책을 갈아끼울 수 있게 만든다

**Files:**
- Modify: `Sources/EditorKit/LiveStyleApplier.swift`, `Sources/EditorKit/EditorTextView.swift`
- Test: `Tests/EditorKitTests/LiveStyleApplierTests.swift`, `Tests/EditorKitTests/EditorTextViewTests.swift`

**Interfaces:**
- `public enum MarkerPolicy { case hideWhenInactive, revealAll }`
- `LiveStyleApplier.init(theme: Theme = .default, markerPolicy: MarkerPolicy = .hideWhenInactive)`
- `EditorTextView.markerPolicy: MarkerPolicy` (설정 시 재스타일)
- `EditorTextView.makePreview(theme:) -> EditorTextView` — 읽기 전용 프리뷰 생성

- [ ] **Step 1: Write the failing tests**

`LiveStyleApplierTests`에 추가:

```swift
func testRevealAllPolicyNeverHidesMarkers() {
    let source = "**굵게**\n둘째 줄"
    let storage = NSTextStorage(string: source)
    LiveStyleApplier(markerPolicy: .revealAll).apply(
        spans: MarkdownSyntaxMap.build(from: source),
        selection: NSRange(location: offset(of: "둘째", in: source), length: 0),
        to: storage)
    XCTAssertFalse(isHidden(storage, at: 0), "소스 모드에서는 커서가 멀어도 마커가 보인다")
    XCTAssertFalse(isHidden(storage, at: 4))
}

func testRevealAllStillDimsMarkers() {
    // 노출한다고 본문색으로 두면 마커가 내용을 방해한다. 구문 색은 유지해야 한다.
    let source = "**굵게**"
    let storage = NSTextStorage(string: source)
    LiveStyleApplier(markerPolicy: .revealAll).apply(
        spans: MarkdownSyntaxMap.build(from: source),
        selection: NSRange(location: 100, length: 0), to: storage)
    XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                   Theme.default.markerColor)
}
```

`EditorTextViewTests`에 추가:

```swift
// MARK: - 줄바꿈 (Plan 3이 놓친 것)

/// 컨테이너 폭 0은 "무제한"이다. 이 설정이 깨지면 긴 문서가 한 줄로 누워
/// 3140pt 폭이 된다. 속성 테스트로는 절대 잡히지 않으므로 기하를 직접 본다.
func testLongTextWrapsWithinContainerWidth() {
    let v = view()
    v.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    v.setMarkdown(String(repeating: "이것은 줄바꿈이 필요한 긴 한글 문장입니다. ", count: 12))

    guard let tlm = v.textLayoutManager else { return XCTFail("TextKit 2가 아니다") }
    tlm.ensureLayout(for: tlm.documentRange)
    var lines = 0
    var widest = 0.0
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location,
                                     options: [.ensuresLayout]) { fragment in
        for line in fragment.textLineFragments {
            lines += 1
            widest = max(widest, line.typographicBounds.width)
        }
        return true
    }
    XCTAssertGreaterThan(lines, 1, "긴 텍스트가 여러 줄로 나뉘어야 한다")
    XCTAssertLessThanOrEqual(widest, 410, "줄이 컨테이너 폭을 넘으면 가로 스크롤이 생긴다")
}

func testWrappingFollowsWidthChange() {
    let v = view()
    v.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    v.setMarkdown(String(repeating: "이것은 줄바꿈이 필요한 긴 한글 문장입니다. ", count: 12))
    let narrow = lineCount(v)
    v.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
    XCTAssertLessThan(lineCount(v), narrow, "넓히면 줄 수가 줄어야 한다")
}

// MARK: - 프리뷰 (분할 모드의 오른쪽)

func testPreviewIsNotEditable() {
    XCTAssertFalse(EditorTextView.makePreview().isEditable,
                   "프리뷰가 편집 가능하면 두 버퍼가 갈라진다")
}

/// 프리뷰는 파생물이다. 저장 경로에 닿으면 무손실 왕복이 깨진다.
func testPreviewNeverReportsTextChange() {
    let preview = EditorTextView.makePreview()
    var fired = 0
    preview.onTextChange = { _ in fired += 1 }
    preview.setMarkdown("에이전트가 쓴 내용")
    preview.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(fired, 0)
}

func testPreviewHidesMarkersRegardlessOfCaret() {
    let preview = EditorTextView.makePreview()
    preview.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    preview.setMarkdown("**굵게**\n둘째 줄")
    preview.setSelectedRange(NSRange(location: 1, length: 0))
    preview.restyleNow()
    XCTAssertTrue(isHidden(preview, at: 0),
                  "프리뷰에는 커서 개념이 없다 — 항상 접혀 있어야 한다")
}

func testSourcePolicyRevealsMarkers() {
    let v = view("**굵게**\n둘째 줄")
    v.markerPolicy = .revealAll
    v.setSelectedRange(NSRange(location: offset(of: "둘째", in: v.string), length: 0))
    v.restyleNow()
    XCTAssertFalse(isHidden(v, at: 0))
}
```

`lineCount(_:)` 헬퍼를 테스트 파일에 추가한다.

- [ ] **Step 2: Implement**

`LiveStyleApplier`: `markerPolicy` 저장 프로퍼티 추가. `applyMarker`에서
`policy == .hideWhenInactive && isHidable(kind) && !onActiveLine`일 때만 접는다.

`EditorTextView`:
- `public var markerPolicy: MarkerPolicy = .hideWhenInactive { didSet { restyleNow() } }`
- `restyleNow()`가 applier를 만들 때 정책을 넘긴다
- `public static func makePreview(theme: Theme = .default) -> EditorTextView` —
  `isEditable = false`, `isPreview = true`
- `isPreview`가 `true`면 `didProcessEditing`에서 `onTextChange`를 부르지 않고,
  마커 노출 시 활성 줄을 무시한다 (선택 범위를 문서 밖으로 취급)

프리뷰에서 "항상 접힘"을 만드는 방법: `apply(spans:selection:to:)`에 넘기는 selection을
문서 밖 범위로 준다. 활성 줄이 어떤 마커와도 겹치지 않으므로 전부 접힌다. 정책 코드를
새로 만들지 않고 기존 경로를 재사용한다.

- [ ] **Step 3: Verify** — `swift test` 전체 초록. 그리고 **변이 테스트**: 컨테이너
  설정에서 `widthTracksTextView = true`를 빼고 줄바꿈 테스트가 빨개지는지 확인한다.
  Plan 3에서 공허한 테스트를 두 번 만들었으므로 이번엔 처음부터 확인한다.

- [ ] **Step 4: Commit** — `feat: make marker reveal policy swappable and add preview mode`

---

## Task 2: 커맨드 팔레트 — 명령과 퍼지 매처

순수 함수다. `AppCore`에서 가장 먼저 만든다.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AppCore/Command.swift`, `Sources/AppCore/CommandMatcher.swift`
- Test: `Tests/AppCoreTests/CommandMatcherTests.swift`

**Interfaces:**
- `public struct Command: Identifiable` — `id: String`, `title: String`, `shortcut: String?`
- `public struct CommandMatch` — `command: Command`, `score: Int`, `matchedOffsets: [Int]`
- `public enum CommandMatcher { public static func match(query: String, in: [Command]) -> [CommandMatch] }`

- [ ] **Step 1: Write the failing test**

`Package.swift`에 추가:
```swift
        .library(name: "AppCore", targets: ["AppCore"]),
```
```swift
        // 조립 층. EditorKit과 DocumentCore를 아는 유일한 곳이다.
        // SwiftUI를 쓰지 않으므로 조립 전체가 swift test로 검증된다.
        .target(name: "AppCore", dependencies: ["EditorKit", "DocumentCore"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
```

`Tests/AppCoreTests/CommandMatcherTests.swift`:

```swift
import XCTest
@testable import AppCore

final class CommandMatcherTests: XCTestCase {

    private let commands = [
        Command(id: "mode.wysiwyg", title: "WYSIWYG 모드"),
        Command(id: "mode.source", title: "소스 모드"),
        Command(id: "mode.split", title: "분할 모드"),
        Command(id: "file.open", title: "파일 열기"),
        Command(id: "file.save", title: "저장"),
        Command(id: "file.saveAs", title: "다른 이름으로 저장"),
    ]

    private func titles(_ query: String) -> [String] {
        CommandMatcher.match(query: query, in: commands).map(\.title)
    }

    func testEmptyQueryReturnsEverythingInOriginalOrder() {
        XCTAssertEqual(titles(""), commands.map(\.title))
    }

    func testMatchesSubsequenceNotOnlyPrefix() {
        XCTAssertTrue(titles("모드").contains("소스 모드"))
    }

    func testFiltersOutNonMatches() {
        XCTAssertEqual(titles("zzz"), [])
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(titles("wys").contains("WYSIWYG 모드"))
        XCTAssertTrue(titles("WYS").contains("WYSIWYG 모드"))
    }

    /// 짧고 정확한 것이 위로 와야 한다. "저장"을 치면 "저장"이 "다른 이름으로 저장"보다
    /// 먼저 나와야 쓸 만하다.
    func testExactShorterTitleRanksHigher() {
        XCTAssertEqual(titles("저장").first, "저장")
    }

    /// 붙어 있는 매치가 흩어진 매치보다 위여야 한다.
    func testContiguousMatchBeatsScattered() {
        let cs = [Command(id: "a", title: "분산 항 목"), Command(id: "b", title: "항목")]
        XCTAssertEqual(CommandMatcher.match(query: "항목", in: cs).map(\.title).first, "항목")
    }

    func testReportsMatchedOffsetsForHighlighting() {
        let cs = [Command(id: "a", title: "저장")]
        let m = CommandMatcher.match(query: "저장", in: cs)[0]
        XCTAssertEqual(m.matchedOffsets, [0, 1])
    }

    func testMatchedOffsetsAreUTF16OffsetsIntoTitle() {
        // 한글·이모지가 섞여도 오프셋이 제목 안을 가리켜야 한다 (하이라이트가 어긋나면 안 된다).
        let cs = [Command(id: "a", title: "🇰🇷 저장하기")]
        let m = CommandMatcher.match(query: "저장", in: cs)[0]
        let title = cs[0].title as NSString
        for off in m.matchedOffsets {
            XCTAssertLessThan(off, title.length)
        }
        XCTAssertEqual(m.matchedOffsets.map { title.substring(with: NSRange(location: $0, length: 1)) }
                        .joined(), "저장")
    }

    func testQueryLongerThanTitleDoesNotMatch() {
        XCTAssertEqual(CommandMatcher.match(query: "저장하기입니다",
                                            in: [Command(id: "a", title: "저장")]).count, 0)
    }
}
```

- [ ] **Step 2: Implement**

부분수열(subsequence) 매칭 + 점수. 점수 규칙은 위 테스트가 요구하는 것만:
붙어 있는 매치에 가점, 매치가 앞쪽일 때 가점, 제목이 짧을 때 가점.
동점이면 원래 순서를 유지한다 (`enumerated()` 인덱스를 타이브레이커로).

UTF-16 오프셋으로 다룬다 — Plan 1에서 얻은 교훈이다.

- [ ] **Step 3: Verify** — `swift test --filter CommandMatcherTests` 초록.

- [ ] **Step 4: Commit** — `feat: add command registry and fuzzy matcher`

---

## Task 3: EditorSession — 조립 루트

Plan 1·2·3이 처음 만나는 곳. **여기가 이 계획의 핵심이다.**

**Files:**
- Create: `Sources/AppCore/DisplayMode.swift`, `Sources/AppCore/EditorSession.swift`
- Test: `Tests/AppCoreTests/EditorSessionTests.swift`

**Interfaces:**
- `public enum DisplayMode { case wysiwyg, source, split }`
- `public final class EditorSession`
  - `public init(theme: Theme = .default)`
  - `public let sourceView: EditorTextView`
  - `public let previewView: EditorTextView`
  - `public var mode: DisplayMode` (설정 시 정책 갱신 + 프리뷰 동기화)
  - `public private(set) var document: MarkdownDocument`
  - `public var isDirty: Bool`
  - `public var onExternalChange: ((ExternalChange) -> Void)?`
  - `public func open(_ url: URL) throws`
  - `public func save() throws -> SaveOutcome`
  - `public func acceptDiskVersion(_ text: String)`
  - `public var commands: [Command]`
  - `public func run(_ command: Command)`

- [ ] **Step 1: Write the failing test**

`Tests/AppCoreTests/EditorSessionTests.swift` — 검증할 것:

```swift
// 모드 → 정책 매핑
func testWysiwygModeHidesMarkersInSourceView()
func testSourceModeRevealsMarkers()
func testSplitModeRevealsInSourceAndHidesInPreview()

// 타이핑이 문서에 반영된다 (Plan 2와의 연결)
func testTypingUpdatesDocumentText()
func testTypingMakesDocumentDirty()
func testSaveClearsDirty()

// 프리뷰 동기화
func testPreviewMirrorsSourceTextInSplitMode()
func testPreviewIsNotSyncedOutsideSplitMode()   // 불필요한 파싱을 피한다
func testSwitchingToSplitSyncsPreviewImmediately()

// 열기
func testOpenLoadsFileIntoSourceViewAndDocument()
func testOpenResetsDirty()
func testOpenPlacesCaretAtDocumentStart()

// 저장 왕복 — AD-2의 핵심 계약이 조립 후에도 유지되는가
func testLoadThenSaveIsByteIdentical()   // 코퍼스로 반복

// 외부 변경 (Plan 2의 충돌 정책이 조립 후에도 동작하는가)
func testExternalChangeReloadsSourceViewWhenClean()
func testExternalChangeReportsConflictWhenDirty()
func testAcceptDiskVersionUpdatesSourceView()

// 명령
func testModeCommandsSwitchMode()
func testSaveCommandRequiresURL()
```

**특히 `testLoadThenSaveIsByteIdentical`이 중요하다.** Plan 2에서 `MarkdownDocument`만으로
검증했지만, 이제 텍스트가 `NSTextStorage`를 왕복한다. `NSTextStorage`가 개행이나 유니코드를
정규화하면 여기서 드러난다. 코퍼스는 Plan 2와 같은 것을 쓴다 (CRLF, 후행 공백, 개행 없음,
빈 파일, 한글, 이모지).

- [ ] **Step 2: Implement**

배선:
- `sourceView.onTextChange = { [weak self] text in self?.handleSourceTextChange(text) }`
  → `document.text = text`, 분할 모드면 `previewView.setMarkdown(text)`
- `document.onExternalChange` → `.reloaded`면 `sourceView.setMarkdown(document.text)`,
  그 외에는 그대로 상위에 전달
- `mode`의 `didSet`에서 `sourceView.markerPolicy`를 정하고, 분할로 들어오면 프리뷰를 동기화
- `open(_:)`은 `MarkdownDocument(loadingFrom:)` → `sourceView.setMarkdown` →
  `beginWatching(with: FSEventsFileWatcher())`

주의: `sourceView.setMarkdown`은 `onTextChange`를 부르지 않으므로 (Plan 3) 리로드가
사용자 편집으로 오인되지 않는다. 그 성질에 의존하고 있음을 주석으로 남긴다.

- [ ] **Step 3: Verify** — `swift test` 전체 초록.

- [ ] **Step 4: Commit** — `feat: add EditorSession composing document, editor, and modes`

---

## Task 4: SwiftUI 껍데기와 실행 타깃

**자동 검증이 불가능한 유일한 태스크다.** 그래서 마지막에 두고, 로직을 두지 않는다.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MarkitApp/MarkitApp.swift`, `EditorPane.swift`, `ModeSwitcher.swift`, `CommandPaletteView.swift`

- [ ] **Step 1: 실행 타깃 추가**

```swift
        .executableTarget(name: "MarkitApp", dependencies: ["AppCore"]),
```

- [ ] **Step 2: 구현**

- `MarkitApp.swift`: `@main struct MarkitApp: App`.
  **`init()`에서 `NSApplication.shared.setActivationPolicy(.regular)`** — 사실 3번.
  이게 없으면 키 입력이 안 들어와서 IME 테스트를 할 수 없다
- `EditorPane.swift`: `NSViewRepresentable`. `makeNSView`에서 `NSScrollView`를 만들고
  `documentView`에 세션의 뷰를 넣는다. 뷰를 새로 만들지 않고 **세션이 소유한 것을 쓴다**
  (SwiftUI가 뷰를 재생성해도 편집 상태가 날아가지 않아야 한다)
- `ModeSwitcher.swift`: 세그먼트 3개. `⌘1`/`⌘2`/`⌘3`
- `CommandPaletteView.swift`: `⌘K` 오버레이. `CommandMatcher` 결과를 띄우고
  `matchedOffsets`로 하이라이트한다
- 분할 모드는 `HSplitView`

- [ ] **Step 3: 수동 검증**

`swift run MarkitApp` 후 `docs/manual-test-checklist.md`를 실행한다.
**이것이 이 태스크의 검증이다** — 자동 테스트가 대신할 수 없다.

최소 확인:
- [ ] 창이 뜨고 클릭하면 커서가 들어간다 (활성화 정책이 맞다)
- [ ] 한글이 입력된다
- [ ] `⌘1`/`⌘2`/`⌘3` 모드 전환
- [ ] `⌘K` 팔레트
- [ ] 긴 문서에서 줄바꿈과 스크롤

- [ ] **Step 4: Commit** — `feat: add SwiftUI shell and runnable app target`

---

## 이 계획이 남기는 것

- **모드 기억(영속 상태)을 만들지 않는다.** 번들이 없어 `UserDefaults`가 신뢰할 수 없다
  (사실 3번). Xcode 앱 타깃이 생기면 그때 넣는다
- **파일 열기/저장 패널(`NSOpenPanel`)은 수동 검증만 가능하다.** 세션의 `open(_:)`/`save()`는
  URL을 받으므로 자동 테스트되고, 패널은 껍데기에 둔다
- **분할 모드가 파싱을 두 배로 한다.** 손익분기점이 16KB로 내려간다. 증분 재파싱을 앞당길
  근거가 필요하면 여기다
- v2(에이전트 통합), v3(내보내기)은 설계 문서대로 남는다