import AppCore
import SwiftUI

/// ⌘K 오버레이. 매칭과 순위는 `CommandMatcher`가 하고 여기서는 그리기만 한다.
struct CommandPaletteView: View {

    let commands: [Command]
    let onRun: (Command) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [CommandMatch] {
        CommandMatcher.match(query: query, in: commands)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("명령 검색", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(14)
                .focused($focused)
                .onSubmit(runSelected)
                .onChange(of: query) { selection = 0 }

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.command.id) { index, match in
                        row(match, isSelected: index == selection)
                            .onTapGesture { onRun(match.command) }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 460)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { focused = true }
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private func row(_ match: CommandMatch, isSelected: Bool) -> some View {
        HStack {
            highlighted(match)
            Spacer()
            if let shortcut = match.command.shortcut {
                Text(shortcut).foregroundStyle(.tertiary).monospaced()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    /// 매치된 글자를 굵게. 오프셋은 `CommandMatcher`가 UTF-16으로 준다.
    private func highlighted(_ match: CommandMatch) -> Text {
        let title = match.command.title as NSString
        let matched = Set(match.matchedOffsets)
        var result = Text("")
        for offset in 0..<title.length {
            let piece = Text(title.substring(with: NSRange(location: offset, length: 1)))
            result = result + (matched.contains(offset)
                               ? piece.bold().foregroundColor(.accentColor)
                               : piece)
        }
        return result
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        selection = max(0, min(matches.count - 1, selection + delta))
        return .handled
    }

    private func runSelected() {
        guard matches.indices.contains(selection) else { return }
        onRun(matches[selection].command)
    }
}
