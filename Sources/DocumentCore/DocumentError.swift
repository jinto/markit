import Foundation

public enum DocumentError: Error, Equatable {
    /// 파일이 유효한 UTF-8이 아니다. 손상된 상태로 열지 않는다.
    case invalidUTF8(URL)
    /// 저장할 위치가 없다 (제목 없는 문서에 `save()`를 불렀다).
    case noURL
    /// 쓰기 실패. 원자적 쓰기이므로 원본은 온전하다.
    case writeFailed(String)
}
