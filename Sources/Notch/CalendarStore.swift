import SwiftUI
import EventKit

/// Reads the user's real macOS Calendar events via EventKit. Access is
/// requested once, the first time the calendar widget is shown.
@MainActor
final class CalendarStore: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let start: Date
        let allDay: Bool
        let color: Color
    }

    @Published var todaysEvents: [Item] = []
    @Published var eventDays: Set<Int> = []      // day-of-month numbers with events (this month)
    @Published var granted = false

    private let store = EKEventStore()
    private var requested = false

    func loadIfNeeded() {
        guard !requested else { return }
        requested = true
        let handler: (Bool, Error?) -> Void = { [weak self] ok, _ in
            Task { @MainActor in
                self?.granted = ok
                if ok { self?.fetch() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    func fetch() {
        let cal = Calendar.current
        let now = Date()

        // Today's timed events (upcoming first).
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let dayPred = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        todaysEvents = store.events(matching: dayPred)
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
            .map { Item(title: $0.title ?? "Event", start: $0.startDate, allDay: $0.isAllDay,
                        color: color(for: $0)) }

        // Which days this month have any event (for the grid dots).
        if let range = cal.range(of: .day, in: .month, for: now),
           let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) {
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
            let mPred = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
            var days = Set<Int>()
            for ev in store.events(matching: mPred) {
                days.insert(cal.component(.day, from: ev.startDate))
            }
            eventDays = days.intersection(Set(range))
        }
    }

    private func color(for ev: EKEvent) -> Color {
        if let cg = ev.calendar?.cgColor { return Color(cgColor: cg) }
        return Color(red: 0.9, green: 0.3, blue: 0.25)
    }
}
