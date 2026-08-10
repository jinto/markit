import AppCore
import SwiftUI

struct ModeSwitcher: View {

    @Binding var mode: DisplayMode

    var body: some View {
        Picker("모드", selection: $mode) {
            Text("WYSIWYG").tag(DisplayMode.wysiwyg)
            Text("소스").tag(DisplayMode.source)
            Text("분할").tag(DisplayMode.split)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
    }
}
