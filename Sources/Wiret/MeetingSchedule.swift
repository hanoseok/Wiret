import Foundation

struct Meeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}

enum MeetingSchedule {
    /// Meeting currently in progress at `now` (start <= now < end). If several overlap, pick the one
    /// that started latest; tie -> earliest end.
    static func current(in meetings: [Meeting], at now: Date) -> Meeting? {
        let inProgress = meetings.filter { $0.start <= now && now < $0.end }
        return inProgress.reduce(nil) { (best: Meeting?, candidate: Meeting) -> Meeting? in
            guard let best else { return candidate }
            if candidate.start > best.start { return candidate }
            if candidate.start == best.start && candidate.end < best.end { return candidate }
            return best
        }
    }

    /// Next meeting starting after `now` (earliest start).
    static func next(in meetings: [Meeting], after now: Date) -> Meeting? {
        let future = meetings.filter { $0.start > now }
        return future.reduce(nil) { (best: Meeting?, candidate: Meeting) -> Meeting? in
            guard let best else { return candidate }
            return candidate.start < best.start ? candidate : best
        }
    }
}

enum AutoRecordAction: Equatable {
    case none
    case start(Meeting)
    case stop
}

struct AutoRecordState: Equatable {
    var autoEnabled: Bool
    var isRecording: Bool
    var autoMeetingId: String?
}

enum AutoRecordPolicy {
    /// Decide what to do at `now`.
    /// - auto disabled: if autoMeetingId != nil && isRecording -> .stop (turning auto off ends an auto recording), else .none
    /// - not recording: if current meeting exists -> .start(meeting) unless that meeting id equals `lastFinishedAutoMeetingId`
    ///   (don't restart a meeting we already auto-stopped, e.g. user manually stopped early) -> .none
    /// - recording manually (autoMeetingId == nil): .none (never interfere with manual recordings)
    /// - recording auto (autoMeetingId != nil): if current meeting?.id != autoMeetingId -> .stop (next tick will start the new one)
    static func decide(state: AutoRecordState, current: Meeting?, lastFinishedAutoMeetingId: String?) -> AutoRecordAction {
        if !state.autoEnabled {
            if state.autoMeetingId != nil && state.isRecording {
                return .stop
            }
            return .none
        }

        if !state.isRecording {
            if let current, current.id != lastFinishedAutoMeetingId {
                return .start(current)
            }
            return .none
        }

        guard let autoMeetingId = state.autoMeetingId else {
            return .none
        }

        if current?.id != autoMeetingId {
            return .stop
        }
        return .none
    }
}
