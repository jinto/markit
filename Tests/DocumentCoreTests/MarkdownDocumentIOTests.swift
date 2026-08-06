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
        for (index, source) in corpus.enumerated() {
            let url = dir.appendingPathComponent("rt-\(index).md")
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
