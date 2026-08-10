import AppKit
import AppCore
import DocumentCore
import SwiftUI

/// 창 하나. 세션을 소유하고 모드에 따라 패널 구성만 바꾼다.
struct EditorWindow: View {

    @State private var session = EditorSession()
    @State private var mode: DisplayMode = .wysiwyg
    @State private var showsPalette = false
    @State private var conflict: ConflictPrompt?

    var body: some View {
        panes
            .toolbar { ModeSwitcher(mode: $mode) }
            .navigationTitle(title)
            .onChange(of: mode) { session.mode = mode }
            .onAppear(perform: wireExternalChanges)
            .overlay(alignment: .top) { palette }
            .background {
                // 메뉴 없이도 동작하는 단축키. 여기서만 키를 정의한다.
                Button("") { showsPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command).hidden()
                Button("") { openFile() }
                    .keyboardShortcut("o", modifiers: .command).hidden()
                Button("") { saveFile() }
                    .keyboardShortcut("s", modifiers: .command).hidden()
                ForEach(Array(DisplayMode.allCases.enumerated()), id: \.offset) { index, value in
                    Button("") { mode = value }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .hidden()
                }
            }
            .alert(item: $conflict) { prompt in
                Alert(title: Text("파일이 외부에서 변경되었습니다"),
                      message: Text("편집 중인 내용이 있습니다. 어느 쪽을 남길까요?"),
                      primaryButton: .default(Text("디스크 내용 사용")) {
                          session.acceptDiskVersion(prompt.diskText)
                      },
                      secondaryButton: .cancel(Text("내 것 유지")))
            }
    }

    @ViewBuilder
    private var panes: some View {
        if mode == .split {
            HSplitView {
                EditorPane(textView: session.sourceView).frame(minWidth: 280)
                EditorPane(textView: session.previewView).frame(minWidth: 280)
            }
        } else {
            EditorPane(textView: session.sourceView)
        }
    }

    @ViewBuilder
    private var palette: some View {
        if showsPalette {
            CommandPaletteView(
                commands: session.commands,
                onRun: { command in
                    showsPalette = false
                    // 모드 명령은 세션과 뷰의 상태를 함께 맞춰야 한다.
                    session.run(command)
                    mode = session.mode
                },
                onDismiss: { showsPalette = false })
            .padding(.top, 60)
        }
    }

    private var title: String {
        let name = session.document.url?.lastPathComponent ?? "제목 없음"
        return session.isDirty ? "\(name) — 편집됨" : name
    }

    private func wireExternalChanges() {
        session.onExternalChange = { change in
            switch change {
            case .reloaded: break  // 세션이 이미 버퍼를 갈아끼웠다
            case .conflict(let diskText): conflict = ConflictPrompt(diskText: diskText)
            case .fileDisappeared: break
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!,
                                     .init(filenameExtension: "markdown")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.open(url)
    }

    private func saveFile() {
        if session.document.url != nil {
            try? session.save()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "제목 없음.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.save(to: url)
    }
}

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let diskText: String
}
