import Foundation

/// App 与 Widget 共用重复规则，快照保留规则而非仅保留某一天的结果。
enum RepeatRule: Codable, Equatable {
    case daily
    case weekly(Set<Int>)               // 1=周日 ... 7=周六
    case monthly(day: Int)
    case yearly(month: Int, day: Int)

    func fires(on date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .daily: return true
        case .weekly(let days): return days.contains(calendar.component(.weekday, from: date))
        case .monthly(let day): return calendar.component(.day, from: date) == day
        case .yearly(let month, let day):
            return calendar.component(.month, from: date) == month
                && calendar.component(.day, from: date) == day
        }
    }

    var isValid: Bool {
        switch self {
        case .daily: return true
        case .weekly(let days): return !days.isEmpty && days.allSatisfy { (1...7).contains($0) }
        case .monthly(let day): return (1...31).contains(day)
        case .yearly(let month, let day):
            let maximumDays = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            return (1...12).contains(month) && (1...maximumDays[month - 1]).contains(day)
        }
    }

    func matchingComponents(hour: Int, minute: Int) -> [DateComponents] {
        guard isValid, (0...23).contains(hour), (0...59).contains(minute) else { return [] }
        let base = DateComponents(hour: hour, minute: minute, second: 0)
        switch self {
        case .daily: return [base]
        case .weekly(let days):
            return days.sorted().map { var d = base; d.weekday = $0; return d }
        case .monthly(let day):
            var d = base; d.day = day; return [d]
        case .yearly(let month, let day):
            var d = base; d.month = month; d.day = day; return [d]
        }
    }
}

enum ReminderOccurrenceBuilder {
    /// 严格匹配：31 日跳过短月、2 月 29 日跳过平年，不把不存在的日期移到别的一天。
    static func dates(rule: RepeatRule, hour: Int, minute: Int, after now: Date,
                      count: Int, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        var dates: [Date] = []
        for components in rule.matchingComponents(hour: hour, minute: minute) {
            var cursor = now
            for _ in 0..<count {
                guard let next = calendar.nextDate(after: cursor, matching: components,
                                                  matchingPolicy: .strict,
                                                  repeatedTimePolicy: .first), next > cursor else { break }
                dates.append(next)
                cursor = next
            }
        }
        return Array(Set(dates).sorted().prefix(count))
    }

    static func time(hour: Int, minute: Int, on day: Date,
                     calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = calendar.dateComponents([.era, .year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0
        return calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
                                 matching: components, matchingPolicy: .strict,
                                 repeatedTimePolicy: .first)
    }
}
