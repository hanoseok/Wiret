import Foundation

struct Meeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}

enum MeetingSchedule {
    /// Every meeting in progress at `now` (start <= now < end), latest start first; tie -> earliest end.
    static func currentAll(in meetings: [Meeting], at now: Date) -> [Meeting] {
        meetings
            .filter { $0.start <= now && now < $0.end }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start > rhs.start }
                return lhs.end < rhs.end
            }
    }

    /// Meeting currently in progress at `now` (start <= now < end). If several overlap, pick the one
    /// that started latest; tie -> earliest end.
    static func current(in meetings: [Meeting], at now: Date) -> Meeting? {
        currentAll(in: meetings, at: now).first
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
    case choose([Meeting])
}

struct AutoRecordState: Equatable {
    var autoEnabled: Bool
    var isRecording: Bool
    var autoMeetingId: String?
}

enum AutoRecordPolicy {
    /// Decide what to do given every meeting in progress right now.
    /// - auto disabled: if autoMeetingId != nil && isRecording -> .stop (turning auto off ends an auto recording), else .none
    /// - recording manually (autoMeetingId == nil): .none (never interfere with manual recordings)
    /// - recording auto (autoMeetingId != nil): .none while that meeting is still in progress, else .stop.
    ///   An overlapping meeting starting does not interrupt the running one.
    /// - idle: meetings already handled (`finishedMeetingIds`) are skipped; one candidate -> .start,
    ///   several -> .choose (ask the user which one to record).
    static func decide(
        state: AutoRecordState,
        current: [Meeting],
        finishedMeetingIds: Set<String>
    ) -> AutoRecordAction {
        if !state.autoEnabled {
            if state.autoMeetingId != nil && state.isRecording {
                return .stop
            }
            return .none
        }

        if state.isRecording && state.autoMeetingId == nil {
            return .none
        }

        if let autoMeetingId = state.autoMeetingId {
            return current.contains { $0.id == autoMeetingId } ? .none : .stop
        }

        let candidates = current.filter { !finishedMeetingIds.contains($0.id) }
        if candidates.isEmpty {
            return .none
        }
        if candidates.count == 1 {
            return .start(candidates[0])
        }
        return .choose(candidates)
    }
}
