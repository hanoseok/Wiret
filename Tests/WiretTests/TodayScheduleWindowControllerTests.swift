import AppKit
import XCTest
@testable import Wiret

final class TodayScheduleWindowControllerTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)
    private var toggles: [(meeting: Meeting, excluded: Bool)] = []
    private var excludedIDs: Set<String> = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        toggles = []
        excludedIDs = []
    }

    private func meeting(id: String, offsetHours: Double = 1) -> Meeting {
        let start = noon.addingTimeInterval(offsetHours * 3600)
        return Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(3600))
    }

    private func makeController(_ meetings: [Meeting]) -> TodayScheduleWindowController {
        TodayScheduleWindowController(
            meetings: meetings,
            date: noon,
            isExcluded: { [weak self] in self?.excludedIDs.contains($0.id) ?? false },
            onToggle: { [weak self] meeting, excluded in
                self?.toggles.append((meeting, excluded))
            }
        )
    }

    /// 기본은 모두 포함이므로 체크가 전부 켜져 있어야 한다.
    func testEveryMeetingStartsChecked() {
        let controller = makeController([meeting(id: "m1"), meeting(id: "m2", offsetHours: 3)])

        XCTAssertEqual(controller.checkboxes.count, 2)
        XCTAssertTrue(controller.checkboxes.allSatisfy { $0.state == .on })
    }

    func testAlreadyExcludedMeetingStartsUnchecked() {
        excludedIDs = ["m1"]

        let controller = makeController([meeting(id: "m1"), meeting(id: "m2", offsetHours: 3)])

        XCTAssertEqual(controller.checkboxes[0].state, .off)
        XCTAssertEqual(controller.checkboxes[1].state, .on)
    }

    /// 체크를 끄는 것이 곧 자동 녹음에서 빼는 것이다.
    func testUncheckingReportsExclusion() {
        let controller = makeController([meeting(id: "m1")])

        controller.toggleCheckbox(at: 0)

        XCTAssertEqual(toggles.count, 1)
        XCTAssertEqual(toggles[0].meeting.id, "m1")
        XCTAssertTrue(toggles[0].excluded)
    }

    func testRecheckingReportsInclusion() {
        excludedIDs = ["m1"]
        let controller = makeController([meeting(id: "m1")])

        controller.toggleCheckbox(at: 0)

        XCTAssertEqual(toggles.count, 1)
        XCTAssertFalse(toggles[0].excluded)
    }

    /// 체크박스와 회의가 어긋나면 엉뚱한 회의가 빠진다.
    func testTogglingReportsTheMatchingMeeting() {
        let controller = makeController([
            meeting(id: "m1"),
            meeting(id: "m2", offsetHours: 3),
            meeting(id: "m3", offsetHours: 5)
        ])

        controller.toggleCheckbox(at: 2)

        XCTAssertEqual(toggles.last?.meeting.id, "m3")
    }

    func testTitleShowsMeetingTimeRange() {
        let controller = makeController([meeting(id: "주간 회의")])

        let title = controller.checkboxes[0].title
        XCTAssertTrue(title.contains("–"), "시간 범위가 없습니다: \(title)")
        XCTAssertTrue(title.contains("주간 회의"), "회의 제목이 없습니다: \(title)")
    }

    func testEmptyScheduleHasNoCheckboxes() {
        let controller = makeController([])

        XCTAssertTrue(controller.checkboxes.isEmpty)
        XCTAssertNotNil(controller.window)
    }

    /// 창이 실제로 그려지는지 본다. 체크박스 배열만 확인하면 목록이 안 보이는 레이아웃 오류를 놓친다.
    func testWindowRendersTheMeetingList() throws {
        let controller = makeController([meeting(id: "m1"), meeting(id: "m2", offsetHours: 3)])
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()

        // 체크박스가 창 안쪽에 실제 크기로 자리 잡아야 한다.
        for checkbox in controller.checkboxes {
            let frame = checkbox.convert(checkbox.bounds, to: view)
            XCTAssertGreaterThan(frame.width, 0, "체크박스 너비가 0입니다")
            XCTAssertGreaterThan(frame.height, 0, "체크박스 높이가 0입니다")
            XCTAssertTrue(view.bounds.intersects(frame), "체크박스가 창 밖에 있습니다: \(frame)")
        }
    }
}
