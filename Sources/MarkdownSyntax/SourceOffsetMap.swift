import Foundation

/// swift-markdown의 `SourceLocation` 좌표를 UTF-16 오프셋으로 환산한다.
///
/// swift-markdown은 위치를 **1-based 줄 번호 + 1-based UTF-8 바이트 열**로 준다.
/// 반면 `NSTextStorage`/`NSRange`는 UTF-16 코드 유닛으로 동작한다. 이 두 좌표계를
/// 섞으면 ASCII 문서에서는 우연히 맞고 한글·이모지 문서에서 조용히 깨진다.
/// 그 변환 지식을 이 타입 하나에 격리해 둔다.
public struct SourceOffsetMap {

    /// 각 줄의 시작 위치. 줄 번호(1-based)에서 1을 뺀 값이 인덱스다.
    private let lineStarts: [String.Index]
    /// 각 줄 시작의 문서 기준 UTF-16 오프셋.
    private let lineStartUTF16: [Int]
    private let source: String

    public init(source: String) {
        self.source = source

        var starts: [String.Index] = [source.startIndex]
        var startsUTF16: [Int] = [0]

        // 줄 나누기를 직접 한다. `split`이나 `components`는 CRLF와 마지막 빈 줄을
        // 우리가 원하는 방식으로 다루지 않는다. swift-markdown은 \n만 줄 구분자로
        // 세므로 \r은 줄 내용의 일부로 남겨 둔다 (CRLF 테스트가 이를 고정한다).
        var utf16Count = 0
        var i = source.startIndex
        while i < source.endIndex {
            let scalar = source.unicodeScalars[i]
            let next = source.unicodeScalars.index(after: i)
            utf16Count += UTF16.width(scalar)
            if scalar == "\n" {
                starts.append(next)
                startsUTF16.append(utf16Count)
            }
            i = next
        }

        self.lineStarts = starts
        self.lineStartUTF16 = startsUTF16
    }

    /// 1-based 줄 번호와 1-based UTF-8 바이트 열을 문서 기준 UTF-16 오프셋으로 바꾼다.
    ///
    /// 범위를 벗어나거나, 열이 유니코드 스칼라 중간을 가리키면 `nil`을 낸다.
    /// 스칼라 경계까지만 요구하고 그래핌 경계는 요구하지 않는다 — 결합 문자열
    /// (예: "e" + U+0301) 안쪽을 가리키는 정당한 위치를 버리지 않기 위해서다.
    public func utf16Offset(line: Int, utf8Column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, utf8Column >= 1 else { return nil }

        let lineStart = lineStarts[line - 1]

        // 줄 시작에서 UTF-8 바이트 단위로 전진한다.
        guard let target = source.utf8.index(
            lineStart, offsetBy: utf8Column - 1, limitedBy: source.utf8.endIndex
        ) else { return nil }

        // 스칼라 경계가 아니면 nil. 여기가 방어선이다.
        guard let targetUTF16 = target.samePosition(in: source.utf16),
              let lineStartUTF16Index = lineStart.samePosition(in: source.utf16)
        else { return nil }

        // 다음 줄 시작을 넘어갔으면 그 열은 이 줄에 없다.
        if line < lineStarts.count, target > lineStarts[line] { return nil }

        return lineStartUTF16[line - 1]
            + source.utf16.distance(from: lineStartUTF16Index, to: targetUTF16)
    }
}
