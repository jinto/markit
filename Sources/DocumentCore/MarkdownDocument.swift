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
