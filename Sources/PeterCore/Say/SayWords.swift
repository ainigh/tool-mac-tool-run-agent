import Foundation

/// The few things Peter says without his model (how a run went, a failure's sentence, a time):
/// never JSON, routes or ids. An answer too long for anyone to read is cut short by a fixed rule.
enum SayWords {
    /// The most an answer says (a page read whole can be long): beyond it, it's cut, and says so.
    static let maxChars = 12_000

    /// An answer no longer than `maxChars`, cut at a line where it can be.
    static func whole(_ text: String, limit: Int = maxChars) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let nl = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: nl) > limit / 2 { cut = String(cut[..<nl]) }
        let left = text.dropFirst(cut.count).split(separator: "\n").count
        return cut + "\n(cut short: \(left) more line\(left == 1 ? "" : "s") weren't said.)"
    }

    /// A message from the API without what's only for programs: routes, JSON bits, field names.
    static func plain(_ message: String) -> String {
        var m = message
        // "(GET /api/scripts lists them)", "(POST /api/run …)": a route in brackets goes.
        m = m.replacingOccurrences(of: #"\s*\([^()]*(/api/|\{\")[^()]*\)"#, with: "", options: .regularExpression)
        // A route or a JSON fragment left in the sentence.
        m = m.replacingOccurrences(of: #"(GET|POST|PUT|DELETE)\s+/api/\S*"#, with: "the API", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\{\"[^}]*\}"#, with: "", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\s+:"#, with: ":", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        m = m.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
        guard let first = m.first else { return message }
        let s = String(first).uppercased() + m.dropFirst()
        return s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") ? s : s + "."
    }

    /// A refusal or a failure: its sentence, and its fix.
    static func failure(_ j: [String: Any]) -> String {
        var out = plain(j["error"] as? String ?? j["message"] as? String ?? "That didn't work.")
        if let fix = j["fix"] as? String, !fix.isEmpty { out += " " + plain(fix) }
        return out
    }

    // MARK: runs and requests

    /// "utilities/nightly-backup.sh" → "nightly backup".
    static func spokenName(_ id: String) -> String {
        ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    /// A run's state, as said.
    static func state(_ s: String) -> String {
        switch s {
        case "running": return "running"
        case "succeeded": return "worked"
        case "failed": return "failed"
        case "stopped": return "stopped"
        case "could_not_start": return "couldn't start"
        default: return s.replacingOccurrences(of: "_", with: " ")
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f
    }()

    /// "9:12", from a date as the API writes it.
    static func time(_ s: String?) -> String? {
        guard let s, let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) else { return nil }
        return clock.string(from: d)
    }

    static func time(_ d: Date) -> String { clock.string(from: d) }
}
