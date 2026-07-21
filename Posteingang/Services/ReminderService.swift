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
    func create(title: String, dueDate: Date, notes: String, leadDays: Int = 7) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw ReminderServiceError.accessDenied
        }
        guard let reminderCalendar = store.defaultCalendarForNewReminders() else {
            throw ReminderServiceError.noCalendar
        }

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
}
