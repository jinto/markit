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
        let count = Box(0)

        watcher.startWatching(url) {
            count.value += 1
            if count.value >= 2 { fired.fulfill() }
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

    /// 메인 런루프를 돌려 큐에 올라간 콜백을 소진시킨다.
    ///
    /// FSEvents는 스트림을 시작한 직후, 시작 전에 일어난 활동에 대한 이벤트를
    /// 흘려보낼 수 있다 (`kFSEventStreamEventIdSinceNow`를 줬어도). setUp에서 파일을
    /// 만들었으므로 그 잔여 이벤트가 온다. 필터를 제대로 검증하려면 먼저 가라앉혀야 한다.
    private func drainEvents(for seconds: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func testIgnoresOtherFilesInSameDirectory() throws {
        let count = Box(0)
        watcher.startWatching(url) { count.value += 1 }

        drainEvents()
        let baseline = count.value

        try Data("noise".utf8).write(to: dir.appendingPathComponent("other.md"),
                                     options: .atomic)
        drainEvents()

        XCTAssertEqual(count.value, baseline,
                       "같은 디렉터리의 다른 파일은 발화시키지 않아야 한다")
    }

    func testStopWatchingSilencesCallbacks() throws {
        let count = Box(0)
        watcher.startWatching(url) { count.value += 1 }

        drainEvents()
        watcher.stopWatching()
        let baseline = count.value

        try Data("after stop\n".utf8).write(to: url, options: .atomic)
        drainEvents()

        XCTAssertEqual(count.value, baseline, "중지 후에는 콜백이 오지 않아야 한다")
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
