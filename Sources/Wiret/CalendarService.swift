import EventKit
import Foundation

protocol MeetingSource: AnyObject {
    var onChange: (() -> Void)? { get set }
    func requestAccess(completion: @escaping (Bool) -> Void)
    func meetings(from: Date, to: Date) -> [Meeting]
}

final class EventKitMeetingSource: MeetingSource {
    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    var onChange: (() -> Void)?

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

    var calendars: [EKCalendar] {
        let google = googleCalendars
        return google.isEmpty ? store.calendars(for: .event) : google
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
