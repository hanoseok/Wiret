import XCTest
@testable import Wiret

private final class FakeMeetingSource: MeetingSource {
    var onChange: (() -> Void)?
    var meetingsToReturn: [Meeting] = []
    var accessGranted = true
    /// When true, `requestAccess` stores the completion until `completePendingAccess(granted:)` runs it.
    var deferAccess = false
    private var pendingAccessCompletion: ((Bool) -> Void)?

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if deferAccess {
            pendingAccessCompletion = completion
            return
        }
        completion(accessGranted)
    }

    func completePendingAccess(granted: Bool) {
        let completion = pendingAccessCompletion
        pendingAccessCompletion = nil
        completion?(granted)
    }

    func meetings(from: Date, to: Date) -> [Meeting] {
        meetingsToReturn
    }

    var availableCalendars: [CalendarInfo] = []
    var selectedCalendarIDs: Set<String> = []
}

private final class FakeSleepPreventer: SleepPreventing {
    private(set) var isActive = false
    private(set) var activateCount = 0
    private(set) var releaseCount = 0
    private(set) var lastReason: String?

    func activate(reason: String) {
        lastReason = reason
        if isActive { return }
        isActive = true
        activateCount += 1
    }

    func release() {
        if !isActive { return }
        isActive = false
        releaseCount += 1
    }
}

