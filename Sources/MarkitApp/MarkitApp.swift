import AppKit
import SwiftUI

@main
struct MarkitApp: App {

    init() {
        // 번들 없는 SPM 실행 파일은 activationPolicy가 .prohibited로 시작한다. 창은
        // 보이지만 앱이 활성화되지 않아 **키 입력이 들어오지 않는다** (프로브로 확인).
        // 한글 IME를 손으로 확인하는 것이 이 실행 타깃의 첫 목적이므로 반드시 필요하다.
        // 제대로 된 .app 번들이 생기면 이 줄은 없어도 된다.
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
