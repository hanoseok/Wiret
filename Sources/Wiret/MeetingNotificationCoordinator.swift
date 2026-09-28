import Foundation

/// 사용자에게 띄울 회의 알림.
enum MeetingNotificationPrompt: Equatable {
    /// 회의가 시작됐다. 녹음을 시작할지 묻는다.
    case start(Meeting)
    /// 녹음 중에 회의 종료 시간이 됐다. 녹음을 어떻게 끝낼지 묻는다.
    case end(Meeting)
}

/// 알림에서 사용자가 고른 답.
enum MeetingNotificationResponse: Equatable {
    case startRecording
    case stopNow
    case stopLater(minutes: Int)
    case cancel
}

/// 캘린더 회의 시작·종료 시각에 맞춰 녹음 시작/중단 알림을 띄운다.
///
/// 자동 녹음과 달리 스스로 녹음을 시작하거나 끝내지 않는다. 결정은 늘 사용자가 알림에서 한다.
/// 자동 녹음과 겹치지 않도록, 자동이 켜져 있으면 시작 알림을 띄우지 않는다. 자동이 녹음을 맡고 있는
/// 동안에는 끼어들지 않다가, 회의가 끝나면 자동이 녹음을 멈추지 않고 넘겨준다(`adoptEndedRecording(of:)`).
/// 그때부터 수동 녹음처럼 종료 알림으로 끝낼지 묻는다.
final class MeetingNotificationCoordinator {
    private static let enabledKey = "meetingNotificationsEnabled"
    /// "몇 분 후 종료"에서 고를 수 있는 시간(분).
    static let delayOptions = [5, 10, 15, 30]
    /// 처리한 회의 기록을 이만큼 지난 뒤에 지운다. 회의를 읽는 범위(12시간 전부터)와 맞춘다.
    private static let handledRetention: TimeInterval = 12 * 3600

    private let source: MeetingSource
    private let defaults: UserDefaults
    private let now: () -> Date
    private var timer: Timer?

    /// 시작 알림을 이미 띄웠거나 띄울 필요가 없어진 회의. 값은 회의 종료 시각으로, 오래된 기록을 지울 때 쓴다.
    private var startHandledIds: [String: Date] = [:]
    /// 종료 알림을 이미 띄운 회의. 같은 회의에 종료 알림이 두 번 뜨지 않게 한다.
    private var endPromptedIds: [String: Date] = [:]

    var onPrompt: ((MeetingNotificationPrompt) -> Void)?
    /// 떠 있던 알림이 더 이상 의미가 없어졌을 때(회의가 끝났거나 녹음이 이미 시작됐을 때 등).
    var onPromptObsolete: (() -> Void)?
    var onStart: ((Meeting) -> Void)?
    var onStop: (() -> Void)?
    var onAccessDenied: (() -> Void)?
    var isRecordingProvider: (() -> Bool)?
    var isStartInFlightProvider: (() -> Bool)?
    /// 자동 녹음이 켜져 있으면 회의 시작은 자동이 맡는다.
    var isAutoEnabledProvider: (() -> Bool)?
    /// 지금 녹음을 자동이 맡고 있는지. 맡고 있는 동안에는 자동이 알아서 하므로 지켜보지 않는다.
    var isAutoRecordingProvider: (() -> Bool)?
    /// 음성 메모 앱이 직접 녹음 중인지. 그동안에는 시작 알림을 띄우지 않는다.
    var isExternalRecordingProvider: (() -> Bool)?
    /// 오늘 일정 화면에서 뺀 회의. 녹음하고 싶지 않다는 뜻이므로 알림도 띄우지 않는다.
    var excludedMeetingIdsProvider: (() -> Set<String>)?

    private(set) var pendingPrompt: MeetingNotificationPrompt?
    /// "몇 분 후 종료"로 예약한 중단 시각.
    private(set) var scheduledStopDate: Date?
    /// 종료 알림을 띄울 대상으로 지켜보는, 지금 녹음 중인 회의.
    private(set) var trackedMeetingId: String?

    init(source: MeetingSource, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.defaults = defaults
        self.now = now
        // source.onChange는 AutoRecordingCoordinator가 쓰므로 여기서 건드리지 않는다.
        // 캘린더 변경은 AppDelegate가 두 코디네이터에 함께 전달한다.
    }

    deinit {
        timer?.invalidate()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// 실행할 때 호출한다. 켜져 있었다면 조용히 다시 켠다.
    func start() {
        if isEnabled {
            setEnabled(true)
        }
    }

    func releaseForTermination() {
        stopTimer()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            source.requestAccess { [weak self] granted in
                guard let self else { return }
                // 권한을 기다리는 사이에 다시 꺼졌을 수 있다.
                guard self.isEnabled else { return }
                if granted {
                    self.startTimer()
                    self.tick()
                } else {
                    self.defaults.set(false, forKey: Self.enabledKey)
                    self.onAccessDenied?()
                }
            }
        } else {
            stopTimer()
            resetState()
        }
    }

