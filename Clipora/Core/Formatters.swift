import Foundation

enum RelativeTime {

    /// 「7 天以上」走绝对日期分支，DateFormatter 构造昂贵，缓存复用（配置后只读，线程安全）。
    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    /// 刚刚 / N分钟前 / N小时前 / 昨天 / N天前 / yyyy/MM/dd
    static func string(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return L("刚刚", "Just now") }
        if interval < 3600 {
            let m = Int(interval / 60)
            return L("\(m)分钟前", "\(m) min ago")
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let h = Int(interval / 3600)
            return L("\(h)小时前", "\(h) hr ago")
        }
        if calendar.isDateInYesterday(date) {
            return L("昨天", "Yesterday")
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 { return L("\(days)天前", "\(days) days ago") }

        return absoluteDateFormatter.string(from: date)
    }
}
