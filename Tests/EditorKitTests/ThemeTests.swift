import XCTest
import AppKit
@testable import EditorKit

final class ThemeTests: XCTestCase {

    func testHeadingFontsDecreaseByLevel() {
        let theme = Theme.default
        let sizes = (1...6).map { theme.headingFont(level: $0).pointSize }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "레벨이 깊어질수록 작아져야 한다")
        XCTAssertGreaterThan(sizes[5], theme.bodyFont.pointSize,
                             "h6도 본문보다는 커야 한다")
    }

    func testHeadingFontIsBold() {
        let f = Theme.default.headingFont(level: 1)
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testHeadingLevelIsClampedNotCrashing() {
        // 파서가 1...6만 낸다고 믿지 않는다. 방어적으로 고정한다.
        XCTAssertEqual(Theme.default.headingFont(level: 0).pointSize,
                       Theme.default.headingFont(level: 1).pointSize)
        XCTAssertEqual(Theme.default.headingFont(level: 99).pointSize,
                       Theme.default.headingFont(level: 6).pointSize)
    }

    func testMonoFontIsFixedPitch() {
        XCTAssertTrue(Theme.default.monoFont.isFixedPitch)
    }
}
