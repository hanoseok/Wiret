import XCTest
@testable import Wiret

final class AutoRecordPolicyTests: XCTestCase {
    private let meeting = Meeting(id: "m1", title: "Standup", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800))
    private let otherMeeting = Meeting(id: "m2", title: "Sync", start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 3000))

    func testDisabledWhileAutoRecordingStops() {
        let state = AutoRecordState(autoEnabled: false, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .stop)
    }

    func testDisabledWhileIdleDoesNothing() {
        let state = AutoRecordState(autoEnabled: false, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testDisabledWhileManuallyRecordingDoesNothing() {
        let state = AutoRecordState(autoEnabled: false, isRecording: true, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testIdleWithCurrentMeetingStarts() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .start(meeting))
    }

    func testIdleWithNoCurrentMeetingDoesNothing() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testIdleWithCurrentAlreadyFinishedDoesNotRestart() {
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [meeting.id])
        XCTAssertEqual(action, .none)
    }

    func testManualRecordingNeverInterfered() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testAutoRecordingSameMeetingContinues() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testAutoRecordingWithNoCurrentMeetingStops() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [], finishedMeetingIds: [])
        XCTAssertEqual(action, .stop)
    }

    func testAutoRecordingWithDifferentCurrentMeetingStops() {
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [otherMeeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .stop)
    }

    func testIdleWithTwoOverlappingCandidatesAsksForChoice() {
        let overlapping = Meeting(id: "m3", title: "Overlap", start: Date(timeIntervalSince1970: 600), end: Date(timeIntervalSince1970: 2400))
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [overlapping, meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .choose([overlapping, meeting]))
    }

    func testIdleWithOneOfTwoAlreadyFinishedStartsTheOther() {
        let overlapping = Meeting(id: "m3", title: "Overlap", start: Date(timeIntervalSince1970: 600), end: Date(timeIntervalSince1970: 2400))
        let state = AutoRecordState(autoEnabled: true, isRecording: false, autoMeetingId: nil)
        let action = AutoRecordPolicy.decide(state: state, current: [overlapping, meeting], finishedMeetingIds: [overlapping.id])
        XCTAssertEqual(action, .start(meeting))
    }

    func testOverlappingMeetingStartingDoesNotStopRunningAutoRecording() {
        let overlapping = Meeting(id: "m3", title: "Overlap", start: Date(timeIntervalSince1970: 600), end: Date(timeIntervalSince1970: 2400))
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [overlapping, meeting], finishedMeetingIds: [])
        XCTAssertEqual(action, .none)
    }

    func testAutoRecordingStopsWhenItsMeetingEndsWhileOverlapContinues() {
        let overlapping = Meeting(id: "m3", title: "Overlap", start: Date(timeIntervalSince1970: 600), end: Date(timeIntervalSince1970: 2400))
        let state = AutoRecordState(autoEnabled: true, isRecording: true, autoMeetingId: meeting.id)
        let action = AutoRecordPolicy.decide(state: state, current: [overlapping], finishedMeetingIds: [])
        XCTAssertEqual(action, .stop)
    }
}
