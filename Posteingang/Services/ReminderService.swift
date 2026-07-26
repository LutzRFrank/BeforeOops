import EventKit
import Foundation

enum ReminderServiceError: LocalizedError {
    case accessDenied
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Der Zugriff auf Erinnerungen wurde nicht erlaubt."
        case .noCalendar: "Es ist keine Liste für neue Erinnerungen verfügbar."
        }
    }
}

struct ReminderService {
    private let calendarTitle = "BeforeOops"

    func create(title: String, dueDate: Date, notes: String, leadDays: Int = 7) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw ReminderServiceError.accessDenied
        }
        let reminderCalendar = try reminderCalendar(in: store)

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = reminderCalendar
        reminder.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day], from: dueDate
        )

        let alertDate = leadDays == 30
            ? Calendar.autoupdatingCurrent.date(byAdding: .month, value: -1, to: dueDate)
            : Calendar.autoupdatingCurrent.date(byAdding: .day, value: -leadDays, to: dueDate)
        if let alertDate {
            reminder.addAlarm(EKAlarm(absoluteDate: alertDate))
        }

        try store.save(reminder, commit: true)
    }

    private func reminderCalendar(in store: EKEventStore) throws -> EKCalendar {
        guard let defaultCalendar = store.defaultCalendarForNewReminders() else {
            throw ReminderServiceError.noCalendar
        }

        let reminderCalendars = store.calendars(for: .reminder)
        if let existingCalendar = reminderCalendars.first(where: {
            $0.title == calendarTitle
                && $0.source.sourceIdentifier == defaultCalendar.source.sourceIdentifier
                && $0.allowsContentModifications
        }) {
            return existingCalendar
        }

        if let existingCalendar = reminderCalendars.first(where: {
            $0.title == calendarTitle && $0.allowsContentModifications
        }) {
            return existingCalendar
        }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = calendarTitle
        calendar.source = defaultCalendar.source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }
}
