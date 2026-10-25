import Foundation

/// Peter's schedule: what's set for later, for each client. A reminder (a message said back to
/// the client when it's due) or a request (done when it's due, and how it went said back), once
/// or again and again ("every day"). Kept on disk, so it outlasts a restart: one that came due
/// while Peter was closed is done as he opens, saying it's late; one over a day late is dropped
/// (a repeating one goes on from its next time).
public actor Schedule {
    public enum Kind: String, Codable, Sendable {
        case remind, later
    }

    public struct Item: Codable, Sendable, Equatable {
        public var id: Int
        public var client: String
        public var kind: Kind
        /// The message (remind), or the request in words (later).
        public var text: String
        public var due: Date
        public var repeats: When.Repeat?
        /// Where the client said to be told (its `X-Reply-To`), if it did.
        public var replyTo: URL?
        public var created: Date
        /// How many times it has come due.
        public var fired = 0

        /// "a reminder: call Sam", "the weather in Lagos".
        public var what: String { kind == .remind ? "a reminder: \(text)" : text }
    }

    struct Kept: Codable {
        var next: Int
        var items: [Item]
    }

    public static let maxItems = 200
    static let stale: TimeInterval = 24 * 3600

    let file: URL?
    public private(set) var items: [Item] = []
    var next = 1
    /// Called when one comes due: the item, and whether it's late.
    var onDue: (@Sendable (Item, Bool) async -> Void)?
    var onChange: (@Sendable () -> Void)?
    private var timer: Task<Void, Never>?

    public init(file: URL? = Schedule.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let kept = try? dec.decode(Kept.self, from: data) {
                items = kept.items
                next = max(kept.next, (kept.items.map(\.id).max() ?? 0) + 1)
            }
        }
    }

    public static var defaultFile: URL {
        if let path = ProcessInfo.processInfo.environment["PETER_SCHEDULE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Peter.support.appendingPathComponent("schedule.json")
    }

    /// Starts the clock: what's due is done as it comes due (what came due while it was off, at once).
    public func start(onDue: @escaping @Sendable (Item, Bool) async -> Void, onChange: (@Sendable () -> Void)? = nil) {
        self.onDue = onDue
        self.onChange = onChange
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// What's due now, done (and a repeating one moved on to its next time).
    public func tick(now: Date = Date()) async {
        let due = items.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        for item in due {
            let late = now.timeIntervalSince(item.due) > 90
            let stale = now.timeIntervalSince(item.due) > Self.stale
            if let r = item.repeats, let k = items.firstIndex(where: { $0.id == item.id }) {
                items[k].due = r.next(after: item.due, now: now)
                items[k].fired += 1
            } else {
                items.removeAll { $0.id == item.id }
            }
            save()
            onChange?()
            if !stale { await onDue?(item, late) }
        }
    }

    /// Adds one: it, or why it can't be.
    public func add(client: String, kind: Kind, text: String, due: Date, repeats: When.Repeat?, replyTo: URL?, now: Date = Date()) throws -> Item {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ScheduleError(kind == .remind ? "Say what to be reminded of." : "Say what to do then.") }
        guard due >= now.addingTimeInterval(-60) else { throw ScheduleError("That time (\(When.long(due, now: now))) has passed.") }
        guard items.count < Self.maxItems else { throw ScheduleError("There are already \(Self.maxItems) things scheduled: cancel some first.") }
        let item = Item(id: next, client: client, kind: kind, text: String(t.prefix(2000)), due: max(due, now), repeats: repeats, replyTo: replyTo, created: now)
        next += 1
        items.append(item)
        save()
        onChange?()
        return item
    }

    /// A client's, the soonest first (nil: everyone's).
    public func list(_ client: String? = nil) -> [Item] {
        items.filter { client == nil || $0.client == client }.sorted { $0.due < $1.due }
    }

    /// Takes off the ones a phrase means (its number, "all", or words from it): those taken off.
    public func cancel(_ phrase: String, client: String?) -> [Item] {
        let mine = list(client)
        let p = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var hit: [Item]
        if ["all", "everything", "all of them", "them all"].contains(p) {
            hit = mine
        } else if let n = Int(p.replacingOccurrences(of: #"^(number|no|#|s)\s*"#, with: "", options: .regularExpression)) {
            hit = mine.filter { $0.id == n }
        } else {
            let q = Set(APISearch.query(p))
            let scored = mine.map { i in (i, q.intersection(Set(APISearch.query(i.text))).count) }.filter { $0.1 > 0 }
            let best = scored.map(\.1).max() ?? 0
            hit = scored.filter { $0.1 == best }.map(\.0)
            // Words that fit several as well: none, unless it's one.
            if hit.count > 1 { return [] }
        }
        let ids = Set(hit.map(\.id))
        guard !ids.isEmpty else { return [] }
        items.removeAll { ids.contains($0.id) }
        save()
        onChange?()
        return hit
    }

    /// Takes one off by its number (for the app's list): whether it was there.
    @discardableResult
    public func remove(_ id: Int) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        save()
        onChange?()
        return true
    }

    func save() {
        guard let file else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(Kept(next: next, items: items)).write(to: file, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Peter: the schedule wasn't saved: \(error)\n".utf8))
        }
    }

    /// One, in a line: "3. tomorrow at 08:00 (in 9 hours), every day: a reminder: stand up".
    public static func line(_ i: Item, now: Date = Date()) -> String {
        "\(i.id). \(When.long(i.due, now: now)) (\(When.fromNow(i.due, now: now)))\(i.repeats.map { ", \($0.said)" } ?? ""): \(i.what)"
    }

    public static func json(_ i: Item) -> [String: Any] {
        var out: [String: Any] = ["number": i.id, "client": i.client, "kind": i.kind.rawValue, "text": i.text, "due": JSON.date(i.due),
                                  "created": JSON.date(i.created), "fired": i.fired, "said": line(i)]
        if let r = i.repeats { out["repeat"] = r.said }
        if let u = i.replyTo { out["reply_to"] = u.absoluteString }
        return out
    }
}

public struct ScheduleError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ d: String) { description = d }
}