    /// 어디서 시작했든 녹음이 시작됐다. 시작 알림은 더 이상 물을 게 없다.
    func noteRecordingStarted() {
        if case .start = pendingPrompt {
            clearPendingPrompt()
        }
    }

    /// 어디서 멈췄든 녹음이 끝났다. 지켜보던 회의와 예약한 중단은 의미가 없어진다.
    func noteRecordingStopped() {
        trackedMeetingId = nil
        scheduledStopDate = nil
        if case .end = pendingPrompt {
            clearPendingPrompt()
        }
    }

    /// 자동 녹음이 회의가 끝난 녹음을 멈추지 않고 넘겨줬다. 그 회의의 종료 알림을 바로 띄운다.
    ///
    /// 다른 알림이 떠 있으면 그 회의를 지켜보기만 한다. 떠 있던 알림이 사라진 뒤 `tick()`에서
    /// 지켜보던 회의가 이미 끝났으므로 종료 알림이 뜬다.
    func adoptEndedRecording(of meeting: Meeting) {
        guard isEnabled, isRecording else { return }
        trackedMeetingId = meeting.id
        guard pendingPrompt == nil,
              scheduledStopDate == nil,
              endPromptedIds[meeting.id] == nil else { return }
        endPromptedIds[meeting.id] = meeting.end
        present(.end(meeting))
    }

    /// 알림에서 요청한 녹음 시작이 실패했다.
    func noteStartFailed() {
        trackedMeetingId = nil
    }

    /// - Parameter prompt: 사용자가 답한 알림. 응답은 비동기로 넘어오므로, 그사이 다른 알림으로 바뀌었다면
    ///   지난 알림에 대한 답이 지금 알림을 처리해 버리지 않도록 무시한다. 알림과 맞지 않는 답도 무시한다.
    func respond(_ response: MeetingNotificationResponse, to prompt: MeetingNotificationPrompt) {
        guard prompt == pendingPrompt else { return }

        switch (response, prompt) {
        case (.startRecording, .start(let meeting)):
            pendingPrompt = nil
            // 알림이 떠 있는 사이 상황이 바뀌었으면(알림 꺼짐, 이미 녹음 중, 자동이 회의를 맡음, 음성 메모가
            // 직접 녹음 중) 두 번째 녹음을 시작하지 않는다.
            guard isEnabled,
                  !isRecording,
                  isStartInFlightProvider?() != true,
                  isAutoEnabledProvider?() != true,
                  isExternalRecordingProvider?() != true else { return }
            trackedMeetingId = meeting.id
            onStart?(meeting)
        case (.stopNow, .end):
            pendingPrompt = nil
            guard isRecording else { return }
            trackedMeetingId = nil
            onStop?()
        case (.stopLater(let minutes), .end):
            pendingPrompt = nil
            guard isRecording else { return }
            scheduledStopDate = now().addingTimeInterval(TimeInterval(minutes) * 60)
        case (.cancel, .end):
            pendingPrompt = nil
            // 녹음은 그대로 이어 간다. 겹쳐 있던 다음 회의가 있으면 그 회의를 지켜본다.
            trackedMeetingId = nil
        case (.cancel, .start):
            // 회의는 이미 처리한 것으로 남아 있어 다시 묻지 않는다.
            pendingPrompt = nil
        default:
            break
        }
    }

    func tick() {
        guard isEnabled else {
            if pendingPrompt != nil {
                clearPendingPrompt()
            }
            return
        }

        let referenceDate = now()
        pruneHandled(before: referenceDate.addingTimeInterval(-Self.handledRetention))

        // 예약한 중단 시각이 됐다.
        if let scheduledStopDate, referenceDate >= scheduledStopDate {
            self.scheduledStopDate = nil
            trackedMeetingId = nil
            if isRecording {
                onStop?()
                return
            }
        }

        let meetings = notifiableMeetings(around: referenceDate)
        let current = MeetingSchedule.currentAll(in: meetings, at: referenceDate)

        dropObsoletePrompt(current: current)
        // 알림은 한 번에 하나만 띄운다.
        if pendingPrompt != nil { return }

        if isRecording {
            checkRecording(meetings: meetings, current: current, at: referenceDate)
        } else {
            checkIdle(current: current)
        }
    }

    private var isRecording: Bool {
        isRecordingProvider?() ?? false
    }

