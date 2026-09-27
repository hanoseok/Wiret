import AppKit
import XCTest
@testable import Wiret

final class MeetingNotificationWindowControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var meeting: Meeting {
        Meeting(id: "m1", title: "주간 회의", start: now, end: now.addingTimeInterval(3600))
    }

    /// 응답은 비동기로 넘어오므로 한 번 받을 때까지 기다린다.
    private func response(
        for prompt: MeetingNotificationPrompt,
        after action: (MeetingNotificationWindowController) -> Void
    ) -> [MeetingNotificationResponse] {
        let received = expectation(description: "response handler called")
        var responses: [MeetingNotificationResponse] = []
        let controller = MeetingNotificationWindowController(prompt: prompt) { response in
            responses.append(response)
            received.fulfill()
        }

        action(controller)

        wait(for: [received], timeout: 2)
        // 뒤늦게 한 번 더 불리지 않는지도 본다.
        let settled = expectation(description: "pending main-queue work drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        return responses
    }

    func testStartPromptTitles() {
        let controller = MeetingNotificationWindowController(prompt: .start(meeting)) { _ in }

        XCTAssertEqual(controller.window?.title, "회의 시작")
        XCTAssertNil(controller.delayPopUp)
    }

    func testEndPromptTitles() {
        let controller = MeetingNotificationWindowController(prompt: .end(meeting)) { _ in }

        XCTAssertEqual(controller.window?.title, "회의 종료")
        XCTAssertNotNil(controller.delayPopUp)
    }

    func testConfirmStartRespondsStartRecording() {
        let responses = response(for: .start(meeting)) { $0.confirmStart() }

        XCTAssertEqual(responses, [.startRecording])
    }

    func testCancelOnStartPromptRespondsCancel() {
        let responses = response(for: .start(meeting)) { $0.cancel() }

        XCTAssertEqual(responses, [.cancel])
    }

    func testStopNowRespondsStopNow() {
        let responses = response(for: .end(meeting)) { $0.stopNow() }

        XCTAssertEqual(responses, [.stopNow])
    }

    func testStopLaterRespondsWithMinutes() {
        let responses = response(for: .end(meeting)) { $0.stopLater(minutes: 15) }

        XCTAssertEqual(responses, [.stopLater(minutes: 15)])
    }

    func testCancelOnEndPromptRespondsCancel() {
        let responses = response(for: .end(meeting)) { $0.cancel() }

        XCTAssertEqual(responses, [.cancel])
    }

    func testDelayPopUpListsDelayOptions() {
        let controller = MeetingNotificationWindowController(prompt: .end(meeting)) { _ in }

        // 풀다운 메뉴의 첫 항목은 버튼 제목이다.
        XCTAssertEqual(
            controller.delayPopUp?.itemTitles,
            ["몇 분 후 종료", "5분 후", "10분 후", "15분 후", "30분 후"]
        )
        XCTAssertEqual(controller.delayPopUp?.itemArray.dropFirst().map(\.tag), [5, 10, 15, 30])
    }

    func testChoosingDelayFromPopUpRespondsStopLater() {
        let responses = response(for: .end(meeting)) { controller in
            guard let popUp = controller.delayPopUp, let action = popUp.action else {
                return XCTFail("몇 분 후 종료 메뉴가 없습니다")
            }
            popUp.selectItem(at: 2)
            NSApp.sendAction(action, to: popUp.target, from: popUp)
        }

        XCTAssertEqual(responses, [.stopLater(minutes: 10)])
    }

    func testClosingWindowRespondsCancelOnce() {
        let responses = response(for: .end(meeting)) { $0.window?.close() }

        XCTAssertEqual(responses, [.cancel])
    }

    func testRespondingTwiceOnlyReportsFirstAnswer() {
        let responses = response(for: .start(meeting)) { controller in
            controller.confirmStart()
            controller.cancel()
        }

        XCTAssertEqual(responses, [.startRecording])
    }

    func testDismissInvokesNoHandler() {
        var count = 0
        let controller = MeetingNotificationWindowController(prompt: .start(meeting)) { _ in count += 1 }

        controller.dismiss()

        let settled = expectation(description: "pending main-queue work drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(count, 0)
    }
}
