import Foundation

struct DetectedDate: Identifiable {
    let date: Date
    let sourceText: String

    var id: Date { date }
}

struct DetectedDateService {
    func dates(in text: String, relativeTo referenceDate: Date = .now) -> [DetectedDate] {
        guard !text.isEmpty else { return [] }

        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let range = NSRange(text.startIndex..., in: text)
        var datesByDay: [Date: DetectedDate] = [:]
        let numericPattern = #"(?<!\d)([0-3]?\d)[.\-/]([01]?\d)[.\-/](\d{2}|\d{4})(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: numericPattern) else { return [] }

        func store(day: Int, month: Int, parsedYear: Int, source: String) {
            let year = parsedYear < 100
                ? (parsedYear >= 50 ? 1900 + parsedYear : 2000 + parsedYear)
                : parsedYear
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day

            guard let date = calendar.date(from: components),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day,
                  date >= startOfToday else { return }

            let normalizedDate = calendar.startOfDay(for: date)
            datesByDay[normalizedDate] = DetectedDate(date: normalizedDate, sourceText: source)
        }

        expression.enumerateMatches(in: text, range: range) { result, _, _ in
            guard let result,
                  let sourceRange = Range(result.range, in: text),
                  let dayRange = Range(result.range(at: 1), in: text),
                  let monthRange = Range(result.range(at: 2), in: text),
                  let yearRange = Range(result.range(at: 3), in: text),
                  let day = Int(text[dayRange]),
                  let month = Int(text[monthRange]),
                  let parsedYear = Int(text[yearRange])
            else { return }

            store(day: day, month: month, parsedYear: parsedYear, source: String(text[sourceRange]))
        }

        let monthNumbers = [
            "january": 1, "jan": 1, "januar": 1,
            "february": 2, "feb": 2, "februar": 2,
            "march": 3, "mar": 3, "märz": 3, "maerz": 3,
            "april": 4, "apr": 4,
            "may": 5, "mai": 5,
            "june": 6, "jun": 6, "juni": 6,
            "july": 7, "jul": 7, "juli": 7,
            "august": 8, "aug": 8,
            "september": 9, "sep": 9, "sept": 9,
            "october": 10, "oct": 10, "oktober": 10, "okt": 10,
            "november": 11, "nov": 11,
            "december": 12, "dec": 12, "dezember": 12, "dez": 12
        ]
        let monthAlternatives = monthNumbers.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let namedPatterns = [
            #"(?<!\d)([0-3]?\d)(?:st|nd|rd|th)?[.,]?\s+("# + monthAlternatives + #")[.,]?\s+(\d{4})(?!\d)"#,
            #"\b("# + monthAlternatives + #")\s+([0-3]?\d)(?:st|nd|rd|th)?[.,]?\s+(\d{4})(?!\d)"#
        ]
        for (patternIndex, pattern) in namedPatterns.enumerated() {
            guard let namedExpression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            namedExpression.enumerateMatches(in: text, range: range) { result, _, _ in
                guard let result, let sourceRange = Range(result.range, in: text) else { return }
                let dayGroup = patternIndex == 0 ? 1 : 2
                let monthGroup = patternIndex == 0 ? 2 : 1
                guard let dayRange = Range(result.range(at: dayGroup), in: text),
                      let monthRange = Range(result.range(at: monthGroup), in: text),
                      let yearRange = Range(result.range(at: 3), in: text),
                      let day = Int(text[dayRange]), let year = Int(text[yearRange]),
                      let month = monthNumbers[String(text[monthRange]).lowercased()] else { return }
                store(day: day, month: month, parsedYear: year, source: String(text[sourceRange]))
            }
        }

        return datesByDay.values.sorted { $0.date < $1.date }.prefix(8).map { $0 }
    }
}
