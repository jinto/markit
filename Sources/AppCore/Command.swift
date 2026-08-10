import Foundation

/// 커맨드 팔레트에 뜨는 명령 하나.
///
/// 동작(클로저)을 담지 않는다. 명령은 값이고, 무엇을 할지는 `EditorSession`이 `id`로
/// 결정한다. 그래서 명령 목록을 비교·정렬·테스트할 수 있다.
public struct Command: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// 표시용 단축키 문자열 (예: `"⌘1"`). 실제 키 바인딩은 SwiftUI 층이 정한다.
    public let shortcut: String?

    public init(id: String, title: String, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }
}