final class AutoRecordingCoordinatorTests: XCTestCase {
    private let suiteName = "AutoRecordingCoordinatorTests"
    private var defaults: UserDefaults!
    private var source: FakeMeetingSource!
    private var sleepPreventer: FakeSleepPreventer!
    private var currentDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        source = FakeMeetingSource()
        sleepPreventer = FakeSleepPreventer()
        currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        source = nil
        sleepPreventer = nil
        super.tearDown()
    }

    private func makeCoordinator() -> AutoRecordingCoordinator {
        AutoRecordingCoordinator(
            source: source,
            defaults: defaults,
            now: { [weak self] in self?.currentDate ?? Date() },
            sleepPreventer: sleepPreventer
        )
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

    // MARK: - Overlapping meetings

    private func makeOverlappingMeetings() -> (Meeting, Meeting) {
        let meetingA = Meeting(
            id: "A",
            title: "Meeting A",
            start: currentDate.addingTimeInterval(-600),
            end: currentDate.addingTimeInterval(3600)
        )
        let meetingB = Meeting(
            id: "B",
            title: "Meeting B",
            start: currentDate.addingTimeInterval(-60),
            end: currentDate.addingTimeInterval(600)
        )
        return (meetingA, meetingB)
    }

    func testOverlappingMeetingsPromptOnceThenChosenMeetingRecords() {
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
        var chooseCalls: [[Meeting]] = []
        coordinator.onChoose = { chooseCalls.append($0) }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)

        XCTAssertEqual(chooseCalls.count, 1)
        XCTAssertEqual(Set(chooseCalls[0].map { $0.id }), ["A", "B"])
        XCTAssertTrue(callOrder.isEmpty)
        XCTAssertNil(coordinator.autoMeetingId)

        coordinator.tick()
        XCTAssertEqual(chooseCalls.count, 1)

        coordinator.choose(meetingB)
        XCTAssertEqual(callOrder, ["start:B"])
        XCTAssertEqual(coordinator.autoMeetingId, meetingB.id)
        XCTAssertNil(coordinator.pendingChoiceIds)

        currentDate = meetingB.end.addingTimeInterval(5)
        coordinator.tick()

        XCTAssertEqual(callOrder, ["start:B", "stop", "start:A"])
        XCTAssertEqual(coordinator.autoMeetingId, meetingA.id)
    }

    func testSkipChoicePreventsStartForBothOverlappingMeetings() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startCount = 0
        coordinator.onStart = { _ in
            startCount += 1
            isRecording = true
        }
        var statusText = ""
        coordinator.onStatusText = { statusText = $0 }
        var chooseCalls = 0
        coordinator.onChoose = { _ in chooseCalls += 1 }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertEqual(chooseCalls, 1)
        XCTAssertTrue(statusText.contains("선택 대기"), statusText)

        coordinator.skipChoice()
        XCTAssertNil(coordinator.pendingChoiceIds)

        coordinator.tick()
        currentDate = meetingB.end.addingTimeInterval(5)
        coordinator.tick()
        currentDate = meetingA.end.addingTimeInterval(-5)
        coordinator.tick()

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(chooseCalls, 1)
    }

    func testPendingChoiceBecomesObsoleteWhenOneMeetingEnds() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startedMeeting: Meeting?
        coordinator.onStart = { meeting in
            startedMeeting = meeting
            isRecording = true
        }
        coordinator.onChoose = { _ in }
        var obsoleteCount = 0
        coordinator.onChoiceObsolete = { obsoleteCount += 1 }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertNotNil(coordinator.pendingChoiceIds)

        currentDate = meetingB.end.addingTimeInterval(5)
        coordinator.tick()

        XCTAssertEqual(obsoleteCount, 1)
        XCTAssertNil(coordinator.pendingChoiceIds)
        XCTAssertEqual(startedMeeting, meetingA)
        XCTAssertEqual(coordinator.autoMeetingId, meetingA.id)
    }

    func testChooseWhileAlreadyRecordingSkipsBothMeetings() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startCount = 0
        coordinator.onStart = { _ in startCount += 1 }
        var chooseCalls = 0
        coordinator.onChoose = { _ in chooseCalls += 1 }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertEqual(chooseCalls, 1)

        // A manual recording started while the prompt was up.
        isRecording = true
        coordinator.choose(meetingB)

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(coordinator.pendingChoiceIds)
        XCTAssertNil(coordinator.autoMeetingId)

        // Both meetings were marked finished, so neither restarts nor re-prompts once idle again.
        isRecording = false
        coordinator.tick()
        currentDate = meetingB.end.addingTimeInterval(5)
        coordinator.tick()

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(chooseCalls, 1)
        XCTAssertNil(coordinator.pendingChoiceIds)
    }

    func testChooseWhileStartInFlightSkipsBothMeetings() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        var startInFlight = false
        coordinator.isStartInFlightProvider = { startInFlight }
        var startCount = 0
        coordinator.onStart = { _ in startCount += 1 }
        var chooseCalls = 0
        coordinator.onChoose = { _ in chooseCalls += 1 }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertEqual(chooseCalls, 1)

        startInFlight = true
        coordinator.choose(meetingB)

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(coordinator.pendingChoiceIds)
        XCTAssertNil(coordinator.autoMeetingId)

        startInFlight = false
        coordinator.tick()
        currentDate = meetingB.end.addingTimeInterval(5)
        coordinator.tick()

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(chooseCalls, 1)
    }

    func testChooseIgnoresMeetingOutsidePendingSet() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        var startCount = 0
        coordinator.onStart = { _ in startCount += 1 }
        coordinator.onChoose = { _ in }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.pendingChoiceIds, ["A", "B"])

        let stranger = Meeting(
            id: "Z",
            title: "Not offered",
            start: currentDate.addingTimeInterval(-30),
            end: currentDate.addingTimeInterval(900)
        )
        coordinator.choose(stranger)

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(coordinator.autoMeetingId)
        XCTAssertEqual(coordinator.pendingChoiceIds, ["A", "B"])
    }

    func testDisablingWhileChoicePendingMakesItObsolete() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        coordinator.onChoose = { _ in }
        var obsoleteCount = 0
        coordinator.onChoiceObsolete = { obsoleteCount += 1 }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertNotNil(coordinator.pendingChoiceIds)

        coordinator.setEnabled(false)

        XCTAssertEqual(obsoleteCount, 1)
        XCTAssertNil(coordinator.pendingChoiceIds)
    }

    func testChoicePromptRepeatsWhenCandidateSetGrows() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        var chooseCalls: [[Meeting]] = []
        coordinator.onChoose = { chooseCalls.append($0) }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)
        XCTAssertEqual(chooseCalls.count, 1)
        XCTAssertEqual(chooseCalls[0].count, 2)

        let meetingC = Meeting(
            id: "C",
            title: "Meeting C",
            start: currentDate.addingTimeInterval(-30),
            end: currentDate.addingTimeInterval(1200)
        )
        source.meetingsToReturn = [meetingA, meetingB, meetingC]
        coordinator.tick()

        XCTAssertEqual(chooseCalls.count, 2)
        XCTAssertEqual(Set(chooseCalls[1].map { $0.id }), ["A", "B", "C"])
        XCTAssertEqual(coordinator.pendingChoiceIds, ["A", "B", "C"])
    }

    func testStartInFlightStillStopsEndedAutoMeeting() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        var startInFlight = false
        coordinator.isStartInFlightProvider = { startInFlight }
        coordinator.onStart = { _ in isRecording = true }
        var stopCount = 0
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
        XCTAssertEqual(coordinator.autoMeetingId, meeting.id)

        startInFlight = true
        currentDate = meeting.end.addingTimeInterval(60)
        coordinator.tick()

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(coordinator.autoMeetingId)
    }

    func testDisablingBeforeAccessCompletionDoesNotStartTicking() {
        source.deferAccess = true
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        var startCount = 0
        coordinator.onStart = { _ in startCount += 1 }
        var statusText = ""
        coordinator.onStatusText = { statusText = $0 }

        source.meetingsToReturn = [
            Meeting(
                id: "m1",
                title: "Weekly Sync",
                start: currentDate.addingTimeInterval(-60),
                end: currentDate.addingTimeInterval(600)
            )
        ]

        coordinator.setEnabled(true)
        XCTAssertEqual(startCount, 0)

        coordinator.setEnabled(false)
        XCTAssertEqual(statusText, "자동: 꺼짐")

        source.completePendingAccess(granted: true)

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(coordinator.autoMeetingId)
        XCTAssertEqual(statusText, "자동: 꺼짐")
        XCTAssertFalse(sleepPreventer.isActive)
    }

    // MARK: - Power assertion

    func testPowerAssertionHeldWhenNextMeetingIsWithinLeadTime() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        source.meetingsToReturn = [
            Meeting(
                id: "soon",
                title: "Soon",
                start: currentDate.addingTimeInterval(600),
                end: currentDate.addingTimeInterval(3600)
            )
        ]

        coordinator.setEnabled(true)

        XCTAssertTrue(sleepPreventer.isActive)
        XCTAssertEqual(sleepPreventer.activateCount, 1)
        XCTAssertEqual(sleepPreventer.lastReason, "Wiret meeting recording")
    }

    func testPowerAssertionNotHeldWhenNextMeetingIsFarAway() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        source.meetingsToReturn = [
            Meeting(
                id: "later",
                title: "Later",
                start: currentDate.addingTimeInterval(7200),
                end: currentDate.addingTimeInterval(10800)
            )
        ]

        coordinator.setEnabled(true)

        XCTAssertFalse(sleepPreventer.isActive)
        XCTAssertEqual(sleepPreventer.activateCount, 0)
    }

    func testPowerAssertionHeldWhileAutoRecording() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        coordinator.onStart = { _ in isRecording = true }
        source.meetingsToReturn = [
            Meeting(
                id: "m1",
                title: "Weekly Sync",
                start: currentDate.addingTimeInterval(-60),
                end: currentDate.addingTimeInterval(600)
            )
        ]

        coordinator.setEnabled(true)

        XCTAssertTrue(sleepPreventer.isActive)
    }

    func testPowerAssertionHeldWhileChoiceIsPending() {
        let coordinator = makeCoordinator()
        coordinator.isRecordingProvider = { false }
        coordinator.onChoose = { _ in }

        let (meetingA, meetingB) = makeOverlappingMeetings()
        source.meetingsToReturn = [meetingA, meetingB]

        coordinator.setEnabled(true)

        XCTAssertNotNil(coordinator.pendingChoiceIds)
        XCTAssertNil(coordinator.autoMeetingId)
        XCTAssertTrue(sleepPreventer.isActive)
        XCTAssertEqual(sleepPreventer.activateCount, 1)
    }

    func testDisablingAutoReleasesPowerAssertion() {
        let coordinator = makeCoordinator()
        var isRecording = false
        coordinator.isRecordingProvider = { isRecording }
        coordinator.onStart = { _ in isRecording = true }
        coordinator.onStop = { isRecording = false }
        source.meetingsToReturn = [
            Meeting(
                id: "m1",
                title: "Weekly Sync",
                start: currentDate.addingTimeInterval(-60),
                end: currentDate.addingTimeInterval(600)
            )
        ]

        coordinator.setEnabled(true)
        XCTAssertTrue(sleepPreventer.isActive)

        coordinator.setEnabled(false)

        XCTAssertFalse(sleepPreventer.isActive)
        XCTAssertEqual(sleepPreventer.releaseCount, 1)
    }
}
