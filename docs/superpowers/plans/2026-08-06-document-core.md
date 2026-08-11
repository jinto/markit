# DocumentCore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 파일 하나의 상태를 소유하는 헤드리스 레이어. 로드, 원자적 저장, dirty 추적, 외부 변경 감지, 충돌 정책. UI 없이 `swift test`로 전부 검증된다.

**Architecture:** 설계 문서 AD-2에 따라 버퍼가 곧 파일 내용이다. 파싱·재직렬화가 없으므로 무손실 왕복은 구조적으로 보장된다. 외부 변경 감지는 `FileWatching` 프로토콜 뒤에 숨겨 테스트에서 가짜 감시자로 대체한다 — FSEvents는 비동기·OS 주도라 결정적 테스트가 불가능하기 때문이다.

**Tech Stack:** Swift 5.9+, macOS 14+, Foundation, CoreServices (FSEvents), XCTest

## Global Constraints

- 최소 플랫폼: `.macOS(.v14)`
- 이 타깃은 **AppKit/SwiftUI를 import하지 않는다.** 헤드리스 유지가 테스트 가능성의 근거다
- 새 서드파티 의존성을 추가하지 않는다. Foundation과 CoreServices만 쓴다
- 저장은 반드시 원자적이어야 한다. 에이전트가 같은 파일을 읽는 중에 부분 기록된 파일을 보면 안 된다
- 재직렬화 금지. 이 레이어는 텍스트를 바이트로만 다룬다
- 테스트 프레임워크는 XCTest
- 라이선스: MIT

## 검증된 사실 (직접 프로브해서 확인 — 추측 아님)

**1. `Data.write(options: .atomic)`은 inode를 바꾼다.**

```
before:  inode=50332082 perm=640
atomic:  inode=50332083 perm=640   inode변경=true
plain:   inode=50332083 perm=640   inode변경=false
```

임시 파일에 쓰고 rename하기 때문이다. **결과: 파일 디스크립터 기반 감시
(`DispatchSource.makeFileSystemObjectSource`)를 쓸 수 없다.** 에이전트도 원자적 쓰기를
하므로, 파일을 감시하면 에이전트가 한 번 저장하는 순간 fd가 낡은 inode를 가리키게 되어
감시가 조용히 죽는다. **부모 디렉터리를 FSEvents로 감시하고 파일명으로 걸러야 한다.**

**2. 원자적 쓰기는 POSIX 권한을 보존한다** (640 → 640). 속성 복원 코드가 필요 없다.

**3. 잘못된 UTF-8은 `String(data:encoding:.utf8)`이 `nil`을 낸다.** 로드 거부가 가능하다.

## 자기 저장의 메아리 문제

우리가 저장하면 FSEvents가 발화한다. 자기 쓰기를 외부 변경으로 오인하면 무한 루프거나
가짜 충돌 대화상자가 뜬다.

**해법: 디스크 내용을 버퍼와 비교한다.** 같으면 아무 일도 없었던 것으로 본다. 이 한 가지
규칙이 세 경우를 모두 옳게 처리한다:

| 경우 | 디스크 vs 버퍼 | 처리 |
|---|---|---|
| 우리 저장이 메아리로 돌아옴 | 같음 | 무시 |
| 에이전트가 버퍼와 똑같은 내용을 씀 | 같음 | 무시 (실제로 달라진 게 없다) |
| 에이전트가 다른 내용을 씀 | 다름 | 충돌 정책 적용 |

별도의 "마지막으로 쓴 내용" 장부가 필요 없다.

## File Structure

```
Sources/DocumentCore/
  DocumentError.swift        오류 타입
  FileWatching.swift         감시자 프로토콜 (테스트에서 대체 가능하게 만드는 이음새)
  MarkdownDocument.swift     파일 하나의 상태. 로드/저장/dirty/충돌
  FSEventsFileWatcher.swift  실제 감시자. 부모 디렉터리를 본다
Tests/DocumentCoreTests/
  FakeFileWatcher.swift          테스트 지원 — 동기적으로 변경을 발화시킨다
  MarkdownDocumentIOTests.swift  로드/저장/dirty/원자성
  ConflictPolicyTests.swift      외부 변경 4가지 시나리오
  FSEventsFileWatcherTests.swift 실제 감시자 통합 테스트
```

