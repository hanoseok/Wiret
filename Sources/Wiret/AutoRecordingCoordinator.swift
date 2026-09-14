import Foundation

final class AutoRecordingCoordinator {
    private static let enabledKey = "autoRecordingEnabled"

    private let source: MeetingSource
    private let defaults: UserDefaults
    private let now: () -> Date
    private var timer: Timer?
    private var lastFinishedAutoMeetingId: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var onStatusText: ((String) -> Void)?
    var onStart: ((Meeting) -> Void)?
    var onStop: (() -> Void)?
    var onAccessDenied: (() -> Void)?
    var isRecordingProvider: (() -> Bool)?
    var isStartInFlightProvider: (() -> Bool)?
    private(set) var autoMeetingId: String?

    init(source: MeetingSource, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.defaults = defaults
        self.now = now
        self.source.onChange = { [weak self] in self?.tick() }
    }

    deinit {
        timer?.invalidate()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// Call at launch: if isEnabled, run the setEnabled(true) flow silently.
    func start() {
        if isEnabled {
            setEnabled(true)
        } else {
            updateStatusText(current: nil, next: nil)
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            lastFinishedAutoMeetingId = nil
            source.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startTimer()
                    self.tick()
                } else {
                    self.defaults.set(false, forKey: Self.enabledKey)
                    self.onStatusText?("캘린더 권한 필요")
                    self.onAccessDenied?()
                }
            }
        } else {
            stopTimer()
            tick()
        }
    }

    func noteManualStop() {
        if autoMeetingId != nil {
            lastFinishedAutoMeetingId = autoMeetingId
        }
        autoMeetingId = nil
    }

    func noteAutoStartFailed() {
        lastFinishedAutoMeetingId = autoMeetingId
        autoMeetingId = nil
    }

    func tick() {
        let referenceDate = now()
        let meetings = source.meetings(
            from: referenceDate.addingTimeInterval(-12 * 3600),
            to: referenceDate.addingTimeInterval(24 * 3600)
        )
        let current = MeetingSchedule.current(in: meetings, at: referenceDate)
        let next = MeetingSchedule.next(in: meetings, after: referenceDate)

        if isStartInFlightProvider?() == true {
            updateStatusText(current: current, next: next)
            return
        }

        let state = AutoRecordState(
            autoEnabled: isEnabled,
            isRecording: isRecordingProvider?() ?? false,
            autoMeetingId: autoMeetingId
        )
        let action = AutoRecordPolicy.decide(state: state, current: current, lastFinishedAutoMeetingId: lastFinishedAutoMeetingId)

        switch action {
        case .start(let meeting):
            autoMeetingId = meeting.id
            onStart?(meeting)
        case .stop:
            lastFinishedAutoMeetingId = autoMeetingId
            autoMeetingId = nil
            onStop?()

            // Back-to-back meetings: re-evaluate once more with the refreshed state so a
            // meeting that starts the instant the previous one ends isn't delayed a full tick.
            let refreshedState = AutoRecordState(
                autoEnabled: isEnabled,
                isRecording: isRecordingProvider?() ?? false,
                autoMeetingId: autoMeetingId
            )
            if case .start(let meeting) = AutoRecordPolicy.decide(state: refreshedState, current: current, lastFinishedAutoMeetingId: lastFinishedAutoMeetingId) {
                autoMeetingId = meeting.id
                onStart?(meeting)
            }
        case .none:
            break
        }

        updateStatusText(current: current, next: next)
    }

    private func updateStatusText(current: Meeting?, next: Meeting?) {
        guard isEnabled else {
            onStatusText?("자동: 꺼짐")
            return
        }

        if let autoMeetingId,
           let current,
           current.id == autoMeetingId,
           isRecordingProvider?() ?? false {
            onStatusText?("녹음 중: \(current.title) (~\(Self.timeFormatter.string(from: current.end)))")
            return
        }

        if let next {
            onStatusText?("다음 회의: \(next.title) (\(Self.timeFormatter.string(from: next.start)))")
            return
        }

        onStatusText?("자동: 예정된 회의 없음")
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 5
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
