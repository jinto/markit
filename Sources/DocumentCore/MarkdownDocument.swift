import Foundation

/// 저장이 파일을 새로 만들었는지, 기존 파일을 덮어썼는지.
public enum SaveOutcome: Equatable {
    case saved
    /// 저장 시점에 파일이 없어서 새로 만들었다. 호출자가 경고할 근거다.
    case recreated
}

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

    // MARK: - 외부 변경 감시

    public var onExternalChange: ((ExternalChange) -> Void)?
    private var watcher: FileWatching?

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
    ///
    /// "내 것 유지"에 대응하는 메서드는 없다 — 버퍼를 그대로 두면 dirty로 남고
    /// 다음 저장이 디스크를 덮어쓰므로 별도 동작이 필요 없다.
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
}