`Package.swift`에 `DocumentCore` 타깃과 `DocumentCoreTests` 테스트 타깃을 추가한다.
`DocumentCore`는 `MarkdownSyntax`에 의존하지 **않는다** — 두 레이어는 독립이고, 조립은
상위(앱)에서 한다.

---

### Task 1: MarkdownDocument — 파일 IO와 dirty 추적

**Files:**
- Modify: `Package.swift`
- Create: `Sources/DocumentCore/DocumentError.swift`
- Create: `Sources/DocumentCore/MarkdownDocument.swift`
- Test: `Tests/DocumentCoreTests/MarkdownDocumentIOTests.swift`

**Interfaces:**
- Consumes: 없음 (Foundation만)
- Produces:
  - `public enum DocumentError: Error, Equatable` — `invalidUTF8(URL)`, `noURL`, `writeFailed(String)`
  - `public enum SaveOutcome: Equatable` — `saved`, `recreated`
  - `public final class MarkdownDocument`
    - `public init(text: String = "", url: URL? = nil)`
    - `public convenience init(loadingFrom url: URL) throws`
    - `public private(set) var url: URL?`
    - `public var text: String`
    - `public var isDirty: Bool` (읽기 전용 계산 속성)
    - `@discardableResult public func save() throws -> SaveOutcome`
    - `public func save(to url: URL) throws -> SaveOutcome`

- [ ] **Step 1: Write the failing test**

`Package.swift`에 타깃을 먼저 추가한다 (테스트가 컴파일되려면 필요하다):

```swift
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
```
를 `products`에, 그리고 `targets`에:
```swift
        .target(name: "DocumentCore"),
        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentCore"]),
```

`Tests/DocumentCoreTests/MarkdownDocumentIOTests.swift`:

