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

    /// 업데이트 확인처럼 상태가 없는 항목은 체크 칸을 비워 두고, 상태가 있다고 읽히지도 않아야 한다.
    func testCheckmarkIsOffByDefault() {
        let view = MenuActionItemView(title: "업데이트 확인")

        XCTAssertNil(view.isChecked)
        XCTAssertNil(view.accessibilityValue())
        XCTAssertFalse(hasInk(inCheckmarkColumnOf: view))
    }

    func testCheckedViewDrawsCheckmark() {
        let view = MenuActionItemView(title: "09:00–09:30   데일리 스크럼")

        view.isChecked = true

        XCTAssertTrue(hasInk(inCheckmarkColumnOf: view))
        XCTAssertEqual(view.accessibilityValue() as? String, "켜짐")
    }

    /// 꺼진 항목은 체크 칸이 비어 있어야 켜진 항목과 구분된다.
    func testUncheckedViewLeavesCheckmarkColumnEmpty() {
        let view = MenuActionItemView(title: "09:00–09:30   데일리 스크럼")
        view.isChecked = true

        view.isChecked = false

        XCTAssertFalse(hasInk(inCheckmarkColumnOf: view))
        XCTAssertEqual(view.accessibilityValue() as? String, "꺼짐")
        XCTAssertEqual(view.accessibilityRole(), .menuItem)
    }

    /// 뷰를 그려 보고 제목 앞 체크 칸에 찍힌 픽셀이 있는지 본다.
    private func hasInk(inCheckmarkColumnOf view: MenuActionItemView) -> Bool {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("비트맵을 만들지 못했습니다")
            return false
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 비트맵은 화면 배율만큼 커질 수 있으므로 포인트 대신 비율로 체크 칸을 잡는다.
        let columnWidth = Int(Double(bitmap.pixelsWide) * 21 / Double(view.bounds.width))
        for x in 0..<columnWidth {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                    return true
                }
            }
        }
        return false
    }
}
