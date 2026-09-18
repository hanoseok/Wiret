import Foundation

final class AutoRecordingCoordinator {
    private static let enabledKey = "autoRecordingEnabled"
    /// Hold the power assertion from this long before a meeting starts.
    private static let leadTime: TimeInterval = 30 * 60
    private static let assertionReason = "Wiret meeting recording"

    private let source: MeetingSource
    private let defaults: UserDefaults
    private let now: () -> Date
    private let sleepPreventer: SleepPreventing
    private var timer: Timer?
    private var finishedMeetingIds: Set<String> = []
    private(set) var pendingChoiceIds: Set<String>?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var onStatusText: ((String) -> Void)?
    var onStart: ((Meeting) -> Void)?
    var onStop: (() -> Void)?
    var onAccessDenied: (() -> Void)?
    var onChoose: (([Meeting]) -> Void)?
    var onChoiceObsolete: (() -> Void)?
    var isRecordingProvider: (() -> Bool)?
    var isStartInFlightProvider: (() -> Bool)?
    /// 음성 메모 앱이 직접 녹음 중인지. 그동안에는 자동 녹음도 자동 중단도 하지 않는다.
    var isExternalRecordingProvider: (() -> Bool)?
    private(set) var autoMeetingId: String?

    init(
        source: MeetingSource,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        sleepPreventer: SleepPreventing = PowerAssertion()
    ) {
        self.source = source
        self.defaults = defaults
        self.now = now
        self.sleepPreventer = sleepPreventer
        self.source.onChange = { [weak self] in self?.tick() }
    }

    deinit {
        timer?.invalidate()
        sleepPreventer.release()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    /// Call at launch: if isEnabled, run the setEnabled(true) flow silently.
    func start() {
        if isEnabled {
            setEnabled(true)
        } else {
            updateStatusText(current: [], next: nil)
            updatePowerAssertion(current: [], next: nil, at: now())
        }
    }

    /// Call at termination: stop ticking and hand back the power assertion.
    func releaseForTermination() {
        stopTimer()
        sleepPreventer.release()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            finishedMeetingIds.removeAll()
            source.requestAccess { [weak self] granted in
                guard let self else { return }
                // Auto may have been switched off again while access was being resolved.
                guard self.isEnabled else { return }
                if granted {
                    self.startTimer()
                    self.tick()
                } else {
                    self.defaults.set(false, forKey: Self.enabledKey)
                    self.updatePowerAssertion(current: [], next: nil, at: self.now())
                    self.onStatusText?("캘린더 권한 필요")
                    self.onAccessDenied?()
                }
            }
        } else {
            stopTimer()
            // tick() sees auto is off, drops any pending choice prompt and releases the assertion.
            tick()
        }
    }

    func noteManualStop() {
        if let autoMeetingId {
            finishedMeetingIds.insert(autoMeetingId)
        }
        autoMeetingId = nil
    }

    func noteAutoStartFailed() {
        if let autoMeetingId {
            finishedMeetingIds.insert(autoMeetingId)
        }
        autoMeetingId = nil
    }

    /// Record the meeting the user picked in the overlap prompt.
    func choose(_ meeting: Meeting) {
        guard pendingChoiceIds?.contains(meeting.id) == true else { return }
        // The world may have moved on while the prompt was up (auto switched off, a recording already
        // running or being started) — treat the answer as a skip rather than starting a second recording.
        if !isEnabled || isRecordingProvider?() == true || isStartInFlightProvider?() == true {
            skipChoice()
            return
        }
        pendingChoiceIds = nil
        autoMeetingId = meeting.id
        onStart?(meeting)
        refreshStatusAndPower()
    }

    /// Skip every meeting offered in the overlap prompt.
    func skipChoice() {
        guard let pending = pendingChoiceIds else { return }
        finishedMeetingIds.formUnion(pending)
        pendingChoiceIds = nil
        refreshStatusAndPower()
    }

