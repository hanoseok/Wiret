import XCTest
@testable import Wiret

private final class FakeNotificationMeetingSource: MeetingSource {
    var onChange: (() -> Void)?
    var meetingsToReturn: [Meeting] = []
    var accessGranted = true
    private(set) var accessRequestCount = 0

    func requestAccess(completion: @escaping (Bool) -> Void) {
        accessRequestCount += 1
        completion(accessGranted)
    }

    func meetings(from: Date, to: Date) -> [Meeting] {
        meetingsToReturn
    }

    var availableCalendars: [CalendarInfo] = []
    var selectedCalendarIDs: Set<String> = []
}

final class MeetingNotificationCoordinatorTests: XCTestCase {
    private let suiteName = "MeetingNotificationCoordinatorTests"
    private var defaults: UserDefaults!
    private var source: FakeNotificationMeetingSource!
    private var currentDate = Date(timeIntervalSince1970: 1_700_000_000)

    // 코디네이터가 읽는 앱 상태를 흉내 낸다.
    private var isRecording = false
    private var isStartInFlight = false
    private var isAutoEnabled = false
    private var isAutoRecording = false
    private var isExternalRecording = false
    private var excludedIds: Set<String> = []

    // 코디네이터가 내보낸 것들.
    private var prompts: [MeetingNotificationPrompt] = []
    private var obsoleteCount = 0
    private var startedMeetings: [Meeting] = []
    private var stopCount = 0
    private var accessDeniedCount = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        source = FakeNotificationMeetingSource()
        currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        isRecording = false
        isStartInFlight = false
        isAutoEnabled = false
        isAutoRecording = false
        isExternalRecording = false
        excludedIds = []
        prompts = []
        obsoleteCount = 0
        startedMeetings = []
        stopCount = 0
        accessDeniedCount = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        source = nil
        super.tearDown()
    }

    private func makeNotifier() -> MeetingNotificationCoordinator {
        let notifier = MeetingNotificationCoordinator(
            source: source,
            defaults: defaults,
            now: { [weak self] in self?.currentDate ?? Date() }
        )
        notifier.isRecordingProvider = { [weak self] in self?.isRecording ?? false }
        notifier.isStartInFlightProvider = { [weak self] in self?.isStartInFlight ?? false }
        notifier.isAutoEnabledProvider = { [weak self] in self?.isAutoEnabled ?? false }
        notifier.isAutoRecordingProvider = { [weak self] in self?.isAutoRecording ?? false }
        notifier.isExternalRecordingProvider = { [weak self] in self?.isExternalRecording ?? false }
        notifier.excludedMeetingIdsProvider = { [weak self] in self?.excludedIds ?? [] }
        notifier.onPrompt = { [weak self] in self?.prompts.append($0) }
        notifier.onPromptObsolete = { [weak self] in self?.obsoleteCount += 1 }
        notifier.onStart = { [weak self] in self?.startedMeetings.append($0) }
        notifier.onStop = { [weak self] in self?.stopCount += 1 }
        notifier.onAccessDenied = { [weak self] in self?.accessDeniedCount += 1 }
        return notifier
    }

    /// 지금(currentDate) 기준으로 시작·종료 시각을 초 단위로 받는다.
    private func meeting(_ id: String, from start: TimeInterval, to end: TimeInterval) -> Meeting {
        Meeting(
            id: id,
            title: "회의 \(id)",
            start: currentDate.addingTimeInterval(start),
            end: currentDate.addingTimeInterval(end)
        )
    }

    /// 지금 떠 있는 알림에 답한다. 창이 자기 알림을 함께 넘기는 것과 같다.
    private func answer(_ notifier: MeetingNotificationCoordinator, _ response: MeetingNotificationResponse) {
        guard let prompt = notifier.pendingPrompt else { return }
        notifier.respond(response, to: prompt)
    }

    /// 알림으로 녹음을 시작한 상태를 만든다.
    private func startRecordingFromNotification(_ notifier: MeetingNotificationCoordinator) {
        answer(notifier, .startRecording)
        isRecording = true
        notifier.noteRecordingStarted()
    }

    // MARK: - 켜고 끄기

    func testDisabledByDefaultAndNeverPrompts() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.start()
        notifier.tick()

        XCTAssertFalse(notifier.isEnabled)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(source.accessRequestCount, 0)
    }

    func testEnablingPersistsAndPromptsStartForMeetingInProgress() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertTrue(notifier.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "meetingNotificationsEnabled"))
        XCTAssertEqual(prompts, [.start(m1)])
        XCTAssertEqual(notifier.pendingPrompt, .start(m1))
    }

    func testStartAtLaunchRestoresEnabledState() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        defaults.set(true, forKey: "meetingNotificationsEnabled")
        let notifier = makeNotifier()

        notifier.start()

        XCTAssertEqual(prompts, [.start(m1)])
    }

    func testNoPromptBeforeMeetingStarts() {
        let m1 = meeting("m1", from: 60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        XCTAssertTrue(prompts.isEmpty)

        currentDate = m1.start
        notifier.tick()

        XCTAssertEqual(prompts, [.start(m1)])
    }

    func testAccessDeniedTurnsOffAndReports() {
        source.accessGranted = false
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertFalse(notifier.isEnabled)
        XCTAssertEqual(accessDeniedCount, 1)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testDisablingDropsPendingPromptAndScheduledStop() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        XCTAssertNotNil(notifier.pendingPrompt)

        notifier.setEnabled(false)

        XCTAssertFalse(notifier.isEnabled)
        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
        XCTAssertFalse(defaults.bool(forKey: "meetingNotificationsEnabled"))
    }

    func testDisablingCancelsScheduledStop() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        startRecordingFromNotification(notifier)
        currentDate = m1.end
        notifier.tick()
        answer(notifier, .stopLater(minutes: 5))
        XCTAssertNotNil(notifier.scheduledStopDate)

        notifier.setEnabled(false)
        currentDate = m1.end.addingTimeInterval(10 * 60)
        notifier.tick()

        XCTAssertNil(notifier.scheduledStopDate)
        XCTAssertEqual(stopCount, 0)
    }

    // MARK: - 시작 알림

    func testStartPromptAppearsOnlyOncePerMeeting() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        notifier.tick()
        answer(notifier, .cancel)
        notifier.tick()
        notifier.tick()

        XCTAssertEqual(prompts.count, 1)
    }

    func testStartRecordingResponseStartsAndTracksMeeting() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        answer(notifier, .startRecording)

        XCTAssertEqual(startedMeetings, [m1])
        XCTAssertEqual(notifier.trackedMeetingId, "m1")
        XCTAssertNil(notifier.pendingPrompt)
    }

    func testCancellingStartDoesNotStartOrPromptAgain() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        answer(notifier, .cancel)
        currentDate = currentDate.addingTimeInterval(60)
        notifier.tick()

        XCTAssertTrue(startedMeetings.isEmpty)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertNil(notifier.pendingPrompt)
    }

    /// 알림이 떠 있는 사이 다른 경로로 녹음이 시작됐으면 두 번째 녹음을 시작하지 않는다.
    func testStartRecordingIsIgnoredWhenAlreadyRecording() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        isRecording = true

        answer(notifier, .startRecording)

        XCTAssertTrue(startedMeetings.isEmpty)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    func testResponsesWithoutMatchingPromptAreIgnored() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        answer(notifier, .stopNow)
        answer(notifier, .stopLater(minutes: 5))

        XCTAssertEqual(stopCount, 0)
        XCTAssertNil(notifier.scheduledStopDate)
        // 시작 알림은 그대로 남아 있다.
        XCTAssertNotNil(notifier.pendingPrompt)
    }

    /// 알림이 떠 있는 사이 자동이 켜졌다면 자동이 회의를 맡으므로 알림에서 녹음을 시작하지 않는다.
    func testStartRecordingIsIgnoredWhenAutoWasEnabledMeanwhile() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        isAutoEnabled = true

        answer(notifier, .startRecording)

        XCTAssertTrue(startedMeetings.isEmpty)
        XCTAssertNil(notifier.trackedMeetingId)
        XCTAssertNil(notifier.pendingPrompt)
    }

    /// 알림이 떠 있는 사이 음성 메모로 직접 녹음을 시작했다면 끼어들지 않는다.
    func testStartRecordingIsIgnoredWhenVoiceMemosStartedRecordingMeanwhile() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        isExternalRecording = true

        answer(notifier, .startRecording)

        XCTAssertTrue(startedMeetings.isEmpty)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    /// 지난 알림에 대한 늦은 답이 지금 떠 있는 알림을 처리해 버리면 안 된다.
    func testResponseToStalePromptIsIgnored() {
        let early = meeting("early", from: -600, to: 1800)
        let late = meeting("late", from: -60, to: 1200)
        source.meetingsToReturn = [early, late]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        XCTAssertEqual(notifier.pendingPrompt, .start(late))
        answer(notifier, .cancel)
        notifier.tick()
        XCTAssertEqual(notifier.pendingPrompt, .start(early))

        notifier.respond(.startRecording, to: .start(late))

        XCTAssertTrue(startedMeetings.isEmpty)
        XCTAssertEqual(notifier.pendingPrompt, .start(early))
    }

    func testNoStartPromptWhenAutoIsEnabled() {
        isAutoEnabled = true
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertTrue(prompts.isEmpty)
    }

    /// 자동이 맡았던 회의는 자동을 꺼도 다시 묻지 않는다.
    func testMeetingHandledByAutoIsNotPromptedAfterAutoTurnsOff() {
        isAutoEnabled = true
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        isAutoEnabled = false
        notifier.tick()

        XCTAssertTrue(prompts.isEmpty)
    }

    func testNoStartPromptWhileAlreadyRecording() {
        isRecording = true
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertTrue(prompts.isEmpty)
    }

    /// 녹음 중이던 시간대의 회의는 도중에 녹음을 멈춰도 시작 알림으로 다시 묻지 않는다.
    func testStoppingMidMeetingDoesNotPromptStart() {
        isRecording = true
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        isRecording = false
        notifier.noteRecordingStopped()
        notifier.tick()

        XCTAssertTrue(prompts.isEmpty)
    }

    func testNoStartPromptWhileStartIsInFlight() {
        isStartInFlight = true
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        XCTAssertTrue(prompts.isEmpty)

        // 시작이 실패해 요청이 끝나면 그때 묻는다.
        isStartInFlight = false
        notifier.tick()

        XCTAssertEqual(prompts, [.start(m1)])
    }

    func testNoStartPromptWhileVoiceMemosIsRecording() {
        isExternalRecording = true
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertTrue(prompts.isEmpty)
    }

    func testNoStartPromptForExcludedMeeting() {
        excludedIds = ["m1"]
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()

        notifier.setEnabled(true)

        XCTAssertTrue(prompts.isEmpty)
    }

    func testStartPromptBecomesObsoleteWhenMeetingEnds() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        currentDate = m1.end
        notifier.tick()

        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
    }

    func testStartPromptBecomesObsoleteWhenRecordingStarts() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        isRecording = true
        notifier.noteRecordingStarted()

        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
    }

    func testStartPromptBecomesObsoleteWhenAutoTurnsOn() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        isAutoEnabled = true
        notifier.tick()

        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
    }

    func testStartPromptBecomesObsoleteWhenMeetingIsExcluded() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        excludedIds = ["m1"]
        notifier.tick()

        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
    }

    func testOverlappingMeetingsArePromptedOneAtATime() {
        let early = meeting("early", from: -600, to: 1800)
        let late = meeting("late", from: -60, to: 1200)
        source.meetingsToReturn = [early, late]
        let notifier = makeNotifier()
        notifier.setEnabled(true)

        // 가장 늦게 시작한 회의부터 하나만 묻는다.
        notifier.tick()
        XCTAssertEqual(prompts, [.start(late)])

        answer(notifier, .cancel)
        notifier.tick()

        XCTAssertEqual(prompts, [.start(late), .start(early)])
    }

    // MARK: - 종료 알림

    func testEndPromptAppearsAtMeetingEndWhileRecording() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        startRecordingFromNotification(notifier)

        currentDate = m1.end.addingTimeInterval(-1)
        notifier.tick()
        XCTAssertEqual(prompts, [.start(m1)])

        currentDate = m1.end
        notifier.tick()

        XCTAssertEqual(prompts, [.start(m1), .end(m1)])
        XCTAssertEqual(notifier.pendingPrompt, .end(m1))
    }

    func testNoEndPromptWhenNotRecording() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        answer(notifier, .cancel)

        currentDate = m1.end
        notifier.tick()

        XCTAssertEqual(prompts, [.start(m1)])
    }

    /// 자동이 녹음을 맡고 있는 동안에는 스스로 종료 알림을 띄우지 않는다. 회의가 끝나 자동이 넘겨줄 때 띄운다.
    func testNoEndPromptWhileAutoOwnsRecording() {
        isAutoEnabled = true
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        isRecording = true
        isAutoRecording = true
        notifier.tick()

        currentDate = m1.end
        notifier.tick()

        XCTAssertTrue(prompts.isEmpty)
    }

    /// 메뉴에서 직접 시작한 녹음도 회의 중이었다면 회의가 끝날 때 묻는다.
    func testManualRecordingDuringMeetingGetsEndPrompt() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        XCTAssertEqual(notifier.trackedMeetingId, "m1")

        currentDate = m1.end
        notifier.tick()

        XCTAssertEqual(prompts, [.end(m1)])
    }

    func testEndPromptBecomesObsoleteWhenRecordingStops() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        currentDate = m1.end
        notifier.tick()

        isRecording = false
        notifier.noteRecordingStopped()

        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(obsoleteCount, 1)
    }

    func testStopNowStopsRecording() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        currentDate = m1.end
        notifier.tick()

        answer(notifier, .stopNow)

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    func testStopLaterStopsOnlyAfterTheDelay() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        currentDate = m1.end
        notifier.tick()

        answer(notifier, .stopLater(minutes: 10))
        XCTAssertEqual(notifier.scheduledStopDate, m1.end.addingTimeInterval(600))

        currentDate = m1.end.addingTimeInterval(599)
        notifier.tick()
        XCTAssertEqual(stopCount, 0)

        currentDate = m1.end.addingTimeInterval(600)
        notifier.tick()
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(notifier.scheduledStopDate)
        // 예약 중단을 기다리는 동안 같은 회의로 다시 묻지 않는다.
        XCTAssertEqual(prompts, [.end(m1)])
    }

    /// 예약한 사이 녹음을 직접 멈췄다가 새로 시작했다면, 새 녹음은 예약 시각에 멈추면 안 된다.
    func testStoppingRecordingCancelsScheduledStop() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        currentDate = m1.end
        notifier.tick()
        answer(notifier, .stopLater(minutes: 5))

        isRecording = false
        notifier.noteRecordingStopped()
        XCTAssertNil(notifier.scheduledStopDate)

        currentDate = m1.end.addingTimeInterval(60)
        isRecording = true
        notifier.noteRecordingStarted()
        currentDate = m1.end.addingTimeInterval(10 * 60)
        notifier.tick()

        XCTAssertEqual(stopCount, 0)
    }

    func testCancellingEndKeepsRecordingAndDoesNotAskAgain() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        currentDate = m1.end
        notifier.tick()

        answer(notifier, .cancel)
        currentDate = m1.end.addingTimeInterval(60)
        notifier.tick()
        notifier.tick()

        XCTAssertEqual(stopCount, 0)
        XCTAssertTrue(isRecording)
        XCTAssertNil(notifier.trackedMeetingId)
        XCTAssertEqual(prompts, [.end(m1)])
    }

    /// 종료 알림을 취소하고 녹음을 이어 가면, 이어서 진행 중인 회의가 끝날 때 다시 묻는다.
    func testCancellingEndTracksNextOverlappingMeeting() {
        let first = meeting("first", from: -600, to: 600)
        let second = meeting("second", from: 0, to: 1800)
        source.meetingsToReturn = [first]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)
        XCTAssertEqual(notifier.trackedMeetingId, "first")

        source.meetingsToReturn = [first, second]
        currentDate = first.end
        notifier.tick()
        answer(notifier, .cancel)
        notifier.tick()
        XCTAssertEqual(notifier.trackedMeetingId, "second")

        currentDate = second.end
        notifier.tick()

        XCTAssertEqual(prompts, [.end(first), .end(second)])
    }

    // MARK: - 연달아 잡힌 회의

    /// A가 끝나는 시각에 B가 시작한다. A를 녹음하던 중에 A의 종료 알림이 뜬 상태를 만든다.
    private func recordAThenReachBackToBackB(
        _ notifier: MeetingNotificationCoordinator
    ) -> (a: Meeting, b: Meeting) {
        let a = meeting("A", from: -600, to: 600)
        let b = meeting("B", from: 600, to: 1800)
        source.meetingsToReturn = [a, b]
        isRecording = true
        notifier.setEnabled(true)
        XCTAssertEqual(notifier.trackedMeetingId, "A")

        currentDate = a.end
        notifier.tick()
        XCTAssertEqual(notifier.pendingPrompt, .end(a))
        return (a, b)
    }

    /// 앞 회의 녹음을 지금 종료하면, 막 시작한 다음 회의는 시작 알림으로 물어야 한다.
    func testStopNowAtBackToBackMeetingPromptsStartForNextMeeting() {
        let notifier = makeNotifier()
        let (a, b) = recordAThenReachBackToBackB(notifier)

        answer(notifier, .stopNow)
        XCTAssertEqual(stopCount, 1)
        isRecording = false
        notifier.noteRecordingStopped()
        notifier.tick()

        XCTAssertEqual(prompts, [.end(a), .start(b)])
    }

    /// 몇 분 후 종료를 기다리는 동안에도 다음 회의를 처리한 것으로 두면 안 된다.
    func testStopLaterAtBackToBackMeetingPromptsStartForNextMeetingAfterStop() {
        let notifier = makeNotifier()
        let (a, b) = recordAThenReachBackToBackB(notifier)

        answer(notifier, .stopLater(minutes: 5))
        currentDate = a.end.addingTimeInterval(60)
        notifier.tick()
        currentDate = a.end.addingTimeInterval(4 * 60)
        notifier.tick()
        XCTAssertEqual(prompts, [.end(a)])
        XCTAssertEqual(stopCount, 0)

        currentDate = a.end.addingTimeInterval(5 * 60)
        notifier.tick()
        XCTAssertEqual(stopCount, 1)
        isRecording = false
        notifier.noteRecordingStopped()
        notifier.tick()

        XCTAssertEqual(prompts, [.end(a), .start(b)])
    }

    /// 종료 알림을 취소하면 녹음이 다음 회의로 이어지므로, 다음 회의는 시작이 아니라 종료만 묻는다.
    func testCancellingEndAtBackToBackMeetingTracksNextMeeting() {
        let notifier = makeNotifier()
        let (a, b) = recordAThenReachBackToBackB(notifier)

        answer(notifier, .cancel)
        notifier.tick()
        XCTAssertEqual(notifier.trackedMeetingId, "B")

        currentDate = b.end
        notifier.tick()

        XCTAssertEqual(prompts, [.end(a), .end(b)])
        XCTAssertEqual(stopCount, 0)
    }

    /// 녹음 중에 회의를 오늘 일정에서 빼면 그 회의로는 종료 알림을 띄우지 않는다.
    func testExcludingTrackedMeetingDropsEndPrompt() {
        let m1 = meeting("m1", from: -60, to: 600)
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()
        isRecording = true
        notifier.setEnabled(true)

        excludedIds = ["m1"]
        notifier.tick()
        XCTAssertNil(notifier.trackedMeetingId)

        currentDate = m1.end
        notifier.tick()

        XCTAssertTrue(prompts.isEmpty)
    }

    func testFailedStartClearsTrackedMeeting() {
        source.meetingsToReturn = [meeting("m1", from: -60, to: 600)]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        answer(notifier, .startRecording)
        XCTAssertEqual(notifier.trackedMeetingId, "m1")

        notifier.noteStartFailed()

        XCTAssertNil(notifier.trackedMeetingId)
    }

    // MARK: - 자동 녹음이 넘겨준 녹음

    /// 자동이 녹음을 맡고 있던 상태를 만든다. 회의 중에 자동이 녹음을 시작했다.
    private func makeNotifierWithAutoRecording(_ meeting: Meeting) -> MeetingNotificationCoordinator {
        isAutoEnabled = true
        isRecording = true
        isAutoRecording = true
        source.meetingsToReturn = [meeting]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        return notifier
    }

    /// 회의가 끝나 자동이 녹음을 넘겨준 순간과 같다.
    private func handOff(_ notifier: MeetingNotificationCoordinator, _ meeting: Meeting) {
        currentDate = meeting.end
        isAutoRecording = false
        notifier.adoptEndedRecording(of: meeting)
    }

    func testAdoptedRecordingPromptsEndImmediately() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        XCTAssertTrue(prompts.isEmpty)

        handOff(notifier, m1)

        XCTAssertEqual(prompts, [.end(m1)])
        XCTAssertEqual(notifier.pendingPrompt, .end(m1))
        XCTAssertEqual(notifier.trackedMeetingId, "m1")
    }

    func testAdoptingIsIgnoredWhenNotificationsAreOff() {
        let m1 = meeting("m1", from: -60, to: 600)
        isRecording = true
        source.meetingsToReturn = [m1]
        let notifier = makeNotifier()

        handOff(notifier, m1)
        notifier.tick()

        XCTAssertTrue(prompts.isEmpty)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    func testAdoptingIsIgnoredWhenNotRecording() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        isRecording = false

        handOff(notifier, m1)

        XCTAssertTrue(prompts.isEmpty)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    /// 다른 알림이 떠 있으면 겹쳐 띄우지 않는다. 그 알림이 사라진 뒤 확인에서 종료 알림이 뜬다.
    func testAdoptingWhilePromptPendingPromptsEndAfterItIsAnswered() {
        // 자동이 꺼져 있는 동안 다음 회의의 시작 알림이 떠 있다. 그사이 자동을 켜 녹음이 시작됐다.
        let m1 = meeting("m1", from: -60, to: 600)
        let m2 = meeting("m2", from: 0, to: 1800)
        source.meetingsToReturn = [m2]
        let notifier = makeNotifier()
        notifier.setEnabled(true)
        XCTAssertEqual(notifier.pendingPrompt, .start(m2))
        source.meetingsToReturn = [m1, m2]
        isRecording = true

        handOff(notifier, m1)
        XCTAssertEqual(prompts, [.start(m2)])
        XCTAssertEqual(notifier.trackedMeetingId, "m1")

        answer(notifier, .cancel)
        notifier.tick()

        XCTAssertEqual(prompts, [.start(m2), .end(m1)])
        XCTAssertEqual(notifier.pendingPrompt, .end(m1))
    }

    func testAdoptedRecordingStopNowStops() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        handOff(notifier, m1)

        answer(notifier, .stopNow)

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertNil(notifier.trackedMeetingId)
    }

    func testAdoptedRecordingStopLaterSchedulesStop() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        handOff(notifier, m1)

        answer(notifier, .stopLater(minutes: 5))
        XCTAssertEqual(notifier.scheduledStopDate, m1.end.addingTimeInterval(300))

        currentDate = m1.end.addingTimeInterval(299)
        notifier.tick()
        XCTAssertEqual(stopCount, 0)

        currentDate = m1.end.addingTimeInterval(300)
        notifier.tick()
        XCTAssertEqual(stopCount, 1)
    }

    func testAdoptedRecordingCancelKeepsRecording() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        handOff(notifier, m1)

        answer(notifier, .cancel)
        currentDate = m1.end.addingTimeInterval(60)
        notifier.tick()

        XCTAssertEqual(stopCount, 0)
        XCTAssertTrue(isRecording)
        XCTAssertNil(notifier.pendingPrompt)
        XCTAssertEqual(prompts, [.end(m1)])
    }

    /// 넘겨받기가 두 번 불리거나 tick이 이어져도 같은 회의로 두 번 묻지 않는다.
    func testAdoptingSameMeetingTwiceDoesNotPromptAgain() {
        let m1 = meeting("m1", from: -60, to: 600)
        let notifier = makeNotifierWithAutoRecording(m1)
        handOff(notifier, m1)
        answer(notifier, .cancel)

        notifier.adoptEndedRecording(of: m1)
        notifier.tick()
        currentDate = m1.end.addingTimeInterval(60)
        notifier.tick()

        XCTAssertEqual(prompts, [.end(m1)])
    }
}
