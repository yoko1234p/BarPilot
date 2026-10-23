import AppKit
import BarPilotCore
import Combine
import EventKit

struct ProCalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendar: String
    let meetingURL: URL?
}

@MainActor
final class CalendarWidgetService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var events: [ProCalendarEvent] = []
    @Published private(set) var status = "未啟用"
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    var nextEvent: ProCalendarEvent? { events.first { !$0.allDay && $0.end > Date() } }
    func setEnabled(_ value: Bool, requestPermission: Bool = false) {
        enabled = value; timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard value else { events = []; store = nil; status = "未啟用"; return }
        store = EKEventStore()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if requestPermission { connect() } else { refresh() }
    }
    func connect() {
        guard enabled, let store else { return }
        Task { @MainActor in
            do {
                let granted = try await store.requestFullAccessToEvents()
                guard enabled else { return }
                status = granted ? "已連接日曆" : "日曆權限未允許"
                // Reload immediately after approval rather than waiting for the next store-change event.
                refresh()
            } catch { status = error.localizedDescription }
        }
    }
    func refresh() {
        guard enabled, let store else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []; status = "請按「連接日曆」授權完整讀取。"; return
        }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = now.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }.prefix(40).map {
                ProCalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "無標題",
                    start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, calendar: $0.calendar.title,
                    meetingURL: MeetingLink.first(in: [$0.url?.absoluteString ?? "", $0.location ?? "", $0.notes ?? ""]))
            }
        status = events.isEmpty ? "未來 24 小時沒有行程" : "已連接日曆"
    }
    func join(_ event: ProCalendarEvent) { if let url = event.meetingURL { NSWorkspace.shared.open(url) } }
    func openCalendar() { NSWorkspace.shared.open(URL(string: "ical://")!) }
}
