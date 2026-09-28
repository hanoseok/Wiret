import AppKit
import XCTest
@testable import Wiret

final class MenuActionItemViewTests: XCTestCase {
    func testClickCallsOnClick() {
        let view = MenuActionItemView(title: "업데이트 확인")
        var clicks = 0
        view.onClick = { clicks += 1 }

        view.performClick()

        XCTAssertEqual(clicks, 1)
    }

    /// 확인 중처럼 비활성화된 동안 누르면 같은 일이 겹친다.
    func testDisabledViewIgnoresClick() {
        let view = MenuActionItemView(title: "업데이트 확인 중…")
        var clicks = 0
        view.onClick = { clicks += 1 }
        view.isEnabled = false

        view.performClick()

        XCTAssertEqual(clicks, 0)
    }

    /// 메뉴 폭을 따라 늘어나야 강조가 메뉴 끝까지 닿는다.
    func testViewStretchesWithMenuWidth() {
        let view = MenuActionItemView(title: "업데이트 확인")

        XCTAssertTrue(view.autoresizingMask.contains(.width))
        XCTAssertEqual(view.frame.height, 22)
    }

    /// 글자가 잘리지 않도록 긴 문구로 바뀌면 필요한 폭도 늘어난다.
    func testLongerTitleWidensView() {
        let view = MenuActionItemView(title: "확인")
        let shortWidth = view.frame.width

        view.title = "업데이트 확인 실패 · 다시 시도"

        XCTAssertGreaterThan(view.frame.width, shortWidth)
        XCTAssertEqual(view.accessibilityLabel(), "업데이트 확인 실패 · 다시 시도")
    }
}