```swift
import XCTest
@testable import DocumentCore

final class MarkdownDocumentIOTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String = "doc.md", contents: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let contents { try Data(contents.utf8).write(to: url) }
        return url
    }

    // MARK: - 로드

    func testLoadReadsText() throws {
        let url = try file(contents: "# 제목\n본문\n")
        let doc = try MarkdownDocument(loadingFrom: url)
        XCTAssertEqual(doc.text, "# 제목\n본문\n")
        XCTAssertEqual(doc.url, url)
        XCTAssertFalse(doc.isDirty)
    }

    func testLoadRejectsInvalidUTF8() throws {
        let url = dir.appendingPathComponent("bad.md")
        try Data([0xFF, 0xFE, 0x41]).write(to: url)
        XCTAssertThrowsError(try MarkdownDocument(loadingFrom: url)) { error in
            XCTAssertEqual(error as? DocumentError, .invalidUTF8(url))
        }
    }

    func testLoadMissingFileThrows() throws {
        let url = dir.appendingPathComponent("nope.md")
        XCTAssertThrowsError(try MarkdownDocument(loadingFrom: url))
    }

    // MARK: - dirty 추적

    func testNewDocumentIsClean() {
        XCTAssertFalse(MarkdownDocument().isDirty)
    }

    func testEditingMarksDirty() throws {
        let doc = try MarkdownDocument(loadingFrom: try file(contents: "a"))
        XCTAssertFalse(doc.isDirty)
        doc.text = "b"
        XCTAssertTrue(doc.isDirty)
    }

    func testRevertingEditClearsDirty() throws {
        let doc = try MarkdownDocument(loadingFrom: try file(contents: "a"))
        doc.text = "b"
        doc.text = "a"
        XCTAssertFalse(doc.isDirty, "내용이 원래대로 돌아왔으면 dirty가 아니다")
    }

    func testSaveClearsDirty() throws {
        let doc = try MarkdownDocument(loadingFrom: try file(contents: "a"))
        doc.text = "b"
        XCTAssertEqual(try doc.save(), .saved)
        XCTAssertFalse(doc.isDirty)
    }

    // MARK: - 저장

    func testSaveWritesBytesExactly() throws {
        let url = try file(contents: "old")
        let doc = try MarkdownDocument(loadingFrom: url)
        doc.text = "# 제목\n\n한글 **강조** 👨‍👩‍👧\n"
        try doc.save()
        XCTAssertEqual(try Data(contentsOf: url), Data(doc.text.utf8))
    }

    /// AD-2의 핵심 회귀 테스트. 로드→저장이 바이트 동일해야 한다.
    func testRoundTripIsByteIdentical() throws {
        let corpus = [
            "# h1\n## h2\n",
            "**bold** *it* `code`\n",
            "- a\n- b\n  - nested\n",
            "> quote\n\n```swift\nlet x = 1\n```\n",
            "한글 문서 **강조**\n",
            "👨‍👩‍👧 이모지\n",
            "crlf\r\nline\r\n",
            "trailing   \n\n\n",
            "\\*escaped\\*\n",
            "no trailing newline",
            "",
        ]
        for source in corpus {
            let url = dir.appendingPathComponent("rt-\(abs(source.hashValue)).md")
            let original = Data(source.utf8)
            try original.write(to: url)

            let doc = try MarkdownDocument(loadingFrom: url)
            try doc.save()

            XCTAssertEqual(try Data(contentsOf: url), original,
                           "왕복이 바이트를 바꿨다: \(source.debugDescription)")
        }
    }

    func testSaveWithoutURLThrows() {
        let doc = MarkdownDocument(text: "x")
        XCTAssertThrowsError(try doc.save()) { error in
            XCTAssertEqual(error as? DocumentError, .noURL)
        }
    }

    func testSaveToURLAdoptsIt() throws {
        let doc = MarkdownDocument(text: "content")
        let url = try file("new.md")
        XCTAssertEqual(try doc.save(to: url), .recreated)
        XCTAssertEqual(doc.url, url)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), Data("content".utf8))
    }

    /// 저장 중 파일이 사라져 있었으면 재생성하고 그 사실을 알린다.
    func testSaveRecreatesDeletedFile() throws {
        let url = try file(contents: "a")
        let doc = try MarkdownDocument(loadingFrom: url)
        try FileManager.default.removeItem(at: url)
        doc.text = "b"
        XCTAssertEqual(try doc.save(), .recreated)
        XCTAssertEqual(try Data(contentsOf: url), Data("b".utf8))
    }

    /// 저장이 실패하면 원본이 보존되고 dirty가 유지되어야 한다.
    func testFailedSaveKeepsDirtyAndPreservesFile() throws {
        let url = try file(contents: "original")
        let doc = try MarkdownDocument(loadingFrom: url)
        doc.text = "modified"

        // 디렉터리를 읽기 전용으로 만들어 쓰기를 실패시킨다.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: dir.path)
        }

        XCTAssertThrowsError(try doc.save())
        XCTAssertTrue(doc.isDirty, "저장 실패 후에도 dirty여야 한다")
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8),
                       "원자적 쓰기이므로 원본이 온전해야 한다")
    }

    /// 원자적 쓰기가 권한을 보존한다 (프로브로 확인된 동작을 고정한다).
    func testSavePreservesPermissions() throws {
        let url = try file(contents: "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o640],
                                             ofItemAtPath: url.path)
        let doc = try MarkdownDocument(loadingFrom: url)
        doc.text = "b"
        try doc.save()

        let perm = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perm, 0o640)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MarkdownDocumentIOTests`
Expected: 컴파일 실패 — `no such module 'DocumentCore'` 또는 `cannot find 'MarkdownDocument'`

- [ ] **Step 3: Write minimal implementation**

`Sources/DocumentCore/DocumentError.swift`:

```swift
import Foundation

public enum DocumentError: Error, Equatable {
    /// 파일이 유효한 UTF-8이 아니다. 손상된 상태로 열지 않는다.
    case invalidUTF8(URL)
    /// 저장할 위치가 없다 (제목 없는 문서에 `save()`를 불렀다).
    case noURL
    /// 쓰기 실패. 원자적 쓰기이므로 원본은 온전하다.
    case writeFailed(String)
}
```

`Sources/DocumentCore/MarkdownDocument.swift`:

