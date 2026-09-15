import AppKit
import XCTest
@testable import Wiret

final class MeetingChoiceWindowControllerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeMeetings() -> [Meeting] {
        [
            Meeting(id: "A", title: "Meeting A", start: now, end: now.addingTimeInterval(3600)),
            Meeting(id: "B", title: "Meeting B", start: now, end: now.addingTimeInterval(1800))
        ]
    }

    func testClosingWindowInvokesSkipHandlerOnce() {
        let skipped = expectation(description: "skip handler called")
        var skipCount = 0
        var chooseCount = 0
        let controller = MeetingChoiceWindowController(
            meetings: makeMeetings(),
            onChoose: { _ in chooseCount += 1 },
            onSkip: {
                skipCount += 1
                skipped.fulfill()
            }
        )

        controller.window?.close()

        wait(for: [skipped], timeout: 2)
        XCTAssertEqual(skipCount, 1)
        XCTAssertEqual(chooseCount, 0)
    }

    func testConfirmSelectionInvokesChooseHandlerWithSelectedMeeting() {
        let meetings = makeMeetings()
        let chosen = expectation(description: "choose handler called")
        var chosenMeetings: [Meeting] = []
        var skipCount = 0
        let controller = MeetingChoiceWindowController(
            meetings: meetings,
            onChoose: { meeting in
                chosenMeetings.append(meeting)
                chosen.fulfill()
            },
            onSkip: { skipCount += 1 }
        )

        controller.confirmSelection()

        wait(for: [chosen], timeout: 2)
        XCTAssertEqual(chosenMeetings, [meetings[0]])
        XCTAssertEqual(skipCount, 0)
    }

    func testDismissInvokesNoHandler() {
        var skipCount = 0
        var chooseCount = 0
        let controller = MeetingChoiceWindowController(
            meetings: makeMeetings(),
            onChoose: { _ in chooseCount += 1 },
            onSkip: { skipCount += 1 }
        )

        controller.dismiss()

        let settled = expectation(description: "pending main-queue work drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(skipCount, 0)
        XCTAssertEqual(chooseCount, 0)
    }
}
