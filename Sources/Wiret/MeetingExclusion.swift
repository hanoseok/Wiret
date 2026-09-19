import Foundation

/// 오늘 일정 화면에 보여줄 회의를 고르는 규칙.
enum TodaySchedule {
    /// `date`와 같은 날에 시작하는 회의를 시작 시각 순으로 돌려준다.
    static func meetings(
        in meetings: [Meeting],
        on date: Date,
        calendar: Calendar = .current
    ) -> [Meeting] {
        meetings
            .filter { calendar.isDate($0.start, inSameDayAs: date) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
    }
}

/// 자동 녹음에서 빼 둔 회의를 기억한다.
///
/// 기본값은 "모두 포함"이다. 사용자가 뺀 것만 저장하므로, 새로 생긴 회의는 따로 손대지 않아도
/// 자동 녹음 대상이 된다.
///
/// 회의 식별자에는 시작 시각이 섞여 있어 같은 반복 일정이라도 회차마다 다르다. 그대로 두면
/// 기록이 무한히 쌓이므로 시작 시각을 함께 저장해 지난 것은 지운다.
final class MeetingExclusionStore {
    private static let key = "excludedMeetingIDs"
    /// 지난 회의 기록을 얼마나 남겨 둘지. 시계가 조금 어긋나도 오늘 것이 지워지지 않을 만큼 넉넉히 둔다.
    private static let retention: TimeInterval = 2 * 24 * 3600

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 제외한 회의 식별자 → 회의 시작 시각(epoch).
    private var storage: [String: Double] {
        get { defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    var excludedIDs: Set<String> {
        Set(storage.keys)
    }

    func isExcluded(_ meeting: Meeting) -> Bool {
        storage[meeting.id] != nil
    }

    func setExcluded(_ excluded: Bool, meeting: Meeting) {
        var current = storage
        if excluded {
            current[meeting.id] = meeting.start.timeIntervalSince1970
        } else {
            current.removeValue(forKey: meeting.id)
        }
        storage = current
    }

    /// 보관 기간이 지난 기록을 지운다.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        let kept = storage.filter { $0.value >= cutoff }
        if kept.count != storage.count {
            storage = kept
        }
    }
}