```swift
import Foundation

/// 저장이 파일을 새로 만들었는지, 기존 파일을 덮어썼는지.
public enum SaveOutcome: Equatable {
    case saved
    /// 저장 시점에 파일이 없어서 새로 만들었다. 호출자가 경고할 근거다.
    case recreated
}

/// 마크다운 파일 하나의 상태.
///
/// 설계 문서 AD-2에 따라 **버퍼가 곧 파일 내용이다.** 파싱하거나 재직렬화하지 않으므로
/// 로드→저장이 바이트 동일함이 구조적으로 보장된다. 이것이 무손실 왕복과 에이전트
/// 협업의 근거다.
public final class MarkdownDocument {

    public private(set) var url: URL?
    public var text: String

    /// 마지막으로 디스크와 일치했던 내용. dirty 판정의 기준점이다.
    private var savedText: String

    public var isDirty: Bool { text != savedText }

    public init(text: String = "", url: URL? = nil) {
        self.text = text
        self.savedText = text
        self.url = url
    }

    public convenience init(loadingFrom url: URL) throws {
        let text = try Self.readText(from: url)
        self.init(text: text, url: url)
    }

    // MARK: - 읽기

    static func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentError.invalidUTF8(url)
        }
        return text
    }

    // MARK: - 저장

    @discardableResult
    public func save() throws -> SaveOutcome {
        guard let url else { throw DocumentError.noURL }
        return try write(to: url)
    }

    @discardableResult
    public func save(to url: URL) throws -> SaveOutcome {
        let outcome = try write(to: url)
        self.url = url
        return outcome
    }

    private func write(to url: URL) throws -> SaveOutcome {
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            // `.atomic`은 임시 파일에 쓰고 rename한다. 에이전트가 같은 파일을 읽는 중에
            // 부분 기록된 내용을 보는 일이 없고, 실패해도 원본이 온전하다.
            // 권한도 보존된다 (프로브로 확인).
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            // savedText를 갱신하지 않으므로 dirty가 유지된다.
            throw DocumentError.writeFailed(error.localizedDescription)
        }
        savedText = text
        return existed ? .saved : .recreated
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MarkdownDocumentIOTests`
Expected: 15개 테스트 PASS

`testRoundTripIsByteIdentical`이 실패하면 어딘가에서 텍스트를 정규화하고 있다는 뜻이다 —
AD-2 위반이므로 즉시 고친다.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/DocumentCore Tests/DocumentCoreTests
git commit -m "feat: add MarkdownDocument with atomic save and byte-identical round-trip"
```

---

### Task 2: 외부 변경 감지와 충돌 정책

**Files:**
- Create: `Sources/DocumentCore/FileWatching.swift`
- Modify: `Sources/DocumentCore/MarkdownDocument.swift`
- Create: `Tests/DocumentCoreTests/FakeFileWatcher.swift`
- Test: `Tests/DocumentCoreTests/ConflictPolicyTests.swift`

**Interfaces:**
- Consumes: `MarkdownDocument` (Task 1)
- Produces:
  - `public protocol FileWatching: AnyObject` — `func startWatching(_ url: URL, onChange: @escaping () -> Void)`, `func stopWatching()`
  - `public enum ExternalChange: Equatable` — `reloaded`, `conflict(diskText: String)`, `fileDisappeared`
  - `MarkdownDocument`에 추가:
    - `public var onExternalChange: ((ExternalChange) -> Void)?`
    - `public func beginWatching(with watcher: FileWatching)`
    - `public func stopWatching()`
    - `public func acceptDiskVersion(_ diskText: String)`

- [ ] **Step 1: Write the failing test**

`Tests/DocumentCoreTests/FakeFileWatcher.swift`:

```swift
import Foundation
@testable import DocumentCore

/// 테스트용 감시자. FSEvents는 비동기·OS 주도라 결정적 테스트가 불가능하므로,
/// 충돌 정책 검증에는 이 가짜를 쓰고 변경을 동기적으로 발화시킨다.
final class FakeFileWatcher: FileWatching {
    private(set) var watchedURL: URL?
    private(set) var stopCallCount = 0
    private var onChange: (() -> Void)?

    func startWatching(_ url: URL, onChange: @escaping () -> Void) {
        watchedURL = url
        self.onChange = onChange
    }

    func stopWatching() {
        stopCallCount += 1
        watchedURL = nil
        onChange = nil
    }

    /// 외부 변경이 일어난 것처럼 동기적으로 발화시킨다.
    func fireChange() { onChange?() }
}
```

`Tests/DocumentCoreTests/ConflictPolicyTests.swift`:

```swift
import XCTest
@testable import DocumentCore

