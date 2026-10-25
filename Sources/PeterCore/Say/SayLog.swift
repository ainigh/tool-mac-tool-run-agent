import Foundation

/// What Peter keeps for each client: the requests it made in words (what, when, how each is
/// going, the system's id for it, whether its result was shown), so he can follow a run, tell the
/// client the moment it's over, and answer "what happened to …". Not a conversation: nothing
/// said before changes how a request is read (but which templates a client uses, offered first).
/// The log keeps a week, at most 200 requests a client; the latest 100 clients are kept. All of
/// it lasts while the app runs.
public actor SayLog {
    public enum State: Sendable, Equatable {
        /// Answered at once (a read).
        case answered
        /// Done at once (something changed).
        case done
        /// It couldn't be done: why.
        case failed(String)
        /// On the Mac, waiting for Run (or Allow).
        case waiting
        case running
        /// Over: whether it worked, its exit code.
        case finished(ok: Bool, code: Int?)
        case denied
        case notAnswered
        case withdrawn
        case couldNotStart(String)
        /// Stopped before it ended.
        case stopped

        /// Still going (waiting for the click, or running).
        public var open: Bool { self == .waiting || self == .running }

        /// A word for it, as it's told: "worked", "waiting for Run on the Mac".
        public var key: String {
            switch self {
            case .answered: "answered"
            case .done: "done"
            case .failed: "failed"
            case .waiting: "waiting"
            case .running: "running"
            case let .finished(ok, _): ok ? "worked" : "failed"
            case .denied: "denied"
            case .notAnswered: "not_answered"
            case .withdrawn: "withdrawn"
            case .couldNotStart: "could_not_start"
            case .stopped: "stopped"
            }
        }
    }

    public struct Entry: Sendable {
        public let number: Int
        public let asked: Date
        /// What the client said (its first line).
        public let said: String
        /// The template it filled.
        public let form: String
        /// What it asked for, in words: "the weather in Lagos", "remember something: Lagos trip".
        public var what: String
        /// How it's referred to: "the nightly backup".
        public var short: String
        /// The system's id for it, while there's something to follow (a run asked for).
        public var request: UUID?
        public var state: State
        /// The result in full, once there's one.
        public var result: String?
        /// The result was shown in full.
        public var shown = false
        /// The state last told in the news (each change is told once).
        public var told: String?
        /// "I'm done with it": no more news about it.
        public var muted = false
        public var ended: Date?
        /// It waits for the person at the Mac (a run, a tag to run by itself).
        public var asks = false

        /// Words it's found by when the client refers to it.
        var words: Set<String> { Set(APISearch.query(what + " " + short + " " + form + " " + said)) }

        /// As it's kept in Storage Spaces.
        var json: [String: Any] {
            var out: [String: Any] = ["number": number, "asked": JSON.date(asked), "said": said, "form": form, "what": what, "short": short,
                                      "state": state.key, "shown": shown, "muted": muted, "asks": asks]
            switch state {
            case let .failed(why), let .couldNotStart(why): out["why"] = why
            case let .finished(ok, code):
                out["ok"] = ok
                if let code { out["code"] = code }
            default: break
            }
            out["state_kind"] = Self.kind(state)
            if let request { out["request"] = request.uuidString }
            if let result { out["result"] = result.count > 20000 ? String(result.suffix(20000)) : result }
            if let told { out["told"] = told }
            if let ended { out["ended"] = JSON.date(ended) }
            return out
        }

        static func kind(_ s: State) -> String {
            switch s {
            case .answered: "answered"
            case .done: "done"
            case .failed: "failed"
            case .waiting: "waiting"
            case .running: "running"
            case .finished: "finished"
            case .denied: "denied"
            case .notAnswered: "not_answered"
            case .withdrawn: "withdrawn"
            case .couldNotStart: "could_not_start"
            case .stopped: "stopped"
            }
        }

        init(number: Int, asked: Date, said: String, form: String, what: String, short: String, request: UUID?, state: State, result: String?) {
            self.number = number
            self.asked = asked
            self.said = said
            self.form = form
            self.what = what
            self.short = short
            self.request = request
            self.state = state
            self.result = result
        }

        init?(json j: [String: Any]) {
            func date(_ v: Any?) -> Date? { (v as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } }
            guard let number = j["number"] as? Int, let asked = date(j["asked"]) else { return nil }
            let why = j["why"] as? String ?? ""
            let state: State
            switch j["state_kind"] as? String ?? "" {
            case "answered": state = .answered
            case "done": state = .done
            case "failed": state = .failed(why)
            case "waiting": state = .waiting
            case "running": state = .running
            case "finished": state = .finished(ok: j["ok"] as? Bool ?? false, code: j["code"] as? Int)
            case "denied": state = .denied
            case "not_answered": state = .notAnswered
            case "withdrawn": state = .withdrawn
            case "could_not_start": state = .couldNotStart(why)
            case "stopped": state = .stopped
            default: return nil
            }
            self.init(number: number, asked: asked, said: j["said"] as? String ?? "", form: j["form"] as? String ?? "", what: j["what"] as? String ?? "",
                      short: j["short"] as? String ?? "", request: (j["request"] as? String).flatMap(UUID.init(uuidString:)), state: state, result: j["result"] as? String)
            shown = j["shown"] as? Bool ?? false
            muted = j["muted"] as? Bool ?? false
            asks = j["asks"] as? Bool ?? false
            told = j["told"] as? String
            ended = date(j["ended"])
        }
    }

    public struct Conversation: Sendable {
        public var entries: [Entry] = []
        public var lastSpoke: Date?
        /// How many times each template was used.
        public var used: [String: Int] = [:]
        /// Where to tell the client how its runs went, as it said (`reply_to`): nil, it hears at
        /// the start of its next reply.
        public var replyTo: URL?
        var counter = 0

        /// Something to tell it yet: a run still going, or one over and not told.
        var untold: Bool { entries.contains { $0.asks && ($0.state.open || (!$0.muted && $0.state.key != $0.told)) } }
    }

    public static let keep: TimeInterval = 7 * 24 * 3600
    public static let perClient = 200
    public static let clients = 100

    private var conversations: [String: Conversation] = [:]
    private var order: [String] = []
    /// The clients whose requests are being followed, to tell them how they went.
    private var watched: Set<String> = []

    public init() {}

    /// What's kept for a client, to read and change.
    public func with<T: Sendable>(_ client: String, now: Date = Date(), _ body: (inout Conversation) -> T) -> T {
        var c = conversations[client] ?? Conversation()
        c.entries.removeAll { now.timeIntervalSince($0.asked) > Self.keep && !$0.state.open }
        if c.entries.count > Self.perClient { c.entries.removeFirst(c.entries.count - Self.perClient) }
        let out = body(&c)
        conversations[client] = c
        order.removeAll { $0 == client }
        order.append(client)
        while order.count > Self.clients { conversations[order.removeFirst()] = nil }
        return out
    }

    /// Adds a request to the log: its number.
    public func add(_ client: String, said: String, form: String, what: String, short: String, state: State, asks: Bool = false,
                    request: UUID? = nil, result: String? = nil) -> Int {
        with(client) { c in
            c.counter += 1
            var e = Entry(number: c.counter, asked: Date(), said: said, form: form, what: what, short: short, request: request, state: state, result: result)
            e.asks = asks
            e.shown = result != nil && !asks
            e.told = state.key
            if !state.open { e.ended = Date() }
            c.entries.append(e)
            c.used[form, default: 0] += 1
            return c.counter
        }
    }

    /// Changes one entry.
    public func update(_ client: String, _ number: Int, _ change: @Sendable (inout Entry) -> Void) {
        with(client) { c in
            if let k = c.entries.firstIndex(where: { $0.number == number }) { change(&c.entries[k]) }
        }
    }

    public func entries(_ client: String) -> [Entry] { with(client) { $0.entries } }

    /// Whether a client has somewhere to be told and something to tell it, with no watch on it yet.
    public func needsWatch(_ client: String) -> Bool {
        guard !watched.contains(client), let c = conversations[client] else { return false }
        return c.replyTo != nil && c.untold
    }

    /// Starts following a client's requests: false when they're followed already.
    public func watch(_ client: String) -> Bool { watched.insert(client).inserted }

    public func unwatch(_ client: String) { watched.remove(client) }

    /// Stops following a client's requests if there's nothing left to tell it (at once, so a
    /// request it makes meanwhile is never missed): whether it stopped.
    public func unwatchIfIdle(_ client: String) -> Bool {
        guard let c = conversations[client], c.replyTo != nil, c.untold else {
            watched.remove(client)
            return true
        }
        return false
    }

    /// Forgets what a client asked for.
    public func reset(_ client: String) {
        with(client) { c in
            c.entries = []
            c.used = [:]
        }
    }

    /// The clients there are, the latest last.
    public func clients() -> [String] { order }

    // MARK: outlasting a restart

    /// What's still being followed, or over and not told yet, for every client (with where it's
    /// to be told): what Peter keeps in Storage Spaces (PETER/FOLLOWING/runs), so a restart
    /// doesn't lose the news.
    public func following() -> [[String: Any]] {
        order.compactMap { client -> [String: Any]? in
            guard let c = conversations[client] else { return nil }
            let entries = c.entries.filter { $0.asks && ($0.state.open || (!$0.muted && $0.state.key != $0.told)) }
            guard !entries.isEmpty else { return nil }
            var out: [String: Any] = ["client": client, "counter": c.counter, "entries": entries.map(\.json)]
            if let u = c.replyTo { out["reply_to"] = u.absoluteString }
            return out
        }
    }

    /// Takes them back after a restart (entries a client has already are left as they are):
    /// the clients that have somewhere to be told.
    public func restore(_ list: [[String: Any]], now: Date = Date()) -> [String] {
        var told: [String] = []
        for item in list {
            guard let client = item["client"] as? String else { continue }
            let entries = (item["entries"] as? [[String: Any]] ?? []).compactMap(Entry.init(json:)).filter { now.timeIntervalSince($0.asked) <= Self.keep }
            guard !entries.isEmpty else { continue }
            let reply = (item["reply_to"] as? String).flatMap(URL.init(string:))
            with(client) { c in
                for e in entries where !c.entries.contains(where: { $0.number == e.number }) { c.entries.append(e) }
                c.entries.sort { $0.number < $1.number }
                c.counter = max(c.counter, item["counter"] as? Int ?? 0, entries.map(\.number).max() ?? 0)
                if c.replyTo == nil { c.replyTo = reply }
            }
            if reply != nil { told.append(client) }
        }
        return told
    }
}