    func tick() {
        let referenceDate = now()
        let meetings = source.meetings(
            from: referenceDate.addingTimeInterval(-12 * 3600),
            to: referenceDate.addingTimeInterval(24 * 3600)
        )
        let current = MeetingSchedule.currentAll(in: meetings, at: referenceDate)
        let next = MeetingSchedule.next(in: meetings, after: referenceDate)

        // 음성 메모로 직접 녹음 중이면 Wiret은 끼어들지 않는다. 시작도, 중단도, 겹친 회의 선택도
        // 하지 않는다. 사용자가 직접 시작한 녹음이 우선이다.
        if isExternalRecordingProvider?() == true {
            if pendingChoiceIds != nil {
                clearPendingChoice()
                onChoiceObsolete?()
            }
            updateStatusText(current: current, next: next)
            updatePowerAssertion(current: current, next: next, at: referenceDate)
            return
        }

        let action = AutoRecordPolicy.decide(
            state: currentState(),
            current: current,
            finishedMeetingIds: finishedMeetingIds
        )

        if pendingChoiceIds != nil, !isChoose(action) {
            // The overlap disappeared (a meeting ended, or auto was turned off) — drop the prompt.
            clearPendingChoice()
            onChoiceObsolete?()
        }

        // A start already being processed suppresses new starts and prompts, but a meeting that ended
        // must still stop.
        switch suppressingStartsIfInFlight(action) {
        case .start(let meeting):
            autoMeetingId = meeting.id
            onStart?(meeting)
        case .choose(let candidates):
            presentChoice(candidates)
        case .stop:
            if let autoMeetingId {
                finishedMeetingIds.insert(autoMeetingId)
            }
            autoMeetingId = nil
            onStop?()

            // Back-to-back and overlapping meetings: re-evaluate once more with the refreshed state so a
            // meeting that starts the instant the previous one ends isn't delayed a full tick.
            let followUp = AutoRecordPolicy.decide(
                state: currentState(),
                current: current,
                finishedMeetingIds: finishedMeetingIds
            )
            switch suppressingStartsIfInFlight(followUp) {
            case .start(let meeting):
                self.autoMeetingId = meeting.id
                onStart?(meeting)
            case .choose(let candidates):
                presentChoice(candidates)
            case .stop, .none:
                break
            }
        case .none:
            break
        }

        updateStatusText(current: current, next: next)
        updatePowerAssertion(current: current, next: next, at: referenceDate)
    }

    /// While a start request is being processed, drop starts and prompts (a second one would race the
    /// first) but keep stops.
    private func suppressingStartsIfInFlight(_ action: AutoRecordAction) -> AutoRecordAction {
        guard isStartInFlightProvider?() == true else { return action }
        switch action {
        case .start, .choose:
            return .none
        case .stop, .none:
            return action
        }
    }

    private func currentState() -> AutoRecordState {
        AutoRecordState(
            autoEnabled: isEnabled,
            isRecording: isRecordingProvider?() ?? false,
            autoMeetingId: autoMeetingId
        )
    }

    private func isChoose(_ action: AutoRecordAction) -> Bool {
        if case .choose = action { return true }
        return false
    }

    private func presentChoice(_ candidates: [Meeting]) {
        let ids = Set(candidates.map { $0.id })
        if pendingChoiceIds == ids { return }
        pendingChoiceIds = ids
        onChoose?(candidates)
    }

    private func clearPendingChoice() {
        pendingChoiceIds = nil
    }

    private func refreshStatusAndPower() {
        let referenceDate = now()
        let meetings = source.meetings(
            from: referenceDate.addingTimeInterval(-12 * 3600),
            to: referenceDate.addingTimeInterval(24 * 3600)
        )
        let current = MeetingSchedule.currentAll(in: meetings, at: referenceDate)
        let next = MeetingSchedule.next(in: meetings, after: referenceDate)
        updateStatusText(current: current, next: next)
        updatePowerAssertion(current: current, next: next, at: referenceDate)
    }

    private func updateStatusText(current: [Meeting], next: Meeting?) {
        guard isEnabled else {
            onStatusText?("자동: 꺼짐")
            return
        }

        if isExternalRecordingProvider?() == true {
            onStatusText?("자동: 음성 메모가 녹음 중이라 대기")
            return
        }

        if let pendingChoiceIds {
            onStatusText?("회의 선택 대기 중 (\(pendingChoiceIds.count)개 겹침)")
            return
        }

        if let autoMeetingId,
           let active = current.first(where: { $0.id == autoMeetingId }),
           isRecordingProvider?() ?? false {
            onStatusText?("녹음 중: \(active.title) (~\(Self.timeFormatter.string(from: active.end)))")
            return
        }

        if let next {
            onStatusText?("다음 회의: \(next.title) (\(Self.timeFormatter.string(from: next.start)))")
            return
        }

        onStatusText?("자동: 예정된 회의 없음")
    }

    /// Keep the Mac awake while auto recording, while a meeting is in progress (including one awaiting
    /// the overlap prompt), or while the next meeting is less than `leadTime` away.
    private func updatePowerAssertion(current: [Meeting], next: Meeting?, at referenceDate: Date) {
        let shouldHold: Bool
        if !isEnabled {
            shouldHold = false
        } else if autoMeetingId != nil || pendingChoiceIds != nil || !current.isEmpty {
            shouldHold = true
        } else if let next {
            shouldHold = next.start.timeIntervalSince(referenceDate) <= Self.leadTime
        } else {
            shouldHold = false
        }

        if shouldHold {
            sleepPreventer.activate(reason: Self.assertionReason)
        } else {
            sleepPreventer.release()
        }
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 2
        // .common so meeting starts/stops keep firing while a modal alert or menu tracking loop runs.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