final class ConflictPolicyTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    private var watcher: FakeFileWatcher!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markit-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("doc.md")
        try Data("original\n".utf8).write(to: url)
        watcher = FakeFileWatcher()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDocument() throws -> (MarkdownDocument, Box<[ExternalChange]>) {
        let doc = try MarkdownDocument(loadingFrom: url)
        let received = Box<[ExternalChange]>([])
        doc.onExternalChange = { received.value.append($0) }
        doc.beginWatching(with: watcher)
        return (doc, received)
    }

    private func writeToDisk(_ text: String) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - 시나리오 1: 외부 변경 + 버퍼 clean → 자동 리로드

    func testCleanBufferAutoReloads() throws {
        let (doc, received) = try makeDocument()
        try writeToDisk("agent wrote this\n")
        watcher.fireChange()

        XCTAssertEqual(received.value, [.reloaded])
        XCTAssertEqual(doc.text, "agent wrote this\n")
        XCTAssertFalse(doc.isDirty, "리로드 후에는 디스크와 일치하므로 clean이다")
    }

    // MARK: - 시나리오 2: 외부 변경 + 버퍼 dirty → 충돌 보고

    func testDirtyBufferReportsConflictWithoutOverwriting() throws {
        let (doc, received) = try makeDocument()
        doc.text = "my edit\n"
        try writeToDisk("agent edit\n")
        watcher.fireChange()

        XCTAssertEqual(received.value, [.conflict(diskText: "agent edit\n")])
        XCTAssertEqual(doc.text, "my edit\n", "조용히 덮어쓰지 않는다")
        XCTAssertTrue(doc.isDirty)
    }

    func testAcceptDiskVersionReplacesBufferAndClearsDirty() throws {
        let (doc, _) = try makeDocument()
        doc.text = "my edit\n"
        try writeToDisk("agent edit\n")
        watcher.fireChange()

        doc.acceptDiskVersion("agent edit\n")
        XCTAssertEqual(doc.text, "agent edit\n")
        XCTAssertFalse(doc.isDirty)
    }

    /// "내 것 유지"는 별도 동작이 없다. 버퍼가 dirty로 남고 다음 저장이 덮어쓴다.
    func testKeepingMineThenSavingOverwritesDisk() throws {
        let (doc, _) = try makeDocument()
        doc.text = "my edit\n"
        try writeToDisk("agent edit\n")
        watcher.fireChange()

        try doc.save()
        XCTAssertEqual(try Data(contentsOf: url), Data("my edit\n".utf8))
        XCTAssertFalse(doc.isDirty)
    }

    // MARK: - 시나리오 3: 자기 저장의 메아리 → 무시

    func testOwnSaveDoesNotReportExternalChange() throws {
        let (doc, received) = try makeDocument()
        doc.text = "my edit\n"
        try doc.save()
        watcher.fireChange()   // FSEvents가 우리 쓰기에 발화한 상황

        XCTAssertTrue(received.value.isEmpty, "자기 저장을 외부 변경으로 오인하면 안 된다")
        XCTAssertFalse(doc.isDirty)
    }

    /// 에이전트가 우연히 버퍼와 똑같은 내용을 써도 알릴 게 없다.
    func testIdenticalDiskContentIsIgnoredAndClearsDirty() throws {
        let (doc, received) = try makeDocument()
        doc.text = "same\n"
        try writeToDisk("same\n")
        watcher.fireChange()

        XCTAssertTrue(received.value.isEmpty)
        XCTAssertFalse(doc.isDirty, "디스크와 일치하므로 clean이 되어야 한다")
    }

    // MARK: - 시나리오 4: 파일 사라짐

    func testDeletedFileReportsDisappeared() throws {
        let (doc, received) = try makeDocument()
        try FileManager.default.removeItem(at: url)
        watcher.fireChange()

        XCTAssertEqual(received.value, [.fileDisappeared])
        XCTAssertEqual(doc.text, "original\n", "버퍼는 그대로 남는다")
    }

    // MARK: - 감시 수명

    func testBeginWatchingWatchesDocumentURL() throws {
        _ = try makeDocument()
        XCTAssertEqual(watcher.watchedURL, url)
    }

    func testStopWatchingStopsTheWatcher() throws {
        let (doc, _) = try makeDocument()
        doc.stopWatching()
        XCTAssertEqual(watcher.stopCallCount, 1)
    }

    func testChangeAfterStopIsIgnored() throws {
        let (doc, received) = try makeDocument()
        doc.stopWatching()
        try writeToDisk("agent wrote\n")
        watcher.fireChange()   // 가짜는 콜백을 버렸으므로 아무 일도 없다
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertEqual(doc.text, "original\n")
    }

    /// 잘못된 UTF-8이 디스크에 나타나면 버퍼를 건드리지 않는다.
    func testInvalidUTF8OnDiskDoesNotClobberBuffer() throws {
        let (doc, received) = try makeDocument()
        try Data([0xFF, 0xFE]).write(to: url, options: .atomic)
        watcher.fireChange()

        XCTAssertEqual(doc.text, "original\n", "읽을 수 없는 내용으로 버퍼를 덮지 않는다")
        XCTAssertTrue(received.value.isEmpty)
    }
}

