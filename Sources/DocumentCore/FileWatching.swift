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
