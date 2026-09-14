import XCTest
@testable import Wiret

final class RecordingStateTests: XCTestCase {
    func testIdleMenuAvailability() {
        let availability = RecordingState.idle.menuAvailability
        XCTAssertEqual(availability, MenuAvailability(canStart: true, canStop: false))
    }

    func testRecordingMenuAvailability() {
        let availability = RecordingState.recording.menuAvailability
        XCTAssertEqual(availability, MenuAvailability(canStart: false, canStop: true))
    }

    func testFileNamerProducesExpectedName() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 5
        components.hour = 9
        components.minute = 7
        components.second = 3

        let calendar = Calendar.current
        let date = calendar.date(from: components)!

        let directory = URL(fileURLWithPath: "/tmp/WiretTestDir")
        let url = RecordingFileNamer.fileURL(in: directory, date: date)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let expectedTimestamp = formatter.string(from: date)
        let expectedName = "Wiret-\(expectedTimestamp).m4a"

        XCTAssertEqual(url.lastPathComponent, expectedName)
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    }

    func testSanitizedTitleCollapsesRunsOfIllegalCharacters() {
        XCTAssertEqual(RecordingFileNamer.sanitizedTitle("a///b"), "a-b")
    }

    func testSanitizedTitleOfOnlyIllegalCharactersIsEmpty() {
        let sanitized = RecordingFileNamer.sanitizedTitle(":::")
        XCTAssertEqual(sanitized, "")

        let directory = URL(fileURLWithPath: "/tmp/WiretTestDir")
        let date = Date(timeIntervalSince1970: 0)
        let url = RecordingFileNamer.fileURL(in: directory, date: date, title: ":::")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let expectedTimestamp = formatter.string(from: date)
        XCTAssertEqual(url.lastPathComponent, "Wiret-\(expectedTimestamp).m4a")
    }

    func testSanitizedTitlePreservesEmoji() {
        XCTAssertEqual(RecordingFileNamer.sanitizedTitle("🎉 Party Time"), "🎉 Party Time")
    }

    func testSanitizedTitleCapsAt60Characters() {
        let longTitle = String(repeating: "a", count: 100)
        let sanitized = RecordingFileNamer.sanitizedTitle(longTitle)
        XCTAssertEqual(sanitized.count, 60)
        XCTAssertEqual(sanitized, String(repeating: "a", count: 60))
    }
}