/// 클로저에서 값을 모으기 위한 참조 상자.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConflictPolicyTests`
Expected: 컴파일 실패 — `cannot find 'FileWatching'`, `cannot find 'ExternalChange'`

- [ ] **Step 3: Write minimal implementation**

`Sources/DocumentCore/FileWatching.swift`:

```swift
import Foundation

/// 파일 변경 감시자의 이음새.
///
/// 프로토콜로 두는 이유는 테스트다. FSEvents는 비동기이고 OS가 발화 시점을 정하므로
/// 결정적 테스트가 불가능하다. 충돌 정책은 이 프로토콜의 가짜 구현으로 검증하고,
/// 실제 FSEvents 구현은 별도의 통합 테스트로 확인한다.
public protocol FileWatching: AnyObject {
    func startWatching(_ url: URL, onChange: @escaping () -> Void)
    func stopWatching()
}
```

`Sources/DocumentCore/MarkdownDocument.swift`에 추가 — 먼저 파일 상단에 타입 추가:

```swift
/// 열어 둔 파일이 외부에서 바뀌었을 때 무슨 일이 있었는지.
public enum ExternalChange: Equatable {
    /// 버퍼가 clean이어서 자동으로 리로드했다. 알림만 하면 된다.
    /// 에이전트 협업의 기본 경로다.
    case reloaded
    /// 버퍼가 dirty라 자동 리로드하지 않았다. 사용자가 골라야 한다.
    case conflict(diskText: String)
    /// 파일이 사라졌다. 버퍼는 그대로 남는다.
    case fileDisappeared
}
```

`MarkdownDocument` 안에 추가:

```swift
    public var onExternalChange: ((ExternalChange) -> Void)?
    private var watcher: FileWatching?

    // MARK: - 외부 변경 감시

    public func beginWatching(with watcher: FileWatching) {
        guard let url else { return }
        self.watcher = watcher
        watcher.startWatching(url) { [weak self] in
            self?.handleFileSystemChange()
        }
    }

    public func stopWatching() {
        watcher?.stopWatching()
        watcher = nil
    }

    /// 충돌 대화에서 사용자가 디스크 버전을 택했을 때.
    public func acceptDiskVersion(_ diskText: String) {
        text = diskText
        savedText = diskText
    }

    /// 충돌 정책의 전부. 설계 문서의 표를 그대로 구현한다.
    private func handleFileSystemChange() {
        guard let url else { return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            onExternalChange?(.fileDisappeared)
            return
        }

        // 읽을 수 없으면(잘못된 UTF-8, 일시적 상태) 버퍼를 건드리지 않는다.
        guard let diskText = try? Self.readText(from: url) else { return }

        // 디스크가 버퍼와 같으면 알릴 게 없다. 이 한 줄이 자기 저장의 메아리와
        // 에이전트가 같은 내용을 쓴 경우를 모두 처리한다.
        if diskText == text {
            savedText = diskText
            return
        }

        if isDirty {
            onExternalChange?(.conflict(diskText: diskText))
        } else {
            text = diskText
            savedText = diskText
            onExternalChange?(.reloaded)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConflictPolicyTests`
Expected: 12개 테스트 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/DocumentCore Tests/DocumentCoreTests
git commit -m "feat: add external change detection and conflict policy"
```

---

### Task 3: FSEventsFileWatcher — 부모 디렉터리 감시

검증된 사실 1번에 따라 파일이 아니라 부모 디렉터리를 감시한다.

**Files:**
- Create: `Sources/DocumentCore/FSEventsFileWatcher.swift`
- Test: `Tests/DocumentCoreTests/FSEventsFileWatcherTests.swift`

**Interfaces:**
- Consumes: `FileWatching` (Task 2)
- Produces:
  - `public final class FSEventsFileWatcher: FileWatching`
  - `public init()`
  - 콜백은 메인 큐로 전달된다 (소비자가 UI다)

- [ ] **Step 1: Write the failing test**

`Tests/DocumentCoreTests/FSEventsFileWatcherTests.swift`:

```swift
import XCTest
@testable import DocumentCore

