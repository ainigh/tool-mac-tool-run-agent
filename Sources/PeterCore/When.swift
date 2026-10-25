import Foundation

/// When something is due, from how a person (or a model) says it: "in 20 minutes", "in 2 hours",
/// "at 17:30", "5:30 pm", "tomorrow 9am", "friday 8:00", "24 October 17:30", "2026-10-24 17:30",
/// "noon". A time of day alone is today, or tomorrow once it has passed; a weekday alone is the
/// next one (at 9:00 when no time is said). And how often it comes again ("every day", "every
/// weekday", "every 30 minutes"), and the words for a moment ("tomorrow at 08:00", "in 45 minutes").
public enum When {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The moment some words mean, or nil when they aren't a time.
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var s = input.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        guard !s.isEmpty else { return nil }
        if s == "now" || s == "right now" { return now }
        // "in 20 minutes", "in an hour", "20 min", "in 1.5 hours", "in 2 days".
        if let m = match(#"^(?:in |after )?(an?|\d+(?:\.\d+)?) ?(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?)(?: from now)?$"#, s) {
            let n = m[1] == "a" || m[1] == "an" ? 1 : Double(m[1]) ?? 0
            let unit: Double
            switch m[2].first {
            case "s": unit = 1
            case "m": unit = 60
            case "h": unit = 3600
            case "w": unit = 7 * 86400
            default: unit = 86400
            }
            return now.addingTimeInterval(n * unit)
        }
        // "in 1 hour 30 minutes", "in 1h30".
        if let m = match(#"^in (\d+) ?(?:hours?|hrs?|h) (?:and )?(\d+) ?(?:minutes?|mins?|m)?$"#, s) {
            return now.addingTimeInterval(Double(Int(m[1])! * 3600 + Int(m[2])! * 60))
        }
        // ISO with an offset or Z: exactly that moment.
        if match(#"^\d{4}-\d{2}-\d{2}t\d{2}:\d{2}(:\d{2}(\.\d+)?)?(z|[+-]\d{2}:?\d{2})$"#, s) != nil {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s.uppercased()) ?? { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s.uppercased()) }()
        }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var date: (y: Int, m: Int, d: Int)?
        var explicitYear = false
        var weekday: Int?
        func take(_ pattern: String, _ body: ([String]) -> Void) -> Bool {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let hit = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return false }
            let groups = (0..<hit.numberOfRanges).map { k in Range(hit.range(at: k), in: s).map { String(s[$0]) } ?? "" }
            body(groups)
            let r = Range(hit.range, in: s)!
            s = (String(s[..<r.lowerBound]) + " " + String(s[r.upperBound...])).trimmingCharacters(in: .whitespaces)
            return true
        }
        let mon = months.map { String($0.prefix(3)) }.joined(separator: "|")
        _ = take(#"\b(\d{4})-(\d{1,2})-(\d{1,2})(?=t|\b)"#) { g in date = (Int(g[1])!, Int(g[2])!, Int(g[3])!); explicitYear = true }
        if date == nil { _ = take(#"\b(today|tonight)\b"#) { g in
            date = (today.year!, today.month!, today.day!)
            if g[1] == "tonight" { s += " evening" }
        } }
        if date == nil { _ = take(#"\btomorrow\b"#) { _ in
            let t = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: now)!)
            date = (t.year!, t.month!, t.day!)
            explicitYear = true
        } }
        if date == nil { _ = take(#"\b(\d{1,2})(?:st|nd|rd|th)? (?:of )?(\#(mon))[a-z]*\.?(?: (\d{4}))?\b"#) { g in
            date = (g[3].isEmpty ? today.year! : Int(g[3])!, months.firstIndex { $0.hasPrefix(g[2]) }! + 1, Int(g[1])!)
            explicitYear = !g[3].isEmpty
        } }
        if date == nil { _ = take(#"\b(\#(mon))[a-z]*\.? (\d{1,2})(?:st|nd|rd|th)?(?:,? (\d{4}))?\b"#) { g in
            date = (g[3].isEmpty ? today.year! : Int(g[3])!, months.firstIndex { $0.hasPrefix(g[1]) }! + 1, Int(g[2])!)
            explicitYear = !g[3].isEmpty
        } }
        if date == nil {
            let day = days.map { String($0.prefix(3)) }.joined(separator: "|")
            _ = take(#"\b(?:next |this |on )?(\#(day))[a-z]*\b"#) { g in weekday = days.firstIndex { $0.hasPrefix(g[1]) }! + 1 }
        }
        var time: (h: Int, m: Int, s: Int)?
        s = s.replacingOccurrences(of: #"^t"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(at|on|by)\b"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        _ = take(#"\b(\d{1,2})(?::(\d{2}))?(?::(\d{2}))? ?(a\.?m\.?|p\.?m\.?)(?=\s|$)"#) { g in
            var hour = Int(g[1])! % 12
            if g[4].hasPrefix("p") { hour += 12 }
            time = (hour, Int(g[2]) ?? 0, Int(g[3]) ?? 0)
        }
        if time == nil { _ = take(#"\b(\d{1,2})[:.h](\d{2})(?::(\d{2})(?:\.\d+)?)?\b"#) { g in time = (Int(g[1])!, Int(g[2])!, Int(g[3]) ?? 0) } }
        if time == nil { _ = take(#"\b(noon|midday)\b"#) { _ in time = (12, 0, 0) } }
        if time == nil { _ = take(#"\bmidnight\b"#) { _ in time = (0, 0, 0) } }
        if time == nil { _ = take(#"\bmorning\b"#) { _ in time = (9, 0, 0) } }
        if time == nil { _ = take(#"\bafternoon\b"#) { _ in time = (15, 0, 0) } }
        if time == nil { _ = take(#"\bevening\b"#) { _ in time = (19, 0, 0) } }
        if time == nil, date != nil || weekday != nil { _ = take(#"^(\d{1,2})$"#) { g in time = (Int(g[1])!, 0, 0) } }
        // Anything left that isn't a time: not understood.
        guard s.replacingOccurrences(of: #"[,. ]|\bthe\b|\bin\b"#, with: "", options: .regularExpression).isEmpty else { return nil }
        guard date != nil || weekday != nil || time != nil else { return nil }
        let t = time ?? (9, 0, 0)
        guard t.h < 24, t.m < 60, t.s < 60 else { return nil }
        if let weekday {
            var c = calendar.dateComponents([.year, .month, .day], from: now)
            c.hour = t.h; c.minute = t.m; c.second = t.s
            guard var d = calendar.date(from: c) else { return nil }
            let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
            d = calendar.date(byAdding: .day, value: ahead, to: d)!
            if d <= now { d = calendar.date(byAdding: .day, value: 7, to: d)! }
            return d
        }
        if let date {
            let c = DateComponents(year: date.y, month: date.m, day: date.d, hour: t.h, minute: t.m, second: t.s)
            guard var d = calendar.date(from: c), calendar.component(.day, from: d) == date.d else { return nil }
            if !explicitYear, d < now.addingTimeInterval(-60) { d = calendar.date(byAdding: .year, value: 1, to: d)! }
            return d
        }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = t.h; c.minute = t.m; c.second = t.s
        guard var d = calendar.date(from: c) else { return nil }
        if d <= now.addingTimeInterval(-30) { d = calendar.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let hit = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<hit.numberOfRanges).map { k in Range(hit.range(at: k), in: s).map { String(s[$0]) } ?? "" }
    }

    /// How often something comes again.
    public enum Repeat: Codable, Equatable, Sendable {
        /// Every so many seconds, from when it was first due.
        case every(TimeInterval)
        /// Every day at the time it was first due.
        case daily
        /// Monday to Friday, at the time it was first due.
        case weekdays
        /// Every week, on the day and at the time it was first due.
        case weekly
        /// Every month, on the day and at the time it was first due.
        case monthly

        /// The choices a template offers.
        public static let choices = ["every day", "every weekday", "every week", "every month", "every hour", "every 30 minutes"]

        /// "every day", "daily", "every 15 minutes", "hourly", "every weekday", "weekly"…
        public static func parse(_ input: String) -> Repeat? {
            let s = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            switch s {
            case "", "once", "no", "none", "never", "not", "one time": return nil
            case "every day", "daily", "each day", "every morning", "every evening", "every night", "every afternoon": return .daily
            case "every weekday", "weekdays", "every work day", "every workday", "on weekdays", "monday to friday": return .weekdays
            case "every week", "weekly", "each week": return .weekly
            case "every month", "monthly", "each month": return .monthly
            case "every hour", "hourly", "each hour": return .every(3600)
            case "every minute": return .every(60)
            default: break
            }
            if let m = match(#"^every (\d+) ?(minutes?|mins?|hours?|hrs?|days?)$"#, s), let n = Double(m[1]), n > 0 {
                let unit: Double = m[2].hasPrefix("m") ? 60 : m[2].hasPrefix("h") ? 3600 : 86400
                return .every(max(60, n * unit))
            }
            return nil
        }

        /// As it's said: "every day", "every 30 minutes".
        public var said: String {
            switch self {
            case let .every(s):
                if s.truncatingRemainder(dividingBy: 86400) == 0 { let n = Int(s / 86400); return n == 1 ? "every day" : "every \(n) days" }
                if s.truncatingRemainder(dividingBy: 3600) == 0 { let n = Int(s / 3600); return n == 1 ? "every hour" : "every \(n) hours" }
                let n = Int(s / 60); return n == 1 ? "every minute" : "every \(n) minutes"
            case .daily: return "every day"
            case .weekdays: return "every weekday"
            case .weekly: return "every week"
            case .monthly: return "every month"
            }
        }

        /// The next time after `last` (and after `now`).
        public func next(after last: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
            var d = last
            repeat {
                switch self {
                case let .every(s): d = d.addingTimeInterval(s)
                case .daily: d = calendar.date(byAdding: .day, value: 1, to: d)!
                case .weekdays:
                    repeat { d = calendar.date(byAdding: .day, value: 1, to: d)! } while [1, 7].contains(calendar.component(.weekday, from: d))
                case .weekly: d = calendar.date(byAdding: .day, value: 7, to: d)!
                case .monthly: d = calendar.date(byAdding: .month, value: 1, to: d)!
                }
            } while d <= now
            return d
        }
    }

    /// "today at 17:30", "tomorrow at 08:00", "Friday 24 October at 17:30".
    public static func long(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
        let time = String(format: "%02d:%02d", c.hour!, c.minute!)
        if calendar.isDate(d, inSameDayAs: now) { return "today at \(time)" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return "tomorrow at \(time)" }
        let year = calendar.component(.year, from: now) == c.year! ? "" : " \(c.year!)"
        return "\(days[c.weekday! - 1].capitalized) \(c.day!) \(months[c.month! - 1].capitalized)\(year) at \(time)"
    }

    /// "in 45 minutes", "in 2 hours and 5 minutes", "in 3 days".
    public static func fromNow(_ d: Date, now: Date = Date()) -> String {
        let min = Int((d.timeIntervalSince(now) / 60).rounded())
        if min <= 0 { return "now" }
        if min < 60 { return "in \(min) minute\(min == 1 ? "" : "s")" }
        let h = min / 60, m = min % 60
        if h < 48 { return "in \(h) hour\(h == 1 ? "" : "s")" + (m > 0 ? " and \(m) minute\(m == 1 ? "" : "s")" : "") }
        return "in \(Int((Double(h) / 24).rounded())) days"
    }
}

/// Something for later, said in a sentence, read without a model: "remind me in 20 minutes to call
/// Sam", "remind me at 5pm: the oven", "remind me to stretch in an hour", "every weekday at 8am,
/// search the web for the traffic", "every morning: remind me to drink water", "tomorrow at 9,
/// run the backup". The time is whatever part of it reads as one (`When.parse`), so a message
/// with "to" or "at" in it stays whole.
public struct LaterWords: Equatable, Sendable {
    public enum Kind: String, Sendable { case remind, later }
    public var kind: Kind
    public var when: String
    public var repeats: When.Repeat?
    public var text: String

    public static func read(_ said: String, now: Date = Date()) -> LaterWords? {
        let s = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains("\n") else { return nil }
        let lower = s.lowercased()
        // "every weekday at 8am, …", "every day: …", "each morning, …"
        if let m = When.match(#"^((?:every|each)\s+[^,:]+?)(?:\s+at\s+([^,:]+?))?\s*[,:]\s*(.+)$"#, s),
           let r = When.Repeat.parse(m[1].lowercased().replacingOccurrences(of: "each", with: "every")) ?? morningRepeat(m[1]) {
            let when = m[2].isEmpty ? defaultTime(m[1]) : m[2]
            guard When.parse(when, now: now) != nil else { return nil }
            var rest = m[3].trimmingCharacters(in: .whitespaces)
            if let reminder = remindRest(rest) { rest = reminder; return LaterWords(kind: .remind, when: when, repeats: r, text: rest) }
            return LaterWords(kind: .later, when: when, repeats: r, text: rest)
        }
        // "remind me …"
        if lower.hasPrefix("remind me ") {
            let rest = String(s.dropFirst("remind me ".count))
            // the time first: "in 20 minutes to …", "at 5pm: …", "tomorrow at 9 that …"
            for sep in [" to ", ": ", ", ", " that ", " about "] {
                var from = rest.startIndex
                while let r = rest.range(of: sep, options: .caseInsensitive, range: from..<rest.endIndex) {
                    let left = String(rest[..<r.lowerBound]), right = String(rest[r.upperBound...])
                    if When.parse(left, now: now) != nil, !right.trimmingCharacters(in: .whitespaces).isEmpty {
                        return LaterWords(kind: .remind, when: left, repeats: nil, text: right.trimmingCharacters(in: .whitespaces))
                    }
                    from = r.upperBound
                }
            }
            // the time last: "to stretch in an hour", "to call Sam at 5pm"
            let what = rest.replacingOccurrences(of: #"^(to|that|about)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            if let (text, when) = timeAtEnd(what, now: now) {
                return LaterWords(kind: .remind, when: when, repeats: nil, text: text)
            }
            return nil
        }
        // "in 2 hours, …", "at 5pm: …", "tomorrow at 9, …"
        // (a clock time or "in …": "tomorrow, what's the weather" is a question about tomorrow, not for later)
        if let m = When.match(#"^([^,:]+?)\s*[,:]\s*(.+)$"#, s), When.parse(m[1], now: now) != nil,
           !(m[1].lowercased().hasPrefix("every")), m[1].range(of: #"\d|^in "#, options: [.regularExpression, .caseInsensitive]) != nil {
            let rest = m[2].trimmingCharacters(in: .whitespaces)
            if let reminder = remindRest(rest) { return LaterWords(kind: .remind, when: m[1], repeats: nil, text: reminder) }
            return LaterWords(kind: .later, when: m[1], repeats: nil, text: rest)
        }
        return nil
    }

    /// "remind me to drink water" → "drink water" (nil: it isn't a reminder).
    static func remindRest(_ s: String) -> String? {
        guard let m = When.match(#"^(?:remind me|tell me)\s+(?:to\s+|that\s+|about\s+)?(.+)$"#, s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return m[1]
    }

    /// The longest end of the words that reads as a time: "stretch in an hour" → ("stretch", "in an hour").
    static func timeAtEnd(_ s: String, now: Date) -> (String, String)? {
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2 else { return nil }
        for k in 1..<words.count {
            let when = words[k...].joined(separator: " ")
            if When.parse(when, now: now) != nil {
                let text = words[..<k].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                return text.isEmpty ? nil : (text, when)
            }
        }
        return nil
    }

    /// "every morning", "every evening", "every night": every day, at that part of it.
    static func morningRepeat(_ s: String) -> When.Repeat? {
        ["morning", "afternoon", "evening", "night"].contains { s.lowercased().hasSuffix($0) } ? .daily : nil
    }

    /// The time a repeat with none said starts at: 7:00 for the morning, 19:00 the evening, else 9:00.
    static func defaultTime(_ s: String) -> String {
        let l = s.lowercased()
        if l.hasSuffix("morning") { return "7:00" }
        if l.hasSuffix("afternoon") { return "13:00" }
        if l.hasSuffix("evening") || l.hasSuffix("night") { return "19:00" }
        if l.contains("hour") || l.contains("minute") { return "in 1 minute" }
        return "9:00"
    }
}
