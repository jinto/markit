import Foundation

public struct CommandMatch: Equatable, Sendable {
    public let command: Command
    public let score: Int
    /// 제목 안에서 매치된 글자들의 **UTF-16 오프셋**. 하이라이트에 쓴다.
    public let matchedOffsets: [Int]
}

/// 부분수열(subsequence) 기반 퍼지 매처. 순수 함수다.
public enum CommandMatcher {

    public static func match(query: String, in commands: [Command]) -> [CommandMatch] {
        let needle = Array(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else {
            return commands.map { CommandMatch(command: $0, score: 0, matchedOffsets: []) }
        }

        let matches = commands.enumerated().compactMap { index, command in
            score(needle, in: command).map { (index, $0) }
        }

        // 동점이면 등록 순서를 지킨다. 안 지키면 같은 질의에 결과 순서가 흔들려 보인다.
        return matches
            .sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }
            .map(\.1)
    }

    /// 글자 단위로 훑는다.
    ///
    /// UTF-16 유닛이 아니라 `Character`(그래핌 클러스터)로 훑는 이유: `🇰🇷`는 UTF-16으로
    /// 4유닛이지만 한 글자다. 유닛 단위로 비교하면 서로게이트 조각과 비교하게 된다.
    /// 대소문자 무시는 제목 전체를 `lowercased()` 하지 않고 글자별로 한다 — 전체를
    /// 소문자화하면 길이가 바뀌는 글자(예: `İ`)가 있어 오프셋이 어긋난다.
    private static func score(_ needle: [Character], in command: Command) -> CommandMatch? {
        var offsets: [Int] = []
        var characterIndices: [Int] = []

        var utf16Offset = 0
        var characterIndex = 0
        var next = 0

        for character in command.title {
            if next < needle.count, equalIgnoringCase(character, needle[next]) {
                offsets.append(utf16Offset)
                characterIndices.append(characterIndex)
                next += 1
            }
            utf16Offset += String(character).utf16.count
            characterIndex += 1
        }

        guard next == needle.count else { return nil }

        var score = 0
        for (i, index) in characterIndices.enumerated() {
            if i == 0 {
                // 앞쪽에서 시작할수록 좋다. 제목 첫 글자면 확실히 좋다.
                score += index == 0 ? 12 : max(0, 8 - index)
            } else if index == characterIndices[i - 1] + 1 {
                // 붙어 있는 매치가 흩어진 매치보다 좋다.
                score += 8
            }
        }
        // 같은 질의를 담은 제목 중에는 짧은 것이 더 정확한 답이다.
        score -= characterIndex - needle.count

        return CommandMatch(command: command, score: score, matchedOffsets: offsets)
    }

    private static func equalIgnoringCase(_ a: Character, _ b: Character) -> Bool {
        a == b || String(a).lowercased() == String(b).lowercased()
    }
}
