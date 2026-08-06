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

/// 클로저에서 값을 모으기 위한 참조 상자.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
