import XCTest
@testable import Wiret

final class MeetingScheduleTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 5
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    func testCurrentPicksInProgressMeeting() {
        let meeting = Meeting(id: "a", title: "Standup", start: date(9), end: date(10))
        let now = date(9, 30)
        XCTAssertEqual(MeetingSchedule.current(in: [meeting], at: now), meeting)
    }

    func testCurrentReturnsNilBetweenMeetings() {
        let first = Meeting(id: "a", title: "A", start: date(9), end: date(10))
        let second = Meeting(id: "b", title: "B", start: date(11), end: date(12))
        let now = date(10, 30)
        XCTAssertNil(MeetingSchedule.current(in: [first, second], at: now))
    }

    func testCurrentPicksLatestStartOnOverlap() {
        let earlier = Meeting(id: "a", title: "A", start: date(9), end: date(11))
        let later = Meeting(id: "b", title: "B", start: date(10), end: date(11, 30))
        let now = date(10, 15)
        XCTAssertEqual(MeetingSchedule.current(in: [earlier, later], at: now), later)
    }

    func testCurrentTieBreaksOnEarliestEnd() {
        let sameStartLongEnd = Meeting(id: "a", title: "A", start: date(9), end: date(11))
        let sameStartShortEnd = Meeting(id: "b", title: "B", start: date(9), end: date(10))
        let now = date(9, 30)
        XCTAssertEqual(MeetingSchedule.current(in: [sameStartLongEnd, sameStartShortEnd], at: now), sameStartShortEnd)
    }

    func testCurrentAllReturnsBothOverlappingMeetingsLatestStartFirst() {
        let earlier = Meeting(id: "a", title: "A", start: date(9), end: date(11))
        let later = Meeting(id: "b", title: "B", start: date(10), end: date(11, 30))
        let now = date(10, 15)
        XCTAssertEqual(MeetingSchedule.currentAll(in: [earlier, later], at: now), [later, earlier])
    }

    func testCurrentAllTieBreaksOnEarliestEnd() {
        let longEnd = Meeting(id: "a", title: "A", start: date(9), end: date(11))
        let shortEnd = Meeting(id: "b", title: "B", start: date(9), end: date(10))
        let now = date(9, 30)
        XCTAssertEqual(MeetingSchedule.currentAll(in: [longEnd, shortEnd], at: now), [shortEnd, longEnd])
    }

    func testCurrentAllExcludesMeetingsNotInProgress() {
        let past = Meeting(id: "a", title: "A", start: date(8), end: date(9))
        let running = Meeting(id: "b", title: "B", start: date(9), end: date(11))
        let future = Meeting(id: "c", title: "C", start: date(12), end: date(13))
        XCTAssertEqual(MeetingSchedule.currentAll(in: [past, running, future], at: date(10)), [running])
    }

    func testNextReturnsEarliestFutureMeeting() {
        let far = Meeting(id: "a", title: "A", start: date(14), end: date(15))
        let near = Meeting(id: "b", title: "B", start: date(11), end: date(12))
        let now = date(10)
        XCTAssertEqual(MeetingSchedule.next(in: [far, near], after: now), near)
    }

    func testNextReturnsNilWhenNoFutureMeetings() {
        let past = Meeting(id: "a", title: "A", start: date(9), end: date(10))
        XCTAssertNil(MeetingSchedule.next(in: [past], after: date(11)))
    }

    func testSanitizedTitleStripsInvalidCharactersAndCollapsesWhitespace() {
        let raw = "  Q1/Q2: Review \\ Plan? 100%*sync|\"quoted\"<tag>  "
        let sanitized = RecordingFileNamer.sanitizedTitle(raw)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("\\"))
        XCTAssertFalse(sanitized.contains("?"))
        XCTAssertFalse(sanitized.contains("%"))
        XCTAssertFalse(sanitized.contains("*"))
        XCTAssertFalse(sanitized.contains("|"))
        XCTAssertFalse(sanitized.contains("\""))
        XCTAssertFalse(sanitized.contains("<"))
        XCTAssertFalse(sanitized.contains(">"))
        XCTAssertFalse(sanitized.hasPrefix(" "))
        XCTAssertFalse(sanitized.hasSuffix(" "))
        XCTAssertFalse(sanitized.contains("  "))
    }

    func testSanitizedTitleCapsAt60Characters() {
        let raw = String(repeating: "a", count: 100)
        let sanitized = RecordingFileNamer.sanitizedTitle(raw)
        XCTAssertEqual(sanitized.count, 60)
    }

    func testFileURLWithTitleHasSuffix() {
        let recordedDate = date(9, 7)
        let directory = URL(fileURLWithPath: "/tmp/WiretTestDir")
        let url = RecordingFileNamer.fileURL(in: directory, date: recordedDate, title: "Weekly Sync")
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-Weekly Sync.m4a"))
    }

    func testFileURLWithoutTitleUnchangedFormat() {
        let recordedDate = date(9, 7)
        let directory = URL(fileURLWithPath: "/tmp/WiretTestDir")
        let url = RecordingFileNamer.fileURL(in: directory, date: recordedDate)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let expectedTimestamp = formatter.string(from: recordedDate)
        XCTAssertEqual(url.lastPathComponent, "Wiret-\(expectedTimestamp).m4a")
    }
}
