import XCTest
@testable import Wiret

final class CalendarServiceTests: XCTestCase {
    func testGoogleTitleIsGoogleSource() {
        XCTAssertTrue(EventKitMeetingSource.isGoogleSource(title: "Google", isCalDAV: false))
    }

    func testCalDAVAccountAddressIsGoogleSource() {
        XCTAssertTrue(EventKitMeetingSource.isGoogleSource(title: "aston.han@kakaocorp.com", isCalDAV: true))
    }

    func testICloudIsNotGoogleSource() {
        XCTAssertFalse(EventKitMeetingSource.isGoogleSource(title: "iCloud", isCalDAV: false))
    }

    func testNonCalDAVExchangeWithAtSignIsNotGoogleSource() {
        XCTAssertFalse(EventKitMeetingSource.isGoogleSource(title: "Exchange aston@kakaocorp.com", isCalDAV: false))
    }
}
