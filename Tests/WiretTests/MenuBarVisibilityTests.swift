import XCTest
@testable import Wiret

final class MenuBarVisibilityTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let rightArea = CGRect(x: 1010, y: 1131, width: 790, height: 38)

    func testHiddenOverflow() {
        let itemFrame = CGRect(x: 606, y: 1130, width: 30, height: 39)
        XCTAssertFalse(MenuBarVisibility.isItemVisible(itemFrame: itemFrame, rightArea: rightArea, screenFrame: screenFrame))
    }

    func testVisibleInRightArea() {
        let itemFrame = CGRect(x: 1040, y: 1130, width: 30, height: 39)
        XCTAssertTrue(MenuBarVisibility.isItemVisible(itemFrame: itemFrame, rightArea: rightArea, screenFrame: screenFrame))
    }

    func testNoNotchAlwaysVisibleWhenInsideScreen() {
        let itemFrame = CGRect(x: 606, y: 1130, width: 30, height: 39)
        XCTAssertTrue(MenuBarVisibility.isItemVisible(itemFrame: itemFrame, rightArea: nil, screenFrame: screenFrame))
    }

    func testEmptyFrameIsNeverVisible() {
        let itemFrame = CGRect.zero
        XCTAssertFalse(MenuBarVisibility.isItemVisible(itemFrame: itemFrame, rightArea: rightArea, screenFrame: screenFrame))
    }
}
