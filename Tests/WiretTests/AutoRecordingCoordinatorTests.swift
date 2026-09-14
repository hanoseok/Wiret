import XCTest
@testable import Wiret

private final class FakeMeetingSource: MeetingSource {
    var onChange: (() -> Void)?
    var meetingsToReturn: [Meeting] = []
    var accessGranted = true

    func requestAccess(completion: @escaping (Bool) -> Void) {
        completion(accessGranted)
    }

    func meetings(from: Date, to: Date) -> [Meeting] {
        meetingsToReturn
    }
}

final class AutoRecordingCoordinatorTests: XCTestCase {
    private let suiteName = "AutoRecordingCoordinatorTests"
    private var defaults: UserDefaults!
    private var source: FakeMeetingSource!
    private var currentDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        source = FakeMeetingSource()
        currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        source = nil
        super.tearDown()
    }

    private func makeCoordinator() -> AutoRecordingCoordinator {
        AutoRecordingCoordinator(source: source, defaults: defaults, now: { [weak self] in self?.currentDate ?? Date() })
    }

    func testEnablingWithAccessStartsInProgressMeeting() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startedMeeting: Meeting?
        coordinator.onStart = { meeting in
            startedMeeting = meeting
            isRecording = true
        }
        var statusText = ""
        coordinator.onStatusText = { statusText = $0 }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)

        XCTAssertEqual(startedMeeting, meeting)
        XCTAssertEqual(coordinator.autoMeetingId, meeting.id)
        XCTAssertTrue(statusText.contains("Weekly Sync"))
    }

    func testAdvancingPastEndStopsRecordingAndClearsAutoMeetingId() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        coordinator.onStart = { _ in isRecording = true }
        var stopCalled = false
        coordinator.onStop = {
            stopCalled = true
            isRecording = false
        }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)
        XCTAssertTrue(isRecording)

        currentDate = meeting.end.addingTimeInterval(60)
        coordinator.tick()

        XCTAssertTrue(stopCalled)
        XCTAssertNil(coordinator.autoMeetingId)
        XCTAssertFalse(isRecording)
    }

    func testManualStopPreventsRestartDuringSameMeeting() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startCount = 0
        coordinator.onStart = { _ in
            startCount += 1
            isRecording = true
        }
        coordinator.onStop = { isRecording = false }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)
        XCTAssertEqual(startCount, 1)

        coordinator.noteManualStop()
        isRecording = false

        coordinator.tick()

        XCTAssertEqual(startCount, 1)
        XCTAssertNil(coordinator.autoMeetingId)
    }

    func testEnablingWithDeniedAccessRevertsAndNotifies() {
        source.accessGranted = false
        let coordinator = makeCoordinator()
        var deniedCalled = false
        coordinator.onAccessDenied = { deniedCalled = true }
        var statusText = ""
        coordinator.onStatusText = { statusText = $0 }

        coordinator.setEnabled(true)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(deniedCalled)
        XCTAssertEqual(statusText, "캘린더 권한 필요")
    }

    func testDisabledShowsOffStatus() {
        let coordinator = makeCoordinator()
        var statusText = ""
        coordinator.onStatusText = { statusText = $0 }

        coordinator.start()

        XCTAssertEqual(statusText, "자동: 꺼짐")
    }

    func testBackToBackMeetingsStopThenStartWithinSameTick() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var callOrder: [String] = []
        coordinator.onStart = { meeting in
            callOrder.append("start:\(meeting.id)")
            isRecording = true
        }
        coordinator.onStop = {
            callOrder.append("stop")
            isRecording = false
        }

        let meetingA = Meeting(
            id: "A",
            title: "Meeting A",
            start: currentDate,
            end: currentDate.addingTimeInterval(3600)
        )
        let meetingB = Meeting(
            id: "B",
            title: "Meeting B",
            start: currentDate.addingTimeInterval(3600),
            end: currentDate.addingTimeInterval(7200)
        )
        source.meetingsToReturn = [meetingA, meetingB]

        currentDate = meetingA.start.addingTimeInterval(1800)
        coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.autoMeetingId, meetingA.id)
        callOrder.removeAll()

        currentDate = meetingB.start.addingTimeInterval(5)
        coordinator.tick()

        XCTAssertEqual(callOrder, ["stop", "start:\(meetingB.id)"])
        XCTAssertEqual(coordinator.autoMeetingId, meetingB.id)
    }

    func testReEnablingMidMeetingResumesAutoRecording() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startCount = 0
        var stopCount = 0
        coordinator.onStart = { _ in
            startCount += 1
            isRecording = true
        }
        coordinator.onStop = {
            stopCount += 1
            isRecording = false
        }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)
        XCTAssertEqual(startCount, 1)

        coordinator.setEnabled(false)
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(coordinator.autoMeetingId)

        coordinator.setEnabled(true)

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(coordinator.autoMeetingId, meeting.id)
    }

    func testStartInFlightProviderSuppressesStartUntilCleared() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        var startCount = 0
        coordinator.onStart = { _ in startCount += 1 }
        var startInFlight = true
        coordinator.isStartInFlightProvider = { startInFlight }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(coordinator.autoMeetingId)

        startInFlight = false
        coordinator.tick()

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(coordinator.autoMeetingId, meeting.id)
    }

    func testNoteAutoStartFailedPreventsRestartDuringSameMeeting() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startCount = 0
        coordinator.onStart = { _ in
            startCount += 1
            isRecording = true
        }
        coordinator.onStop = { isRecording = false }

        let meeting = Meeting(
            id: "m1",
            title: "Weekly Sync",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        source.meetingsToReturn = [meeting]

        coordinator.setEnabled(true)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(coordinator.autoMeetingId, meeting.id)

        isRecording = false
        coordinator.noteAutoStartFailed()
        XCTAssertNil(coordinator.autoMeetingId)

        coordinator.tick()

        XCTAssertEqual(startCount, 1)
        XCTAssertNil(coordinator.autoMeetingId)
    }
}
