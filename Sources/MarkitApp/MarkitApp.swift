import AppKit
import SwiftUI

@main
struct MarkitApp: App {

    init() {
        // `swift run MarkitApp`은 번들 없이 실행되고, 그때 activationPolicy가
        // .prohibited로 시작한다. 창은 보이지만 앱이 활성화되지 않아 **키 입력이
        // 들어오지 않는다** (프로브로 확인).
        //
        // `scripts/make-app.sh`로 만든 Markit.app에서는 번들이 있으므로 이미 .regular다.
        // 그래도 이 줄을 남긴다 — 개발 루프가 `swift run`이기 때문이다.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            EditorWindow()
                .frame(minWidth: 520, minHeight: 360)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified)
    }
}
