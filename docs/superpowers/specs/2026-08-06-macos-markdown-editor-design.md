# macOS 마크다운 에디터 — 설계 문서

- 날짜: 2026-08-06
- 상태: 승인됨 (v1 구현 대기)
- 프로젝트 경로: `/Users/jinto/projects/markit`
- 라이선스: MIT

## 배경

[Markdowner](https://markdowner.chann.dev/)와 같은 기능을 하는 macOS 마크다운 에디터를 만든다.
Markdowner의 포지셔닝은 "당신과 코딩 에이전트를 위한 마크다운 에디터" — 사람이 편집하기 쉬운
경험과, 도구·에이전트가 파싱하기에 예측 가능한 파일을 한 문서 안에서 동시에 지키는 것이다.

조사한 Markdowner의 기능 목록은 부록 A에 있다. 우리가 겨냥하는 것도 같은 범위다.

## 목표

1. 사람이 워드프로세서처럼 쓸 수 있는 WYSIWYG 마크다운 편집
2. 파일이 언제나 깨끗한 마크다운으로 유지됨 — 열고 저장해도 바이트가 변하지 않음
3. 코딩 에이전트(Claude Code, Codex)와 같은 파일을 동시에 보며 작업할 수 있음
4. 네이티브 macOS 앱의 완성도 — 즉시 실행, 낮은 메모리, 시스템 통합

## 비목표

- 크로스플랫폼 (Windows/Linux). macOS 전용으로 설계한다.
- 웹 기술(Electron/Tauri/WebView) 사용. 명시적으로 배제한다.
- 실시간 협업, 클라우드 동기화, 계정 시스템
- 마크다운 외 포맷의 편집 (docx, org-mode 등)

## 아키텍처 결정

### AD-1. 언어: Swift 단일 (UI + 코어)

**결정.** UI와 도큐먼트 코어 모두 Swift로 작성한다.

**근거.** 이 앱의 본체는 텍스트 편집 엔진이다. 커서 이동, 선택, 한글 IME 조합, 언두
그래뉼래러티, 접근성, 스크롤 앵커링, 이미지 인라인 배치 — 이 전부를 macOS는 TextKit 2 /
NSTextView로 이미 제공한다. 이걸 직접 만드는 것은 Zed가 수년을 쓴 일이다.

Apple 프레임워크는 Swift 전용이므로 UI 층에는 실질적 선택지가 없다. Ghostty를 만든
Mitchell Hashimoto도 Zig 코어 + Swift UI를 택했고 이유를 이렇게 남겼다:

> "Modern macOS development effectively requires Swift, as all the new fancy functionality
> and frameworks Apple is shipping is Swift-only."

코어까지 Swift로 하는 이유는 `swift-markdown`이 cmark-gfm(CommonMark 레퍼런스 구현) 랩이라
"결정적 파싱"이 이미 해결되기 때문이다. Rust/Zig 코어는 FFI 경계, 듀얼 빌드 파이프라인,
메모리 소유권 다툼을 추가하고 macOS 전용 앱에서는 이득이 없다.

**검토했으나 배제한 것.**

| 언어 | 배제 이유 |
|---|---|
| Rust | GUI에 리치 텍스트 편집 위젯이 없다. egui/iced는 텍스트 편집이 빈약하고 한글 IME가 특히 취약. gpui는 Zed 전용에 가깝고 문서가 부족. 코어 언어로는 최상급이지만 AD-1에 따라 코어도 Swift로 간다. |
| Zig | GUI 생태계 부재. 코어 언어로는 Ghostty가 C ABI 선례를 증명했으나 AD-1과 같은 이유로 불필요. |
| Go | Shirei(514★)는 IME·복잡 문자 셰이핑·양방향 레이아웃까지 명시한 진지한 프레임워크다. 그러나 즉시 모드 + 자체 렌더링이라 **텍스트 편집 엔진이 없다** (README에 멀티라인 편집·선택·커서·언두 언급 없음). 이 앱은 텍스트 엔진이 8할이므로 궁합이 맞지 않는다. |

### AD-2. WYSIWYG 아키텍처: 소스가 진실 (source-of-truth buffer)

**결정.** `NSTextStorage`가 마크다운 원문을 그대로 보유한다. 스타일링 패스는 속성만 입힌다 —
헤딩은 크게, `**` 같은 마커는 커서가 멀면 흐리게/숨김. Obsidian 라이브 프리뷰, Bear가 쓰는
방식이다.

**근거.** 목표 2(무손실)와 목표 3(에이전트 협업)이 이 선택에서 **공짜로 따라온다**:

- 버퍼가 곧 파일 내용이다. 파싱·재직렬화를 하지 않으므로 서식이 깨질 경로가 존재하지 않는다.
- 에이전트가 파일을 고치면 버퍼를 교체하면 끝이다. AST 재조정이나 커서 위치 재매핑 문제가 없다.

**검토했으나 배제한 것 — 도큐먼트 모델(AST가 진실).** 파싱해서 AST를 만들고, AST를
렌더링하고, 편집마다 마크다운으로 재직렬화하는 방식(ProseMirror 계열). 마커가 완전히 사라지는
"진짜" WYSIWYG이 되지만, **재직렬화는 필연적으로 정규화를 한다** — `*foo*`가 `_foo_`로,
리스트 마커가 `-`에서 `*`로, 공백이 재배치. 에이전트가 쓴 파일을 열었다 저장만 해도 diff가
터진다. 에이전트와 파일을 공유하는 앱에서 이것은 목표 2·3을 정면으로 위반한다.

**알려진 한계.** 표·이미지·코드블록을 "진짜처럼" 보여주기가 제한적이다. v1 이후
`NSTextAttachment` 블록 위젯을 얹어 점진적으로 해결한다 (A → 하이브리드). 이 점진 경로가
존재한다는 것도 A를 택한 이유다. B는 처음부터 전부 만들어야 한다.

### AD-3. 텍스트 엔진 토대: NSTextView / TextKit 2 직접 사용

**결정.** 서드파티 텍스트 뷰를 쓰지 않고 `NSTextView`(TextKit 2)를 직접 쓴다.
`NSViewRepresentable`로 SwiftUI에 브리지한다.

**근거.** 후보를 전수 조사한 결과, 성숙한 것에는 라이선스 함정이 있고 라이선스가 깨끗한 것은
어리거나 정체돼 있었다.

| 패키지 | 라이선스 | 나이 / ★ | 판정 |
|---|---|---|---|
| STTextView | **GPL v3 또는 유료 상용** | 4.5년 / 1,580 | 배제 — 아래 참조 |
| CodeEditTextView | MIT | 2023-12 / 180 | 2026-04-20 이후 정체 |
| CodeEditSourceEditor | MIT | 2022-05 / 712 | 스스로 "not ready for production" |
| swift-markdown-engine | Apache-2.0 | **3개월** / 892 | 0.11.0, 버스 팩터 1 → 교재로만 사용 |

STTextView는 프로젝트가 오픈소스여도 배제한다. GPL v3는 전염성이라 앱 전체가 GPL v3로
고정되고, 그러면 **App Store 경로가 영구히 닫힌다** (GPL v3의 추가제약 금지 조항과 App Store
약관 충돌). 그 대가로 얻는 것은 코드 에디터용 텍스트 뷰이고, 핵심 가치인 라인 번호·거터는
WYSIWYG 마크다운 모드에서 쓰지 않는다. 정작 필요한 라이브 스타일링은 어차피 직접 쓴다.
한계 효용은 작고 라이선스 비용은 영구적이다.

swift-markdown-engine은 **의존성이 아니라 교재로** 쓴다. 코드 설계는 훌륭하다(코어 외부
의존성 0, `WikiLinkResolver`/`SyntaxHighlighter`/`LatexRenderer` 프로토콜 어댑터, 코드블록·
LaTeX는 opt-in 프로덕트로 분리, 테스트 타겟 보유). 그러나 3개월·0.11.0·주 저자 1인
177커밋(전체의 약 3/4)인 프로젝트를 앱의 최심부에 박을 수는 없다. 라이브 스타일링 패스는
이 제품의 심장이고, 심장은 소유해야 한다.

Apache-2.0이므로 구현을 읽고 배우는 것은 자유롭다. 다만 우리 프로젝트가 MIT이므로(AD-4)
**코드를 복사해 온다면 그 파일은 Apache-2.0으로 남기고 출처를 표기해야 한다.** 프로젝트
전체를 한 라이선스로 유지하려면 읽고 다시 쓰는 편이 낫다.

시간은 커모디티에서 아낀다 — 터미널(7년 검증된 SwiftTerm), 파싱(Apple 공식), PDF(OS 제공).
차별점에서 아끼지 않는다.

### AD-4. 프로젝트 라이선스: MIT

**결정.** MIT. (초안은 Apache-2.0이었다 — 아래 개정 이력 참조.)

**근거.** 가장 단순하고 널리 이해되는 허용적 라이선스다. 기여자가 조건을 읽는 데 시간을
쓰지 않아도 되고, App Store 배포 경로도 열려 있다.

**개정 이력.** 초안에서는 Apache-2.0을 택했다. 근거는 핵심 의존성(`swift-markdown`)과
참고 교재(`swift-markdown-engine`)가 둘 다 Apache-2.0이어서 차용·상류 기여가 매끄럽고,
특허 조항이 따라오며 NOTICE 처리가 명시적이라는 것이었다. 저장소를 만들 때 MIT로 정했고
그 결정을 따른다.

**대가 (분명히 기록한다).**

1. **Apache-2.0 코드를 그대로 가져올 때 프로젝트 라이선스로 흡수할 수 없다.**
   `swift-markdown-engine`을 교재로 쓰기로 한 AD-3의 계획에 영향이 있다. 읽고 배우는 것은
   자유롭지만, 코드를 복사해 온다면 **그 파일은 Apache-2.0으로 남기고 출처와 라이선스를
   표기해야 한다.** 프로젝트 전체를 한 라이선스로 두려던 원래 이점은 사라진다.
2. **명시적 특허 허여가 없다.** MIT에는 Apache-2.0 §3에 해당하는 조항이 없다.
3. 의존성으로 **링크**하는 것은 어느 쪽이든 문제가 없다 (`swift-markdown`은 Apache-2.0인 채로
   남는다). 위 1번은 소스를 복사해 오는 경우에만 해당한다.

## 스택

| 역할 | 선택 | 라이선스 |
|---|---|---|
| UI 셸 | SwiftUI + AppKit | OS |
| 텍스트 엔진 | NSTextView / TextKit 2 (직접) | OS |
| **라이브 스타일링** | **직접 구현** | — |
| 마크다운 파싱 | `swiftlang/swift-markdown` | Apache-2.0 |
| 내장 터미널 | SwiftTerm `LocalProcessTerminalView` | MIT |
| PDF 내보내기 | PDFKit / `NSPrintOperation` | OS |
| 외부 변경 감지 | FSEvents | OS |
| 원자적 쓰기 | `Data.write(options: .atomic)` | OS |
| `mdner` CLI | `swift-argument-parser` | Apache-2.0 |
| 참고 교재 (의존성 아님) | `swift-markdown-engine` | Apache-2.0 |

런타임 서드파티 의존성이 3개뿐이며 전부 퍼미시브 라이선스이고 성숙하다.

최소 지원 버전: macOS 14 (TextKit 2 성숙도 기준).

## 컴포넌트 설계

모듈 경계는 **UI 없이 테스트 가능한 것을 최대화**하는 방향으로 잘랐다. 1~3번은 순수하거나
헤드리스이므로 유닛 테스트가 가능하고, 이 앱에서 가장 위험한 로직이 전부 거기 있다.

### 1. `MarkdownDocument` — 파일 하나의 상태

- **하는 일:** 원문 텍스트 소유, 로드, 원자적 저장, dirty 상태 추적, 외부 변경 알림 중계
- **쓰는 법:** `load(url:)`, `save()`, `text` (읽기/쓰기), `onExternalChange` 콜백
- **의존:** Foundation, `FileWatcher`
- **UI 무관.** AppKit을 import하지 않는다.

### 2. `MarkdownSyntaxMap` — 원문 → 스타일 범위

- **하는 일:** 마크다운 원문을 받아 스타일링에 필요한 범위 정보를 낸다 — 헤딩 레벨과 범위,
  강조 범위, 구문 마커의 정확한 위치, 코드블록 범위, 링크 범위, 리스트 마커
- **쓰는 법:**
  - `build(from: String) -> [StyleSpan]` — 전체 문서. 순수 함수
  - `rebuild(_ spans: [StyleSpan], in: String, changed: Range<String.Index>) -> [StyleSpan]` —
    변경된 블록만 갱신. 역시 순수 함수 (이전 결과를 인자로 받을 뿐 내부 상태가 없다)
- **의존:** `swift-markdown`만
- **순수 함수.** 입력이 같으면 출력이 같다. 이 앱에서 가장 테스트하기 쉽고 가장 중요한 모듈.

`swift-markdown`의 AST 노드를 원문 UTF-8 offset 범위로 환산하는 것이 이 모듈의 핵심 작업이다.

증분 경로(`rebuild`)와 전체 경로(`build`)의 관계는 테스트로 고정한다: 임의의 편집 시퀀스에
대해 `rebuild`를 반복 적용한 결과가 `build`를 처음부터 돌린 결과와 **항상 같아야 한다**.
증분 최적화가 정확성을 갉아먹지 않게 하는 안전장치이며, 이것이 성능 리스크 완화의 근거다.

### 3. `LiveStyleApplier` — 스타일 범위 + 커서 → 텍스트 속성

- **하는 일:** `[StyleSpan]`과 현재 선택 위치를 받아 `NSTextStorage`에 속성을 적용한다.
  마커를 숨길지 노출할지 결정하는 정책이 여기 있다 (커서가 해당 범위 안이면 마커 노출).
- **쓰는 법:** `apply(spans:selection:to:)`
- **의존:** AppKit (`NSTextStorage`), 2번
- 마커 표시 정책을 이 모듈에 격리해두면 WYSIWYG/소스 모드가 같은 파이프라인을 쓰면서
  정책만 갈아끼울 수 있다.

### 4. `EditorTextView` — NSTextView 조립

- **하는 일:** `NSTextView`(TextKit 2) 서브클래스. 편집 이벤트를 받아 2·3번을 돌린다.
  증분 갱신(변경된 블록만 재파싱)을 담당한다.
- **의존:** AppKit, 2번, 3번

### 5. `EditorPane` / `ModeSwitcher` — SwiftUI 층

- **하는 일:** WYSIWYG / 소스 / 분할 모드 전환. 분할은 `HSplitView`.
- 세 모드가 **같은 `MarkdownDocument`를 공유**한다. 모드 전환은 표시 정책 변경일 뿐이며
  문서 변환이 아니다 (AD-2의 직접적 이득).

### 6. `CommandPalette`

- **하는 일:** 명령 레지스트리 + fuzzy matcher + SwiftUI 오버레이
- **의존:** 없음 (matcher는 순수 함수 → 테스트 가능)

### 7. `FileWatcher`

- **하는 일:** FSEvents 래퍼. 지정 경로의 외부 변경을 알린다.
- **의존:** CoreServices

## 데이터 흐름

```
파일 열기
  → MarkdownDocument.load(url:)          [원자적 읽기]
  → text

편집 발생
  → EditorTextView가 변경 범위 감지
  → MarkdownSyntaxMap.build (변경된 블록만 증분)
  → LiveStyleApplier.apply(spans, selection)
  → NSTextStorage 속성 갱신

저장
  → MarkdownDocument.save()               [FileManager.replaceItemAt = 원자적]

외부 변경 (에이전트가 파일 수정)
  → FileWatcher 알림
  → 충돌 정책 판정 (아래)
  → 버퍼 교체 또는 사용자 선택
```

## 에러 처리 / 충돌 정책

에이전트와 파일을 공유하는 앱이므로 충돌 정책이 설계의 일부다.

| 상황 | 처리 |
|---|---|
| **디스크 내용 == 버퍼 내용** | **무시.** 세 경우를 한 규칙으로 처리한다: (1) 우리 저장이 메아리로 돌아온 경우, (2) 에이전트가 우연히 같은 내용을 쓴 경우, (3) FSEvents가 스트림 시작 직후 흘려보내는 잔여 이벤트. 이것이 없으면 저장할 때마다, 그리고 파일을 열 때마다 가짜 충돌이 뜬다 |
| 외부 변경 + 버퍼 clean | **자동 리로드.** 알림만 표시 (에이전트 협업의 기본 경로) |
| 외부 변경 + 버퍼 dirty | 사용자 선택: 내 것 유지 / 디스크 것 채택 / diff 보기. 조용히 덮어쓰지 않는다 |
| 저장 중 파일 삭제됨 | 재생성하고 경고 |
| 저장 실패 (권한/디스크) | 원본 보존(원자적 쓰기가 보장), 오류 표시, dirty 유지 |
| 잘못된 UTF-8 | 로드 거부 + 명확한 오류. 손상된 상태로 열지 않는다 |

원자적 쓰기를 쓰는 이유는 목표 2 때문만이 아니다. 에이전트가 같은 파일을 읽는 중에 부분
기록된 파일을 보게 되면 안 된다. 구현은 `Data.write(options: .atomic)`을 쓴다 — 임시 파일에
쓰고 rename하며, POSIX 권한을 보존하고(확인됨), 실패 시 원본이 온전하다.

**감시는 파일이 아니라 부모 디렉터리를 대상으로 한다.** 원자적 쓰기는 inode를 바꾸므로
(확인됨: 50332082 → 50332083), 파일 디스크립터 기반 감시는 에이전트가 한 번 저장하는
순간 낡은 inode를 가리키게 되어 조용히 죽는다. FSEvents로 부모 디렉터리를 보고 파일명으로
거른다.

## 테스트 전략

**핵심 회귀 테스트 — 무손실 왕복.** 샘플 문서 코퍼스(GFM 표, 중첩 리스트, 코드 펜스, 각주,
혼합 강조 마커, CRLF, 한글, 이모지)에 대해 `load → save`가 **바이트 동일**함을 검증한다.
AD-2가 옳게 구현되었다면 이 테스트는 자명하게 통과해야 하고, 실패하면 아키텍처가 새고 있다는
신호다.

| 대상 | 방법 |
|---|---|
| `MarkdownSyntaxMap` | 순수 함수 → 스냅샷 테스트. 범위 offset 정확성 |
| 증분 = 전체 등가성 | 임의 편집 시퀀스에 `rebuild` 반복 == `build` 처음부터. 성능 최적화가 정확성을 깨지 않는지 |
| 무손실 왕복 | 코퍼스 바이트 비교 (위) |
| 충돌 정책 | `FileWatcher`를 목으로 대체, 4가지 시나리오 |
| `CommandPalette` matcher | 순수 함수 유닛 테스트 |
| 한글 IME 조합 | **자동화 불가 — 수동 테스트 체크리스트로 관리.** 조합 중 커서 위치, 조합 중 스타일링 패스가 조합을 깨뜨리지 않는지 |

한글 IME는 이 프로젝트에서 자동 검증이 안 되는 유일한 핵심 영역이므로 수동 체크리스트를
문서로 유지한다.

## 범위

### v1 — 에디터의 본질
- 3-모드: WYSIWYG / 소스 / 분할
- 파일 열기·저장, 원자적 쓰기
- 외부 변경 감지 + 충돌 정책
- 커맨드 팔레트
- 라이브 스타일링 (헤딩, 강조, 코드, 링크, 리스트)

### v2 — 에이전트 통합
- `mdner` CLI: `mdner README.md`, `mdner my-project/`
- `$EDITOR`/`$VISUAL` 등록 + Ctrl+G 셸 통합
- 내장 터미널 패널 (SwiftTerm), 높이 조절·기억

### v3 — 내보내기
- Export Preview (글꼴·여백·색·테마 조정)
- PDF 내보내기
- self-contained HTML (이미지 base64 인라인)
- 문서 1장 / 워크스페이스 전체

## 리스크

| 리스크 | 완화 |
|---|---|
| **라이브 스타일링 직접 구현이 최대 작업량.** 특히 한글 조합 중 커서와 언두 그래뉼래러티. 일정이 여기서 결정된다 | swift-markdown-engine(Apache-2.0)의 구현을 교재로 삼는다. 수동 IME 체크리스트를 초기에 만든다 |
| 표·이미지·코드블록 렌더링이 A에서 제한적 | v1 범위에서 제외. 이후 `NSTextAttachment` 블록 위젯으로 점진 해결 |
| `$EDITOR` 통합(Ctrl+G)이 까다롭다 — CLI가 앱에 열기 요청 후 **저장까지 블로킹 대기**해야 한다 | v2로 분리. XPC 또는 URL scheme + 종료 신호 대기로 설계 |
| 대용량 문서 성능 (TextKit 2 증분 파싱) | `MarkdownSyntaxMap`을 블록 단위 증분으로 설계. 전체 재파싱을 기본 경로로 두지 않는다 |
| macOS 14+ 요구 | 수용. TextKit 2 성숙도가 그 아래에서 불안정 |

## Markdowner 대비 우위

정식 코드 서명 + notarize로 배포하면 사용자가 `xattr -dr com.apple.quarantine`을 칠 필요가
없다. 현재 Markdowner 베타는 미서명이라 이 단계를 요구한다.

---

## 부록 A. 조사한 Markdowner 기능 목록

랜딩 페이지가 SPA라 JS 번들에서 문구를 추출해 정리했다.

| 기능 | 내용 |
|---|---|
| 3-모드 편집 | WYSIWYG / Editor(소스, CodeMirror 6) / Split |
| 에이전트 협업 | 외부 변경 감지 + 원자적 쓰기 |
| 무손실 왕복 | 에이전트가 읽고 쓰고 저장해도 서식 유지 |
| 내장 터미널 | 하단 패널, 높이 조절·기억, 활성 문서/워크스페이스 기준 |
| `mdner` CLI | `EDITOR=mdner` 등록, 터미널에서 Ctrl+G, 저장·종료 시 에이전트 복귀 |
| Export Preview | PDF + self-contained HTML, 글꼴·여백·색·테마 조정, 문서 1장 ~ 워크스페이스 전체 |
| 커맨드 팔레트 | VS Code 스타일 |
| 상태 | macOS 전용 베타, 무료, GitHub releases `.dmg`, 미서명 |

Markdowner 자신의 스택은 랜딩 문구에 노출되어 있다: **"Rust 우선 도큐먼트 코어
(markdowner-core)가 결정적인 파싱을 보장합니다"**, **"CodeMirror 6 기반의 순수 마크다운"**.
즉 Rust 코어 + 웹 프론트엔드 조합이다. 우리는 AD-1에 따라 웹 기술 없이 간다.

## 부록 B. 참고 링크

- [Markdowner](https://markdowner.chann.dev/)
- [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) — Apache-2.0
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT
- [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) — Apache-2.0, 교재
- [Integrating Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui) — Ghostty 아키텍처 근거
- [Ghostty macOS Implementation](https://deepwiki.com/ghostty-org/ghostty/6.2-macos-implementation)
- [Shirei](https://github.com/hasenj/go-shirei) — 검토 후 배제한 Go GUI 프레임워크
