import EventKit
import Foundation

protocol MeetingSource: AnyObject {
    var onChange: (() -> Void)? { get set }
    func requestAccess(completion: @escaping (Bool) -> Void)
    func meetings(from: Date, to: Date) -> [Meeting]
    /// 메뉴에 보여줄 전체 캘린더 목록.
    var availableCalendars: [CalendarInfo] { get }
    /// 사용자가 고른 캘린더. 비어 있으면 자동(Google 우선)으로 동작한다.
    var selectedCalendarIDs: Set<String> { get set }
}

final class EventKitMeetingSource: MeetingSource {
    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    var onChange: (() -> Void)?

    /// 비어 있으면 자동으로 Google 캘린더를 고른다. 자세한 규칙은 `CalendarSelection` 참고.
    var selectedCalendarIDs: Set<String> = []

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.onChange?()
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)

        func complete(_ granted: Bool) {
            DispatchQueue.main.async {
                completion(granted)
            }
        }

        switch status {
        case .authorized:
            complete(true)
        case .notDetermined:
            if #available(macOS 14, *) {
                store.requestFullAccessToEvents { granted, _ in
                    complete(granted)
                }
            } else {
                store.requestAccess(to: .event) { granted, _ in
                    complete(granted)
                }
            }
        case .denied, .restricted:
            complete(false)
        default:
            // Covers .fullAccess / .writeOnly (macOS 14+) and any future cases.
            if #available(macOS 14, *) {
                complete(status == .fullAccess)
            } else {
                complete(false)
            }
        }
    }

    static func isGoogleSource(title: String, isCalDAV: Bool) -> Bool {
        let lowercased = title.lowercased()
        if lowercased.contains("google") || lowercased.contains("gmail") {
            return true
        }
        if isCalDAV && title.contains("@") {
            return true
        }
        return false
    }

    private var googleCalendars: [EKCalendar] {
        store.calendars(for: .event).filter { calendar in
            Self.isGoogleSource(title: calendar.source.title, isCalDAV: calendar.source.sourceType == .calDAV)
        }
    }

    var availableCalendars: [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }
    }

    var calendars: [EKCalendar] {
        let all = store.calendars(for: .event)
        let resolved = CalendarSelection.resolve(
            all: all.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title) },
            googleIDs: Set(googleCalendars.map(\.calendarIdentifier)),
            selected: selectedCalendarIDs
        )
        let resolvedIDs = Set(resolved.map(\.id))
        return all.filter { resolvedIDs.contains($0.calendarIdentifier) }
    }

    func meetings(from start: Date, to end: Date) -> [Meeting] {
        let selectedCalendars = calendars
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: selectedCalendars.isEmpty ? nil : selectedCalendars
        )
        let events = store.events(matching: predicate)
        return events.compactMap { event -> Meeting? in
            if event.isAllDay { return nil }
            if event.status == .canceled { return nil }
            if let attendees = event.attendees {
                let declinedByMe = attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
                if declinedByMe { return nil }
            }
            let id = "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)"
            return Meeting(id: id, title: event.title ?? "회의", start: event.startDate, end: event.endDate)
        }
    }
}
