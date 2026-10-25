import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Storage Spaces (github.com/ainigh/tool-mac-tool-run-storage-spaces), over its HTTP API on
/// 127.0.0.1:8771: what the apps on this Mac keep, a space each. Peter may read and write every
/// space, and he's the one who lets other apps in.
///
/// He keeps what he needs to work in his own space, PETER: his schedule (SCHEDULE/schedule), his
/// model's settings (SETTINGS/model, without a key), the runs he's following (FOLLOWING/runs) and
/// how things stand (STATUS/now). His own files in Application Support stay as they were, so he
/// works the same while Storage Spaces is closed; whichever is newer wins when he opens.
///
/// The person's library, MEMORY and the mind he reads and writes straight from here (the same
/// templates as before: "read the note …", "remember …", "what do you know about …"), and only
/// through Tool Mac Tool Run when Storage Spaces isn't answering.
///
/// He claims his name with a key the first time (`POST /api/clients/register`), kept in his
/// Application Support (`storage-key`), so no other app can pass itself off as him.
public actor StorageSpaces {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let defaultURL = "http://127.0.0.1:8771"
    public static let client = "Peter"

    public let url: String
    let send: Send
    /// Where his key is kept (nil: in memory only).
    let keyFile: URL?
    private var key: String?
    /// Whether it answered, and when that was last asked.
    private var answered: (ok: Bool, at: Date) = (false, .distantPast)
    /// Why it isn't usable, when it isn't (unreachable, his name's key lost).
    public private(set) var problem: String?
    /// The latest snapshot of each record to be written, and the ones last written.
    private var pending: [String: Any] = [:]
    private var written: [String: Data] = [:]
    private var flushing = false
    /// It's never asked (tests, and an app that wants none of it).
    let off: Bool

    public init(url: String = StorageSpaces.defaultURL, keyFile: URL? = Peter.support.appendingPathComponent("storage-key"), send: @escaping Send = ToolMac.live) {
        self.url = url
        self.keyFile = keyFile
        self.send = send
        off = false
        key = keyFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        if key?.isEmpty == true { key = nil }
    }

    init(off: Bool) {
        url = Self.defaultURL
        keyFile = nil
        send = { _ in throw URLError(.cannotConnectToHost) }
        self.off = off
    }

    /// One that's never asked: Peter works as he did without it.
    public static func none() -> StorageSpaces { StorageSpaces(off: true) }

    // MARK: asking

    /// One call, as Peter (with his key): its status and JSON (`{"ok": false, "error"}` when
    /// nothing answers). `body` is JSON (an object, or any value for a record's PUT).
    public func call(_ method: String, _ path: String, _ body: Any? = nil, timeout: TimeInterval = 10) async -> (Int, [String: Any]) {
        if off { return (0, ["ok": false, "code": "unreachable", "error": "Storage Spaces is off"]) }
        guard let u = URL(string: url + path) else { return (0, ["ok": false, "error": "\(url) isn't an address"]) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(Self.client, forHTTPHeaderField: "X-Client")
        if let key { r.setValue(key, forHTTPHeaderField: "X-Storage-Key") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        }
        do {
            let (data, status) = try await send(r)
            answered = (true, Date())
            let json = JSON.object(data) ?? (data.isEmpty ? [:] : ["text": String(decoding: data, as: UTF8.self)])
            if status == 401, json["code"] as? String == "bad_key" {
                problem = "Storage Spaces knows Peter by a key this copy doesn't have: forget Peter's key in the Storage Spaces window (Access), and he claims his name again."
            }
            return (status, json)
        } catch {
            answered = (false, Date())
            problem = "Storage Spaces isn't answering at \(url). Is it open?"
            return (0, ["ok": false, "code": "unreachable", "error": "Storage Spaces isn't answering at \(url). Is it open?"])
        }
    }

    /// Whether it answers (asked again after a few seconds), and Peter's name is his: the first
    /// time, he claims it with a key.
    public func ready() async -> Bool {
        if off { return false }
        if Date().timeIntervalSince(answered.at) < 5 {
            if !answered.ok { return false }
            if key != nil, lastReady { return true }
        }
        lastReady = await claim()
        return lastReady
    }

    private var lastReady = false

    private func claim() async -> Bool {
        if key == nil {
            let (status, j) = await call("POST", "/api/clients/register", ["client": Self.client], timeout: 3)
            guard status != 0 else { return false }
            if status == 200, let k = j["key"] as? String {
                key = k
                if let keyFile {
                    try? FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data(k.utf8).write(to: keyFile, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
                }
                problem = nil
            } else if status == 409 {
                problem = "Peter's name in Storage Spaces has a key this copy doesn't have: forget Peter's key in the Storage Spaces window (Access), and he claims it again."
                return false
            }
            return true
        }
        let (status, j) = await call("GET", "/api/access/check?space=peter&store=status", timeout: 3)
        if status == 200 { problem = nil }
        return status == 200 && j["allowed"] as? Bool == true
    }

    public var hasKey: Bool { key != nil }

    // MARK: Peter's records

    /// A record of his (`store`: schedule, status, following, settings): its value and when it
    /// was last written; nil when there's none (or Storage Spaces isn't answering).
    public func record(_ store: String, _ key: String) async -> (value: Any, updated: Date)? {
        let (status, j) = await call("GET", "/api/spaces/peter/\(store)/records/\(Self.escape(key))")
        guard status == 200, let value = j["value"] else { return nil }
        let updated = (j["updated"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } ?? .distantPast
        return (value, updated)
    }

    /// Writes one: whether it was written.
    @discardableResult
    public func put(_ store: String, _ key: String, _ value: Any) async -> Bool {
        let (status, _) = await call("PUT", "/api/spaces/peter/\(store)/records/\(Self.escape(key))", value)
        return (200..<300).contains(status)
    }

    /// Keeps a snapshot in a record: only when it's changed since it was last written, and only
    /// the latest of several in a row (written in order, one at a time).
    public func mirror(_ store: String, _ key: String, _ value: Any) {
        guard !off else { return }
        pending["\(store)/\(key)"] = value
        guard !flushing else { return }
        flushing = true
        Task { await self.flush() }
    }

    private func flush() async {
        while let (path, value) = pending.first {
            pending[path] = nil
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            if written[path] == data { continue }
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            if await put(parts[0], parts[1], value) { written[path] = data }
        }
        flushing = false
    }

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

    // MARK: the person's library, MEMORY and the mind

    /// The tools Storage Spaces answers itself (Tool Mac Tool Run's names for them).
    public static let tools: Set<String> = ["library", "remember", "recall", "memory", "mind"]

    /// A storage tool called straight on Storage Spaces, its arguments as Peter's templates make
    /// them (the same answers Tool Mac Tool Run's tools give: they're the same routes).
    public func tool(_ name: String, _ args: [String: Any]) async -> (Int, [String: Any]) {
        switch name {
        case "library": return await call("POST", "/api/library", args)
        case "remember":
            var b = args
            b["category"] = (args["category"] as? String ?? "OTHERS").uppercased().replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "ORGANISATIONS", with: "ORGANIZATIONS")
            return await call("POST", "/api/memory/remember", b)
        case "recall":
            let n = (args["name"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return await call("GET", "/api/memory/recall?name=\(n)")
        case "memory": return await call("POST", "/api/memory", args)
        case "mind": return await call("POST", "/api/mind", args)
        default: return (404, ["ok": false, "error": "Storage Spaces has no tool called \(name)"])
        }
    }

    // MARK: letting apps in

    /// The requests for access waiting for a yes or a no, oldest first.
    public func openRequests() async -> [[String: Any]] {
        let (status, j) = await call("GET", "/api/access/requests?state=open")
        return status == 200 ? j["requests"] as? [[String: Any]] ?? [] : []
    }

    /// Says yes or no to one: Storage Spaces' answer.
    public func decide(_ number: Int, yes: Bool, hours: Double? = nil) async -> (Int, [String: Any]) {
        await call("POST", "/api/access/requests/\(number)/\(yes ? "approve" : "deny")", hours.map { ["hours": $0] } ?? [String: Any]())
    }

    /// Lets an app in without being asked.
    public func grant(to app: String, space: String, store: String?, access: String, hours: Double? = nil) async -> (Int, [String: Any]) {
        var b: [String: Any] = ["to": app, "space": space, "access": access, "why": "the person asked Peter"]
        if let store { b["store"] = store }
        if let hours { b["hours"] = hours }
        return await call("POST", "/api/access/grants", b)
    }

    /// Takes back every grant an app has: how many.
    public func revoke(_ app: String) async -> (Int, [String: Any]) {
        let (status, j) = await call("GET", "/api/access/grants")
        guard status == 200 else { return (status, j) }
        let mine = (j["grants"] as? [[String: Any]] ?? []).filter { ($0["client"] as? String)?.lowercased() == app.lowercased() }
        var lines: [String] = []
        for g in mine {
            if let id = g["id"] as? Int, (200..<300).contains(await call("DELETE", "/api/access/grants/\(id)").0) { lines.append(g["line"] as? String ?? "") }
        }
        return (200, ["ok": true, "count": lines.count, "lines": lines])
    }

    /// The space and store a phrase means: "my memory" → user/memory, "Super Face's prompt" →
    /// super/prompt, "my space" → user. Nil when it means none.
    public static func place(_ text: String) -> (space: String, store: String?)? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let space: String
        if t.contains("super") { space = "super" } else if t.contains("peter") { space = "peter" } else { space = "user" }
        let stores: [(String, [String])] = [
            ("library", ["library", "note"]), ("memory", ["memory", "memories", "remember"]), ("mind", ["mind"]),
            ("prompt", ["prompt", "instruction"]), ("schedule", ["schedule"]), ("status", ["status"]),
            ("following", ["following", "runs"]), ("settings", ["settings"]),
        ]
        let valid: [String: Set<String>] = ["user": ["library", "memory", "mind"], "super": ["prompt", "memory"], "peter": ["schedule", "status", "following", "settings"]]
        for (store, words) in stores where words.contains(where: { t.contains($0) }) {
            if valid[space]?.contains(store) == true { return (space, store) }
        }
        let whole = ["space", "everything", "all", "things", "stuff"]
        if whole.contains(where: { t.contains($0) }) || t.contains("super") || t.contains("peter") { return (space, nil) }
        return nil
    }

    /// "USER/MEMORY", "SUPER".
    public static func placeName(_ space: String, _ store: String?) -> String {
        space.uppercased() + (store.map { "/" + $0.uppercased() } ?? "")
    }
}