    private func dropObsoletePrompt(current: [Meeting]) {
        switch pendingPrompt {
        case .start(let meeting):
            let obsolete = !current.contains { $0.id == meeting.id }
                || isRecording
                || isStartInFlightProvider?() == true
                || isAutoEnabledProvider?() == true
                || isExternalRecordingProvider?() == true
            if obsolete { clearPendingPrompt() }
        case .end:
            if !isRecording { clearPendingPrompt() }
        case nil:
            break
        }
    }

    private func checkRecording(meetings: [Meeting], current: [Meeting], at referenceDate: Date) {
        // 자동이 맡은 녹음은 자동이 회의 끝에 멈추거나 이쪽으로 넘겨준다. 그 시간대 회의는 자동을 꺼 녹음이
        // 멈춰도 다시 묻지 않는다.
        if isAutoRecordingProvider?() == true {
            markStartHandled(current)
            return
        }

        guard let trackedMeetingId else {
            let untracked = current.filter { endPromptedIds[$0.id] == nil }
            self.trackedMeetingId = MeetingSchedule.current(in: untracked, at: referenceDate)?.id
            markStartHandled(current)
            return
        }

        // 녹음 중에 회의가 지워지거나 제외되면 더 지켜볼 대상이 없다.
        guard let meeting = meetings.first(where: { $0.id == trackedMeetingId }) else {
            self.trackedMeetingId = nil
            return
        }

        if referenceDate >= meeting.end {
            if scheduledStopDate == nil, endPromptedIds[meeting.id] == nil {
                endPromptedIds[meeting.id] = meeting.end
                present(.end(meeting))
            }
            // 지켜보던 회의가 끝난 뒤 시작한 회의(연달아 잡힌 회의)는 처리한 것으로 두지 않는다.
            // 사용자가 지금 종료하거나 예약 중단으로 녹음이 끝나면 그 회의의 시작 알림을 띄워야 한다.
            return
        }

        // 이미 녹음 중인 시간대의 회의는, 도중에 녹음을 멈춰도 시작 알림으로 다시 묻지 않는다.
        markStartHandled(current)
    }

    private func markStartHandled(_ meetings: [Meeting]) {
        for meeting in meetings {
            startHandledIds[meeting.id] = meeting.end
        }
    }

    private func checkIdle(current: [Meeting]) {
        // 시작 요청이 처리되는 중이면 결과를 기다린다.
        if isStartInFlightProvider?() == true { return }

        let candidates = current.filter { startHandledIds[$0.id] == nil }
        if candidates.isEmpty { return }

        // 자동 녹음이 맡거나 음성 메모로 직접 녹음 중이면 묻지 않는다. 나중에 끝나도 다시 묻지 않도록 처리한 것으로 둔다.
        if isAutoEnabledProvider?() == true || isExternalRecordingProvider?() == true {
            markStartHandled(candidates)
            return
        }

        // 겹친 회의는 하나씩 묻는다. 나머지는 사용자가 답한 뒤 다음 확인에서 묻는다.
        let meeting = candidates[0]
        startHandledIds[meeting.id] = meeting.end
        present(.start(meeting))
    }

    private func present(_ prompt: MeetingNotificationPrompt) {
        pendingPrompt = prompt
        onPrompt?(prompt)
    }

    private func clearPendingPrompt() {
        pendingPrompt = nil
        onPromptObsolete?()
    }

    private func resetState() {
        if pendingPrompt != nil {
            clearPendingPrompt()
        }
        scheduledStopDate = nil
        trackedMeetingId = nil
        startHandledIds.removeAll()
        endPromptedIds.removeAll()
    }

    /// 종료된 지 오래된 회의 기록은 다시 쓸 일이 없다. 하루 종일 켜 두는 앱이라 쌓이지 않게 지운다.
    private func pruneHandled(before cutoff: Date) {
        startHandledIds = startHandledIds.filter { $0.value >= cutoff }
        endPromptedIds = endPromptedIds.filter { $0.value >= cutoff }
    }

    /// 알림 대상 회의. 오늘 일정에서 뺀 회의는 녹음하고 싶지 않다는 뜻이라 알림에서도 뺀다.
    private func notifiableMeetings(around referenceDate: Date) -> [Meeting] {
        let meetings = source.meetings(
            from: referenceDate.addingTimeInterval(-12 * 3600),
            to: referenceDate.addingTimeInterval(24 * 3600)
        )
        guard let excluded = excludedMeetingIdsProvider?(), !excluded.isEmpty else {
            return meetings
        }
        return meetings.filter { !excluded.contains($0.id) }
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 2
        // .common이어야 경고창이나 메뉴가 열려 있는 동안에도 알림 시각을 놓치지 않는다.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