/// 실제 FSEvents 통합 테스트. OS가 발화 시점을 정하므로 expectation과 넉넉한
/// 타임아웃을 쓴다. 결정적 충돌 정책 검증은 `ConflictPolicyTests`가 담당한다.
final class FSEventsFileWatcherTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    private var watcher: FSEventsFileWatcher!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markit-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("watched.md")
        try Data("initial\n".utf8).write(to: url)
        watcher = FSEventsFileWatcher()
    }

    override func tearDownWithError() throws {
        watcher.stopWatching()
        try? FileManager.default.removeItem(at: dir)
    }

    func testDetectsAtomicWrite() throws {
        let fired = expectation(description: "변경 감지")
        fired.assertForOverFulfill = false
        watcher.startWatching(url) { fired.fulfill() }

        // FSEvents 스트림이 뜰 시간을 준다.
        Thread.sleep(forTimeInterval: 0.3)
        try Data("changed by agent\n".utf8).write(to: url, options: .atomic)

        wait(for: [fired], timeout: 10)
    }

    /// 원자적 쓰기는 inode를 바꾼다 (프로브로 확인). 부모 디렉터리를 감시하므로
    /// 연속된 원자적 쓰기를 계속 감지해야 한다. 파일 fd를 감시했다면 여기서 죽는다.
    func testSurvivesRepeatedAtomicWrites() throws {
        let fired = expectation(description: "두 번째 원자적 쓰기 감지")
        fired.assertForOverFulfill = false
        var writeCount = 0

        watcher.startWatching(url) {
            writeCount += 1
            if writeCount >= 2 { fired.fulfill() }
        }

        Thread.sleep(forTimeInterval: 0.3)
        try Data("first\n".utf8).write(to: url, options: .atomic)
        Thread.sleep(forTimeInterval: 0.4)
        try Data("second\n".utf8).write(to: url, options: .atomic)

        wait(for: [fired], timeout: 10)
    }

    func testDetectsDeletion() throws {
        let fired = expectation(description: "삭제 감지")
        fired.assertForOverFulfill = false
        watcher.startWatching(url) { fired.fulfill() }

        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.removeItem(at: url)

        wait(for: [fired], timeout: 10)
    }

    func testIgnoresOtherFilesInSameDirectory() throws {
        let unrelated = expectation(description: "무관한 파일은 발화하지 않는다")
        unrelated.isInverted = true
        watcher.startWatching(url) { unrelated.fulfill() }

        Thread.sleep(forTimeInterval: 0.3)
        try Data("noise".utf8).write(to: dir.appendingPathComponent("other.md"),
                                    options: .atomic)

        wait(for: [unrelated], timeout: 3)
    }

    func testStopWatchingSilencesCallbacks() throws {
        let silent = expectation(description: "중지 후에는 발화하지 않는다")
        silent.isInverted = true
        watcher.startWatching(url) { silent.fulfill() }
        Thread.sleep(forTimeInterval: 0.3)
        watcher.stopWatching()

        try Data("after stop\n".utf8).write(to: url, options: .atomic)
        wait(for: [silent], timeout: 3)
    }

    func testCallbackArrivesOnMainQueue() throws {
        let onMain = expectation(description: "메인 큐에서 온다")
        onMain.assertForOverFulfill = false
        watcher.startWatching(url) {
            XCTAssertTrue(Thread.isMainThread)
            onMain.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.3)
        try Data("x\n".utf8).write(to: url, options: .atomic)
        wait(for: [onMain], timeout: 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FSEventsFileWatcherTests`
Expected: 컴파일 실패 — `cannot find 'FSEventsFileWatcher' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/DocumentCore/FSEventsFileWatcher.swift`:

```swift
import Foundation
import CoreServices

/// FSEvents로 파일 변경을 감시한다.
///
/// **부모 디렉터리를 감시하고 파일명으로 거른다.** 파일 자체를 감시하지 않는 이유:
/// 원자적 쓰기(`Data.write(options: .atomic)`)는 임시 파일에 쓰고 rename하므로
/// inode가 바뀐다 (프로브로 확인: 50332082 → 50332083). 에이전트도 원자적 쓰기를
/// 하므로, 파일 디스크립터를 감시하면 에이전트가 한 번 저장하는 순간 낡은 inode를
/// 가리키게 되어 감시가 조용히 죽는다.
public final class FSEventsFileWatcher: FileWatching {

    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?
    /// 감시 대상 파일의 정규화된 경로. 이 이름으로 이벤트를 거른다.
    private var targetPath: String?
    private let queue = DispatchQueue(label: "dev.markit.filewatcher")

    public init() {}

    deinit { tearDownStream() }

    public func startWatching(_ url: URL, onChange: @escaping () -> Void) {
        stopWatching()

        self.onChange = onChange
        // 심볼릭 링크를 풀어야 FSEvents가 주는 경로와 비교가 맞는다.
        // (/var → /private/var 같은 경우)
        let resolvedDir = url.deletingLastPathComponent().resolvingSymlinksInPath()
        self.targetPath = resolvedDir
            .appendingPathComponent(url.lastPathComponent).path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsFileWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes를 쓰지 않았으므로 char** 이다.
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            for i in 0..<count {
                guard let cPath = paths[i] else { continue }
                watcher.handleEvent(path: String(cString: cPath))
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [resolvedDir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,  // 지연(초). 짧게 잡아 에이전트 편집이 바로 보이게 한다
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stopWatching() {
        tearDownStream()
        onChange = nil
        targetPath = nil
    }

    private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleEvent(path: String) {
        guard let targetPath, path == targetPath, let onChange else { return }
        // 소비자가 UI이므로 메인 큐로 넘긴다.
        DispatchQueue.main.async { onChange() }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FSEventsFileWatcherTests`
Expected: 6개 테스트 PASS

`testIgnoresOtherFilesInSameDirectory`가 실패하면 경로 필터가 동작하지 않는다는 뜻이다 —
`resolvingSymlinksInPath()` 처리를 확인한다. macOS에서 `NSTemporaryDirectory()`는
`/var/folders/...`를 주고 FSEvents는 `/private/var/folders/...`를 준다.

- [ ] **Step 5: Commit**

```bash
git add Sources/DocumentCore/FSEventsFileWatcher.swift Tests/DocumentCoreTests/FSEventsFileWatcherTests.swift
git commit -m "feat: add FSEvents file watcher watching parent directory"
```

---

## 이 계획의 범위 밖

- diff 보기 UI — 충돌 시 "diff 보기"는 UI 기능이므로 Plan 4에서 다룬다. 이 레이어는
  `conflict(diskText:)`로 양쪽 텍스트를 넘기는 데까지만 책임진다
- 워크스페이스(디렉터리) 열기 — v2의 `mdner my-project/`에서 다룬다
- 여러 문서 동시 관리 — 앱 층의 책임이다

## Self-Review

**스펙 커버리지.** 설계 문서 컴포넌트 1번(`MarkdownDocument`)과 7번(`FileWatcher`)을 덮는다.
"에러 처리 / 충돌 정책" 표의 5개 행이 모두 테스트를 갖는다:

| 스펙의 행 | 테스트 |
|---|---|
| 외부 변경 + 버퍼 clean → 자동 리로드 | `testCleanBufferAutoReloads` |
| 외부 변경 + 버퍼 dirty → 사용자 선택 | `testDirtyBufferReportsConflictWithoutOverwriting` |
| 저장 중 파일 삭제됨 → 재생성하고 경고 | `testSaveRecreatesDeletedFile` (`.recreated`) |
| 저장 실패 → 원본 보존, dirty 유지 | `testFailedSaveKeepsDirtyAndPreservesFile` |
| 잘못된 UTF-8 → 로드 거부 | `testLoadRejectsInvalidUTF8` |

테스트 전략의 "무손실 왕복 코퍼스 바이트 비교"는 `testRoundTripIsByteIdentical`이다.

**타입 일관성.** `DocumentError`(Task 1)가 Task 2의 `readText` 실패 경로에서 쓰인다.
`FileWatching`(Task 2)을 `FakeFileWatcher`(Task 2)와 `FSEventsFileWatcher`(Task 3)가
같은 시그니처로 구현한다. `SaveOutcome`(Task 1)이 Task 1 테스트에서만 쓰인다.

**스펙에 없어서 추가한 것.** 자기 저장의 메아리 억제. 스펙의 충돌 표에는 없지만 없으면
저장할 때마다 가짜 충돌이 뜬다. 디스크와 버퍼를 비교하는 한 줄로 해결하고
`testOwnSaveDoesNotReportExternalChange`로 고정했다. 설계 문서에도 반영해야 한다.
