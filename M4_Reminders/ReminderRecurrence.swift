import Foundation

/// App 和 Widget 共用日期规则，月末采用夹到当月最后一天的策略。
enum RepeatRule: Codable, Equatable {
    case daily
    case weekly(Set<Int>) // 1=周日 ... 7=周六
    case monthly(day: Int)
    case yearly(month: Int, day: Int)
    case once(at: Date)

    var usesRollingSchedule: Bool {
        switch self { case .monthly, .yearly: return true; default: return false }
    }
    var label: String {
        switch self {
        case .daily: return "每日"
        case .weekly(let days):
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return "每周" + days.sorted().filter { (1...7).contains($0) }.map { names[$0 - 1] }.joined(separator: "、")
        case .monthly(let day): return "每月\(day)日（不足则月底）"
        case .yearly(let month, let day): return "每年\(month)月\(day)日（不足则月底）"
        case .once(let date): return "仅一次 · " + date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

enum AdvanceOption: String, Codable, CaseIterable, Identifiable {
    case none = "准时", m5 = "提前5分钟", m15 = "提前15分钟", m30 = "提前30分钟"
    case h1 = "提前1小时", d1 = "提前1天", d3 = "提前3天"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .none: return 0
        case .m5: return 300; case .m15: return 900; case .m30: return 1800
        case .h1: return 3600; case .d1: return 86400; case .d3: return 259200
        }
    }
    func fireDate(for due: Date, calendar: Calendar) -> Date {
        switch self {
        case .d1, .d3: return calendar.date(byAdding: .day, value: self == .d1 ? -1 : -3, to: due) ?? due
        default: return calendar.date(byAdding: .minute, value: -Int(seconds / 60), to: due) ?? due
        }
    }
}

enum ReminderRecurrence {
    static func validationError(rule: RepeatRule, hour: Int, minute: Int, advance: AdvanceOption) -> String? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return "提醒时间无效" }
        switch rule {
        case .daily: if advance.seconds > 3600 { return "每日提醒最多提前1小时" }
        case .weekly(let days): if days.isEmpty || !days.allSatisfy({ (1...7).contains($0) }) { return "每周至少选择一天" }
        case .monthly(let day): if !(1...31).contains(day) { return "每月日期无效" }
        case .yearly(let month, let day):
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
            guard (1...12).contains(month), let first = cal.date(from: DateComponents(year: 2000, month: month, day: 1)),
                  let days = cal.range(of: .day, in: .month, for: first), days.contains(day) else { return "所选月份不存在该日期" }
        case .once: break
        }
        return nil
    }

    static func occurs(rule: RepeatRule, on date: Date, calendar: Calendar) -> Bool {
        let day = calendar.component(.day, from: date)
        let last = calendar.range(of: .day, in: .month, for: date)?.count ?? 31
        switch rule {
        case .daily: return true
        case .weekly(let days): return days.contains(calendar.component(.weekday, from: date))
        case .monthly(let requested): return day == min(requested, last)
        case .yearly(let month, let requested): return calendar.component(.month, from: date) == month && day == min(requested, last)
        case .once(let due): return calendar.isDate(due, inSameDayAs: date)
        }
    }

    /// 使用日历日偏移，保持夏令时前后的当地钟点；重复的秋季钟点取第一次。
    static func dates(rule: RepeatRule, hour: Int, minute: Int, after start: Date, through end: Date,
                      calendar: Calendar = .current) -> [Date] {
        guard validationError(rule: rule, hour: hour, minute: minute, advance: .none) == nil else { return [] }
        if case .once(let due) = rule { return due > start && due <= end ? [due] : [] }
        var day = calendar.startOfDay(for: start)
        switch rule {
        case .monthly: day = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? day
        case .yearly: day = calendar.date(from: calendar.dateComponents([.year], from: start)) ?? day
        default: break
        }
        var result: [Date] = []
        while day <= end {
            let occurrenceDay: Date?
            let stride: Calendar.Component
            switch rule {
            case .monthly(let requested):
                let last = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
                occurrenceDay = calendar.date(byAdding: .day, value: min(requested, last) - 1, to: day); stride = .month
            case .yearly(let month, let requested):
                let first = calendar.date(from: DateComponents(year: calendar.component(.year, from: day), month: month, day: 1))
                occurrenceDay = first.flatMap { first in calendar.date(byAdding: .day, value: min(requested, calendar.range(of: .day, in: .month, for: first)?.count ?? 31) - 1, to: first) }
                stride = .year
            default: occurrenceDay = occurs(rule: rule, on: day, calendar: calendar) ? day : nil; stride = .day
            }
            if let occurrenceDay,
               let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: occurrenceDay,
                                       matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first),
               due > start, due <= end { result.append(due) }
            guard let next = calendar.date(byAdding: stride, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
}
