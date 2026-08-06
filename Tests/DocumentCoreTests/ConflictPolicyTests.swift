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
