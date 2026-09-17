import XCTest
@testable import Wiret

final class CalendarSelectionTests: XCTestCase {
    private let work = CalendarInfo(id: "work", title: "업무", sourceTitle: "aston@kakaocorp.com")
    private let personal = CalendarInfo(id: "personal", title: "개인", sourceTitle: "aston@gmail.com")
    private let local = CalendarInfo(id: "local", title: "나의 캘린더", sourceTitle: "iCloud")

    private var all: [CalendarInfo] { [work, personal, local] }
    private var googleIDs: Set<String> { ["work", "personal"] }

    func testSelectedCalendarsAreUsed() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: googleIDs, selected: ["work"])

        XCTAssertEqual(resolved, [work])
    }

    func testMultipleSelectionKeepsOriginalOrder() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: googleIDs, selected: ["local", "work"])

        XCTAssertEqual(resolved, [work, local])
    }

    /// 고르지 않았으면 예전 동작(Google 캘린더)을 그대로 유지한다.
    func testEmptySelectionFallsBackToGoogleCalendars() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: googleIDs, selected: [])

        XCTAssertEqual(resolved, [work, personal])
    }

    func testEmptySelectionWithoutGoogleUsesEverything() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: [], selected: [])

        XCTAssertEqual(resolved, all)
    }

    /// 계정을 지우면 저장해 둔 식별자가 남아도 가리키는 캘린더가 없다.
    /// 이때 아무것도 못 보게 두면 자동 녹음이 조용히 멈춘다.
    func testSelectionPointingAtRemovedCalendarsFallsBack() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: googleIDs, selected: ["없어진-캘린더"])

        XCTAssertEqual(resolved, [work, personal])
    }

    func testPartiallyRemovedSelectionKeepsWhatRemains() {
        let resolved = CalendarSelection.resolve(all: all, googleIDs: googleIDs, selected: ["없어진-캘린더", "local"])

        XCTAssertEqual(resolved, [local])
    }

    func testIsAutomaticWhenNothingSelected() {
        XCTAssertTrue(CalendarSelection.isAutomatic(all: all, selected: []))
        XCTAssertTrue(CalendarSelection.isAutomatic(all: all, selected: ["없어진-캘린더"]))
        XCTAssertFalse(CalendarSelection.isAutomatic(all: all, selected: ["work"]))
    }
}
