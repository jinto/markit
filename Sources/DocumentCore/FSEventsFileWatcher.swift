import Foundation
import CoreServices

/// FSEvents로 파일 변경을 감시한다.
///
/// **부모 디렉터리를 감시하고 파일명으로 거른다.** 파일 자체를 감시하지 않는 이유:
/// 원자적 쓰기(`Data.write(options: .atomic)`)는 임시 파일에 쓰고 rename하므로
/// inode가 바뀐다 (프로브로 확인: 50332082 → 50332083). 에이전트도 원자적 쓰기를
/// 하므로, 파일 디스크립터를 감시하면 에이전트가 한 번 저장하는 순간 낡은 inode를
/// 가리키게 되어 감시가 조용히 죽는다.
public final class FSEventsFileWatcher: FileWatching {

    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?
    /// 감시 대상 파일의 정규화된 경로. 이 이름으로 이벤트를 거른다.
    private var targetPath: String?
    private let queue = DispatchQueue(label: "dev.markit.filewatcher")

    public init() {}

    deinit { tearDownStream() }

    public func startWatching(_ url: URL, onChange: @escaping () -> Void) {
        stopWatching()

        self.onChange = onChange

        // FSEvents는 정규화된 경로로 이벤트를 준다 (`/private/var/...`). 비교가 맞으려면
        // 감시 대상 경로도 같은 방식으로 정규화해야 한다.
        //
        // `URL.resolvingSymlinksInPath()`를 쓰면 안 된다 — macOS에서 `/var`를 풀지
        // 않는다 (확인: `/var/folders/...`를 그대로 되돌려 준다). 그러면 필터가 모든
        // 이벤트를 거부해 감시가 조용히 죽는다. `realpath(3)`은 올바르게
        // `/private/var/folders/...`로 정규화한다.
        //
        // 파일이 아니라 디렉터리를 정규화하는 이유: 삭제를 감지해야 하므로 대상 파일이
        // 없는 상태도 다뤄야 하고, `realpath`는 없는 경로에 실패한다.
        let canonicalDir = Self.canonicalPath(of: url.deletingLastPathComponent())
        let resolvedDir = URL(fileURLWithPath: canonicalDir)
        self.targetPath = resolvedDir.appendingPathComponent(url.lastPathComponent).path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsFileWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes를 쓰지 않았으므로 char** 이다.
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            for i in 0..<count {
                guard let cPath = paths[i] else { continue }
                watcher.handleEvent(path: String(cString: cPath))
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [resolvedDir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,  // 지연(초). 짧게 잡아 에이전트 편집이 바로 보이게 한다
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stopWatching() {
        tearDownStream()
        onChange = nil
        targetPath = nil
    }

    private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// 이벤트 판정과 전달을 **모두 메인 큐에서** 한다.
    ///
    /// FSEvents 콜백은 `queue`에서 오지만 `targetPath`/`onChange`는 메인에서만
    /// 만지도록 통일해 경쟁을 없앤다. 부수 효과로 `stopWatching()` 이후 이미 큐에
    /// 올라간 이벤트가 조용히 버려진다 — 중지했는데 콜백이 오는 문제가 사라진다.
    ///
    /// 전제: `startWatching`/`stopWatching`은 메인에서 호출한다 (소비자가 UI다).
    private func handleEvent(path: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let targetPath = self.targetPath,
                  // 정확한 파일명 비교가 원자적 쓰기의 임시 파일 소음을 걸러 준다.
                  // (`watched.md.sb-0a6385a3-URZk2p` 같은 이벤트가 함께 온다.)
                  path == targetPath,
                  let onChange = self.onChange
            else { return }
            onChange()
        }
    }

    /// `realpath(3)`으로 경로를 정규화한다. 대상이 존재해야 한다.
    private static func canonicalPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
