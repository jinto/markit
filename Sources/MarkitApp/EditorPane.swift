import AppKit
import AppCore
import EditorKit
import SwiftUI

/// 세션이 소유한 `EditorTextView`를 스크롤 뷰에 얹어 SwiftUI에 넘긴다.
///
/// **뷰를 새로 만들지 않는다.** SwiftUI가 표현체를 다시 만들어도 편집 상태(원문, 커서,
/// 언두 스택)가 살아 있어야 하므로 세션이 가진 것을 그대로 쓴다.
struct EditorPane: NSViewRepresentable {

    let textView: EditorTextView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // 스크롤 뷰가 프레임을 주는 순간 컨테이너 폭이 따라오고 줄바꿈이 시작된다.
        // 컨테이너 폭 0은 "무제한"이므로 이 연결이 없으면 문서가 한 줄로 눕는다.
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 세션이 상태를 갖고 있으므로 여기서 할 일이 없다. 뷰를 갈아끼우지 않는다.
    }
}
