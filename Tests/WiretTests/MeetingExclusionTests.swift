import XCTest
@testable import Wiret

final class TodayScheduleTests: XCTestCase {
    /// 시간대를 고정하지 않으면 실행 지역에 따라 같은 시각이 다른 날이 된다.
    /// (UTC 러너에서 한국 기준 정오가 전날로 넘어가 테스트가 깨진 적이 있다.)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 하루 한가운데라, 몇 시간을 더하고 빼도 같은 날 안에 머문다.
    private lazy var noon = calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 16, hour: 12)
    )!

    private func meeting(id: String, offsetHours: Double, durationMinutes: Double = 60) -> Meeting {
        let start = noon.addingTimeInterval(offsetHours * 3600)
        return Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(durationMinutes * 60))
    }

    func testKeepsOnlyMeetingsStartingToday() {
        let today = meeting(id: "today", offsetHours: 1)
        let tomorrow = meeting(id: "tomorrow", offsetHours: 30)
        let yesterday = meeting(id: "yesterday", offsetHours: -30)

        let result = TodaySchedule.meetings(in: [tomorrow, today, yesterday], on: noon, calendar: calendar)

        XCTAssertEqual(result, [today])
    }

    func testSortsByStartTime() {
        let later = meeting(id: "later", offsetHours: 3)
        let earlier = meeting(id: "earlier", offsetHours: 1)

        let result = TodaySchedule.meetings(in: [later, earlier], on: noon, calendar: calendar)

        XCTAssertEqual(result.map(\.id), ["earlier", "later"])
    }

    /// 같은 시각에 시작하면 먼저 끝나는 회의를 위에 둔다. 순서가 흔들리면 체크박스도 흔들린다.
    func testSameStartIsOrderedByEnd() {
        let long = meeting(id: "long", offsetHours: 1, durationMinutes: 120)
        let short = meeting(id: "short", offsetHours: 1, durationMinutes: 30)

        let result = TodaySchedule.meetings(in: [long, short], on: noon, calendar: calendar)

        XCTAssertEqual(result.map(\.id), ["short", "long"])
    }

    func testEmptyWhenNothingToday() {
        let tomorrow = meeting(id: "tomorrow", offsetHours: 30)

        XCTAssertTrue(TodaySchedule.meetings(in: [tomorrow], on: noon, calendar: calendar).isEmpty)
    }
}

final class MeetingExclusionStoreTests: XCTestCase {
    private let suiteName = "MeetingExclusionStoreTests"
    private var defaults: UserDefaults!
    private var store: MeetingExclusionStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = MeetingExclusionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    private func meeting(id: String, startOffset: TimeInterval = 0) -> Meeting {
        let start = now.addingTimeInterval(startOffset)
        return Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(3600))
    }

    /// 기본은 모두 포함이다. 새 회의가 생겨도 손대지 않아야 녹음된다.
    func testNothingIsExcludedByDefault() {
        XCTAssertFalse(store.isExcluded(meeting(id: "m1")))
        XCTAssertTrue(store.excludedIDs.isEmpty)
    }

    func testExcludingAndIncludingAgain() {
        let m = meeting(id: "m1")

        store.setExcluded(true, meeting: m)
        XCTAssertTrue(store.isExcluded(m))
        XCTAssertEqual(store.excludedIDs, ["m1"])

        store.setExcluded(false, meeting: m)
        XCTAssertFalse(store.isExcluded(m))
        XCTAssertTrue(store.excludedIDs.isEmpty)
    }

    func testExclusionSurvivesANewStoreOnTheSameDefaults() {
        store.setExcluded(true, meeting: meeting(id: "m1"))

        let reopened = MeetingExclusionStore(defaults: defaults)

        XCTAssertEqual(reopened.excludedIDs, ["m1"])
    }

    /// 반복 일정은 회차마다 식별자가 달라 기록이 계속 쌓인다.
    func testPruneDropsOldExclusions() {
        store.setExcluded(true, meeting: meeting(id: "old", startOffset: -5 * 24 * 3600))
        store.setExcluded(true, meeting: meeting(id: "today", startOffset: 0))

        store.prune(now: now)

        XCTAssertEqual(store.excludedIDs, ["today"])
    }

    /// 시계가 조금 어긋나도 오늘 뺀 회의가 지워지면 안 된다.
    func testPruneKeepsRecentExclusions() {
        store.setExcluded(true, meeting: meeting(id: "yesterday", startOffset: -20 * 3600))

        store.prune(now: now)

        XCTAssertEqual(store.excludedIDs, ["yesterday"])
    }
}
