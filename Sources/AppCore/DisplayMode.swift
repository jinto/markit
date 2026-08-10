import EditorKit

/// 세 표시 모드.
///
/// 세 모드가 **같은 원문 버퍼를 공유한다.** 모드 전환은 표시 정책 변경일 뿐 문서 변환이
/// 아니다 — AD-2의 직접적 이득이다. 그래서 모드를 아무리 바꿔도 저장 결과가 바뀌지 않는다.
public enum DisplayMode: CaseIterable, Sendable {
    /// 마커를 접어 결과에 가깝게 보여준다.
    case wysiwyg
    /// 마커를 모두 노출한다. 구문 색만 입힌 원문.
    case source
    /// 왼쪽 원문(편집) + 오른쪽 프리뷰(읽기 전용).
    case split

    /// 이 모드에서 편집 뷰가 쓸 마커 정책.
    var sourceMarkerPolicy: MarkerPolicy {
        switch self {
        case .wysiwyg: return .hideWhenInactive
        // 분할 모드의 왼쪽은 원문 쪽이므로 마커를 보여준다. 접힌 모습은 오른쪽에 있다.
        case .source, .split: return .revealAll
        }
    }

    var showsPreview: Bool { self == .split }
}
