import XCTest
@testable import Wiret

final class AutoRecordPolicyTests: XCTestCase {
    private let meeting = Meeting(id: "m1", title: "Standup", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800))
    private let otherMeeting = Meeting(id: "m2", title: "Sync", start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 3000))

    func testDisabledWhileAutoRecordingStops() {
        let state = AutoRecordState(autoEnabled: false, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .stop)
    }

    func testDisabledWhileIdleDoesNothing() {
        let state = AutoRecordState(autoEnabled: false, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .none)
    }

    func testDisabledWhileManuallyRecordingDoesNothing() {
        let state = AutoRecordState(autoEnabled: false, isRecording: true, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .none)
    }

    func testIdleWithCurrentMeetingStarts() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .start(meeting))
    }

    func testIdleWithNoCurrentMeetingDoesNothing() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: nil, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .none)
    }

    func testIdleWithCurrentEqualToLastFinishedDoesNotRestart() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: meeting.id)
        XCTAssertEqual(action, .none)
    }

    func testManualRecordingNeverInterfered() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .none)
    }

    func testAutoRecordingSameMeetingContinues() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: meeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .none)
    }

    func testAutoRecordingWithNoCurrentMeetingStops() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: nil, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .stop)
    }

    func testAutoRecordingWithDifferentCurrentMeetingStops() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: otherMeeting, lastFinishedAutoMeetingId: nil)
        XCTAssertEqual(action, .stop)
    }
}
