import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Peter: requests in plain words, carried out on this Mac, answered in plain words.
///
/// A client says what it wants (`POST /api/say`). Peter's model reads it and does it with his
/// tools: Tool Mac Tool Run's (the web, Chrome, the person's scripts and flows, showing and
/// copying), Storage Spaces' (the person's notes, MEMORY and the mind; Super Face's own notes),
/// and his own (the schedule, what a client asked for, who's let into Storage Spaces); then it
/// says how it went. There are no templates: a client never has to fit a shape, and never needs
/// docs to ask. A run on the Mac still waits for the person's click.
///
/// He keeps no conversation: each message is all he has, and his model never sees another. A
/// client that wants something refined asks again, whole. What he does keep is operational: what
/// a client asked for that's still going (a run waiting for Run on the Mac, or running), so he can
/// tell it the moment it's over (`X-Reply-To`); the schedule, reminders and requests for later,
/// said back to the client when they're due; and both of those in his space in Storage Spaces.
public final class Peter: @unchecked Sendable {
    public static let port = 8770
    public static let service = "peter"

    /// Where Peter keeps his things (`~/Library/Application Support/Peter`, or `PETER_HOME`).
    public static var support: URL {
        if let path = ProcessInfo.processInfo.environment["PETER_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Peter", isDirectory: true)
    }

    public let toolMac: ToolMac
    /// Storage Spaces: his own things (PETER), and the person's library, MEMORY and mind.
    public let storage: StorageSpaces
    /// His model: it reads every request and does it with his tools.
    public let brain: Brain
    public let sayLog = SayLog()
    public let schedule: Schedule
    public let version: String
    /// How often a client's runs are looked at while it waits to be told (nanoseconds).
    let sayEvery: UInt64
    /// Delivers news to a client (tests give their own).
    let deliver: @Sendable (SayNews) async -> Bool

    public init(toolMac: ToolMac = ToolMac(), storage: StorageSpaces = StorageSpaces(), brain: Brain = Brain(), schedule: Schedule = Schedule(),
                version: String = "dev", sayEvery: UInt64 = 2_000_000_000, deliver: @escaping @Sendable (SayNews) async -> Bool = Peter.deliverLive) {
        self.toolMac = toolMac
        self.storage = storage
        self.brain = brain
        self.schedule = schedule
        self.version = version
        self.sayEvery = sayEvery
        self.deliver = deliver
    }

    /// Starts the schedule's clock, after taking from Storage Spaces what it has newer than his
    /// own files (the schedule, the model's settings, the runs he was following); then keeps his
    /// things there as they change.
    public func start(onChange: (@Sendable () -> Void)? = nil) async {
        await restoreFromStorage()
        await schedule.start(onDue: { [weak self] item, late in await self?.due(item, late: late) }, onChange: onChange)
        started = Date()
        storageLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.keepInStorage()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// When he started (STATUS/now says so).
    var started = Date()
    var storageLoop: Task<Void, Never>?

    // MARK: Storage Spaces

    /// What Storage Spaces has that's newer than his own files: taken. Each it has none of, or
    /// an older one: his own goes there (on the next `keepInStorage`).
    func restoreFromStorage() async {
        guard await storage.ready() else { return }
        if let r = await storage.record("schedule", "schedule"), r.updated > (await schedule.savedAt ?? .distantPast) {
            await schedule.restore(r.value)
        }
        if let r = await storage.record("settings", "model"), var fields = r.value as? [String: Any], r.updated > (await brain.savedAt ?? .distantPast) {
            // The key never goes to Storage Spaces: the one here stays. The old translator's
            // settings ("sure" was its own) waited too briefly for a request that does things.
            fields["key"] = nil
            if fields["sure"] != nil { fields["timeout"] = nil }
            _ = try? await brain.change(fields)
        }
        if let r = await storage.record("following", "runs"), let list = (r.value as? [String: Any])?["clients"] as? [[String: Any]] {
            for client in await sayLog.restore(list) { sayWatch(client) }
        }
    }

    /// His things, as they are now, into his space (each only when it's changed).
    func keepInStorage() async {
        guard await storage.ready() else { return }
        if let s = await schedule.snapshot() { await storage.mirror("schedule", "schedule", s) }
        await storage.mirror("settings", "model", await brain.settings.kept)
        await storage.mirror("following", "runs", ["clients": await sayLog.following()])
        var now = await health()
        now["started"] = JSON.date(started)
        now["storage_spaces"] = nil
        await storage.mirror("status", "now", now)
    }

    /// A storage tool (the library, MEMORY, the mind) straight on Storage Spaces; the rest, and
    /// those while it isn't answering, on Tool Mac Tool Run.
    func callTool(_ name: String, _ args: [String: Any], why: String, async: Bool) async -> (Int, [String: Any]) {
        if StorageSpaces.tools.contains(name), await storage.ready() {
            let (status, json) = await storage.tool(name, args)
            if status != 0 { return (status, json) }
        }
        return await toolMac.tool(name, args, why: why, async: async)
    }

    /// The clients that are the person (Peter's own window): only they say yes through Peter
    /// (an app that asked can't have Peter say yes for it). Never taken from an HTTP request.
    public static let personClients: Set<String> = ["Peter's window"]

    /// Letting apps into Storage Spaces, in words: who's asking, yes or no, letting one in,
    /// taking it back. Its answer is said (`said`).
    func accessTool(_ args: [String: Any], client: String) async -> (Int, [String: Any]) {
        guard await storage.ready() else {
            return (503, ["ok": false, "error": await storage.problem ?? "Storage Spaces isn't answering. Is it open?"])
        }
        let op = args["op"] as? String ?? ""
        let person = Self.personClients.contains(client)
        if ["approve", "grant"].contains(op), !person {
            return (403, ["ok": false, "error": "Only the person says yes to an app, in Peter's window or Storage Spaces' window: \(client) can't, through me."])
        }
        func number() -> Int? { Self.text(args["number"]).flatMap { Int($0.filter(\.isNumber)) } }
        switch op {
        case "requests":
            let list = await storage.openRequests()
            if list.isEmpty { return (200, ["ok": true, "said": "No app is asking for access."]) }
            let lines = list.map { r -> String in
                let why = (r["why"] as? String).map { " (\"\($0)\")" } ?? ""
                return "request \(r["id"] ?? ""): \(r["client"] ?? "an app") asks to \(r["access"] ?? "read") \(StorageSpaces.placeName(r["space"] as? String ?? "", r["store"] as? String))\(why)"
            }
            return (200, ["ok": true, "said": "Waiting for a yes or a no:\n" + lines.map { "- " + $0 }.joined(separator: "\n") + "\nSay \"allow request N\" or \"deny request N\"."])
        case "approve", "deny":
            guard let n = number() else { return (400, ["ok": false, "error": "Say which request, by its number (\"who's asking for access\" lists them)."]) }
            let (status, j) = await storage.decide(n, yes: op == "approve", hours: (args["hours"] as? NSNumber)?.doubleValue)
            guard (200..<300).contains(status) else { return (status, j) }
            let r = j["request"] as? [String: Any] ?? [:]
            let place = StorageSpaces.placeName(r["space"] as? String ?? "", r["store"] as? String)
            if op == "deny" { return (200, ["ok": true, "said": "Turned down request \(n): \(r["client"] ?? "the app") may not \(r["access"] ?? "read") \(place)."]) }
            let line = (r["grant"] as? [String: Any])?["line"] as? String ?? "\(r["client"] ?? "The app") may \(r["access"] ?? "read") \(place)"
            return (200, ["ok": true, "said": "Said yes to request \(n): " + line + "."])
        case "grant":
            let app = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { return (400, ["ok": false, "error": "Say which app."]) }
            guard let (space, store) = StorageSpaces.place(args["place"] as? String ?? "") else {
                return (400, ["ok": false, "error": "Say what of yours: my library, my memory, the mind, or Super Face's prompt or memory."])
            }
            let (status, j) = await storage.grant(to: app, space: space, store: store, access: args["access"] as? String ?? "read")
            guard (200..<300).contains(status) else { return (status, j) }
            return (200, ["ok": true, "said": ((j["grant"] as? [String: Any])?["line"] as? String ?? "\(app) is let in") + "."])
        case "revoke":
            let app = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { return (400, ["ok": false, "error": "Say which app."]) }
            let (status, j) = await storage.revoke(app)
            guard (200..<300).contains(status) else { return (status, j) }
            let n = j["count"] as? Int ?? 0
            return (200, ["ok": true, "said": n == 0 ? "\(app) wasn't let in anywhere beyond its own space." : "Took back what \(app) was let into (\(n)). It keeps its own space."])
        default:
            return (400, ["ok": false, "error": "There's no access op \(op)."])
        }
    }

    // MARK: the HTTP API

    /// Every route there is: `GET /api` lists them.
    public static let routes: [(String, String, String)] = [
        ("POST", "/api/say", "say what you want, in plain words, as text (text/plain, or {\"text\"}): the answer is plain text. Each message is whole in itself: nothing said before goes with it. ?client= (or X-Client): who's talking. X-Reply-To (an http address on this Mac): where to be told the moment a run is over, and when something scheduled is due"),
        ("GET", "/api/say", "how to talk to Peter, as text"),
        ("GET", "/api/say/log", "what this client asked for, and how each went (JSON, the newest first)"),
        ("POST", "/api/say/stop", "call off one of this client's requests by its number {\"number\": 3}"),
        ("POST", "/api/say/reset", "forget what this client asked for"),
        ("GET", "/api/model", "Peter's model: its settings, whether it's ready, its instructions and tools, and its latest requests, each tool call with what it gave back"),
        ("POST", "/api/model", "change its settings, from this Mac {\"on\", \"api\", \"url\", \"model\", \"key\", \"timeout\", \"effort\", \"context\", \"steps\"}"),
        ("GET", "/api/schedules", "what's scheduled (?client=: one client's)"),
        ("POST", "/api/schedules", "schedule something {\"kind\": \"remind\" | \"later\", \"text\", \"when\", \"repeat\"?, \"client\"?, \"reply_to\"?}"),
        ("DELETE", "/api/schedules/{number}", "take one off"),
        ("GET", "/api/health", "is it up, its version, whether Tool Mac Tool Run answers, its model"),
        ("GET", "/api", "these routes"),
    ]

    /// One request, answered. Only programs on this Mac are answered.
    public func route(_ req: HTTPRequest) async -> HTTPResponse {
        guard req.fromLoopback else {
            return JSON.response(["ok": false, "code": "forbidden", "error": "Peter answers only programs on this Mac"], status: 403)
        }
        do {
            return try await answer(req)
        } catch let e as HTTPError {
            return JSON.response(["ok": false, "code": e.code, "error": e.message], status: e.status)
        } catch {
            return JSON.response(["ok": false, "code": "failed", "error": "\(error)"], status: 500)
        }
    }

    func answer(_ req: HTTPRequest) async throws -> HTTPResponse {
        let method = req.method == "HEAD" ? "GET" : req.method
        var fields: [String: Any] = req.query
        if req.contentType.hasPrefix("application/json"), !req.body.isEmpty {
            guard let o = JSON.object(req.body) else { throw HTTPError(status: 400, code: "bad_request", message: "the body isn't JSON (send what you want to say as text/plain, or {\"text\": \"…\"})") }
            fields.merge(o) { _, b in b }
        }
        let client = Self.client(req, fields)
        switch (method, req.path) {
        case ("GET", "/"), ("GET", "/api"), ("GET", "/api/endpoints"):
            return JSON.response(["ok": true, "service": Self.service, "about": "Peter: say what you want in plain words (POST /api/say), and he carries it out on this Mac.",
                                  "routes": Self.routes.map { ["method": $0.0, "path": $0.1, "summary": $0.2] }])
        case ("GET", "/api/health"):
            return JSON.response(await health())
        case ("POST", "/api/say"):
            if let url = try Self.replyAddress(req, fields) { await sayLog.with(client) { $0.replyTo = url } }
            let text: String
            if req.contentType.hasPrefix("application/json") {
                text = Self.text(fields["text"]) ?? Self.text(fields["say"]) ?? Self.text(fields["message"]) ?? Self.text(fields["q"]) ?? ""
            } else {
                text = req.body.isEmpty ? (req.query["text"] ?? req.query["q"] ?? "") : String(decoding: req.body, as: UTF8.self)
            }
            return Self.plainText(await say(text, client: client))
        case ("GET", "/api/say"):
            return Self.plainText(Self.howTo)
        case ("GET", "/api/say/log"):
            _ = await sayNews(client, tell: false)
            let entries = await sayLog.entries(client)
            return JSON.response(["ok": true, "client": client, "count": entries.count, "entries": entries.reversed().map(Self.entryJSON),
                                  "note": "What this client asked Peter for, newest first (kept a week, the latest 200, while Peter runs)."])
        case ("POST", "/api/say/stop"):
            guard let n = Self.text(fields["number"]).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
                throw HTTPError(status: 400, code: "bad_request", message: "say which request: {\"number\": 3}, its number in GET /api/say/log")
            }
            guard let e = await sayLog.entries(client).first(where: { $0.number == n }) else {
                throw HTTPError(status: 404, code: "not_found", message: "this client has no request numbered \(n) (GET /api/say/log lists them)")
            }
            let reply = await sayStop(e, client: client)
            let now = await sayLog.entries(client).first { $0.number == n }
            return JSON.response(["ok": true, "client": client, "number": n, "message": reply.answer, "state": now?.state.key ?? e.state.key])
        case ("POST", "/api/say/reset"):
            await sayLog.reset(client)
            return JSON.response(["ok": true, "client": client, "message": "What this client asked for is forgotten."])
        // The translator's address, from before Peter's model did all of it.
        case ("GET", "/api/model"), ("POST", "/api/model"), ("GET", "/api/say/translator"), ("POST", "/api/say/translator"):
            return try await modelRoute(method, fields)
        case ("GET", "/api/schedules"):
            let only = req.query["client"].flatMap { $0.isEmpty ? nil : $0 }
            let items = await schedule.list(only)
            return JSON.response(["ok": true, "count": items.count, "schedules": items.map(Schedule.json)])
        case ("POST", "/api/schedules"):
            return try await scheduleRoute(fields, client: client, req)
        case ("DELETE", _) where req.path.hasPrefix("/api/schedules/"):
            guard let n = Int(req.path.dropFirst("/api/schedules/".count)) else { throw HTTPError(status: 400, code: "bad_request", message: "say which, by its number: DELETE /api/schedules/3") }
            guard await schedule.remove(n) else { throw HTTPError(status: 404, code: "not_found", message: "nothing scheduled has the number \(n)") }
            return JSON.response(["ok": true, "removed": n])
        case (_, "/api/say/forms"), (_, "/api/say/translate"):
            throw HTTPError(status: 410, code: "gone", message: "Peter has no templates any more: say what you want in plain words (POST /api/say), and his model does it")
        default:
            if Self.routes.contains(where: { $0.1 == req.path }) {
                throw HTTPError(status: 405, code: "bad_request", message: "\(req.path) doesn't take \(req.method) (GET /api lists what each takes)")
            }
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api lists them)")
        }
    }

    public func health() async -> [String: Any] {
        let c = await toolMac.catalog()
        let s = await brain.settings
        var tm: [String: Any] = ["url": await toolMac.url, "reachable": c.reachable, "tools": c.tools.count, "scripts": c.scripts.count, "flows": c.flows.count]
        if let e = c.error { tm["error"] = e }
        if let v = c.version { tm["version"] = v }
        var st: [String: Any] = ["url": storage.url, "ready": await storage.ready(), "key": await storage.hasKey]
        if let p = await storage.problem { st["problem"] = p }
        var model: [String: Any] = ["on": s.on, "api": s.api, "model": s.model, "ready": await brain.ready, "working": await brain.working > 0]
        if let picked = await brain.pickedModel { model["picked"] = picked }
        return ["ok": true, "service": Self.service, "version": version, "tool_mac_tool_run": tm, "model": model,
                "scheduled": await schedule.items.count, "storage_spaces": st]
    }

    /// What `GET /api/say` says: how to talk to Peter, for a person setting a client up.
    public static let howTo = """
    Talk to Peter in plain words: he carries out what you ask on this Mac (the web, Chrome, the person's scripts and flows, notes, MEMORY and the mind, showing and copying), and keeps a schedule. His model reads every request: there are no templates or formats to learn.

    POST /api/say with what you want, as text (Content-Type: text/plain), and say who you are (?client=My App, or an X-Client header). The answer is text too.

    For a model's instructions, this is enough:
      To get anything done on the Mac or the web, ask Peter in plain words, each message complete in itself.

    How it goes:
    - Say the whole request, with every detail it needs: the actual address, the exact time, the full text. Peter keeps no conversation: each message is all he has, so "yes", "the second one" or "more" mean nothing to him. To change something, ask again, whole.
    - If something is missing or unclear, he does nothing, and says what's missing and how to ask. If he can't, he says why, and what would work instead.
    - "How would I ask you to …?" is answered without doing anything: whether he can, and the words to ask with.
    - A run (a script, a flow) waits for the person at the Mac to click Run. Peter says it's asked for, and tells you how it went the moment it's over (with X-Reply-To), or at the start of your next answer.
    - For later: "remind me in 20 minutes to call Sam", "every morning at 7, what's the weather in Lagos". When it's due, Peter tells you (the reminder), or does it and tells you how it went.
    - About what you asked for: "what have I asked for today", "what happened to the backup", "stop the backup".

    To be told the moment a run is over or something scheduled is due, rather than in your next answer, say where (X-Reply-To: http://127.0.0.1:{port}/{path}, an address on this Mac): it's POSTed there as JSON, {"client", "text", "entries": […]}.

    Also: GET /api/say/log (what you asked for, as JSON), POST /api/say/stop ({"number": 3}), GET /api/schedules, GET /api/model (his model: its instructions, its tools, its latest requests).
    """

    // MARK: saying

    /// One reply, before it's put together: the answer, and the requests it was about (their
    /// news isn't told twice).
    struct SayReply {
        var answer: String
        var about: [Int] = []
    }

    /// Everything a reply says: the news, then the answer.
    public func say(_ text: String, client: String) async -> String {
        var news = await sayNews(client, tell: true)
        let reply = await sayAnswer(text, client: client)
        await sayLog.with(client) { $0.lastSpoke = Date() }
        news.removeAll { reply.about.contains($0.number) }
        var parts: [String] = []
        if !news.isEmpty {
            let lines = news.map { Self.capitalized($0.line) }
            parts.append(lines.count == 1 ? "Meanwhile: " + lines[0] : "Meanwhile:\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        }
        parts.append(SayWords.whole(reply.answer))
        if await sayLog.needsWatch(client) { sayWatch(client) }
        return parts.joined(separator: "\n\n")
    }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    /// What the card on the Mac shows as the reason: the client's own words.
    static func sayWhy(_ client: String, _ said: String) -> String {
        let first = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
        return "\(client) asked in words: “\(clean(first, limit: 160))”"
    }

    static func firstLine(_ s: String) -> String { clean(s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s, limit: 200) }

    static func failed(_ status: Int, _ json: [String: Any]) -> Bool { status < 200 || status >= 400 || json["ok"] as? Bool == false }

    // MARK: the news

    /// What's changed in the client's requests since it last heard: each change told once. Peter
    /// follows Tool Mac Tool Run's requests himself, and collects a result once it's over (so its
    /// open list no longer has it; the client hears of it here, and sees it in full when it asks).
    func sayNews(_ client: String, tell: Bool) async -> [(number: Int, line: String)] {
        var out: [(Int, String)] = []
        for var e in await sayLog.entries(client) where e.asks {
            let followed = e.request != nil && e.state.open
            if followed, let id = e.request { await sayFollow(&e, id) }
            let key = e.state.key
            guard key != e.told else {
                // Only what was followed can have changed.
                if followed { await sayLog.update(client, e.number) { [e] x in x.state = e.state; x.result = e.result; x.ended = e.ended } }
                continue
            }
            let line = Self.newsLine(e)
            let told = tell ? key : e.told
            await sayLog.update(client, e.number) { [e] x in
                x.state = e.state
                x.result = e.result
                x.ended = e.ended
                x.told = told
            }
            if tell, !e.muted { out.append((e.number, line)) }
        }
        return out
    }

    /// Where a request on Tool Mac Tool Run is now, into the entry (its result collected once it's over).
    func sayFollow(_ e: inout SayLog.Entry, _ id: UUID) async {
        let (status, j) = await toolMac.request(id.uuidString, peek: true)
        if status == 0 { return } // out of reach for now: as it was
        guard (200..<300).contains(status) || j["state"] != nil else {
            e.state = .couldNotStart(status == 404 ? "Tool Mac Tool Run has forgotten it (it was closed, or it ran on too long)" : SayWords.failure(j))
            if e.ended == nil { e.ended = Date() }
            return
        }
        let state = j["state"] as? String ?? ""
        let run = j["run"] as? [String: Any]
        switch state {
        case "waiting": e.state = .waiting
        case "denied": e.state = .denied
        case "not_answered": e.state = .notAnswered
        case "withdrawn": e.state = .withdrawn
        case "could_not_start" where run == nil: e.state = .couldNotStart(SayWords.plain(j["error"] as? String ?? "it couldn't start"))
        case "gone": e.state = .couldNotStart("its run was cleared from Tool Mac Tool Run's history")
        case "running": e.state = .running
        default:
            guard let run else {
                e.state = .done
                break
            }
            let rs = run["state"] as? String ?? state
            if rs == "running" { e.state = .running; return }
            e.state = rs == "stopped" ? .stopped : rs == "could_not_start" ? .couldNotStart(SayWords.plain(run["problem"] as? String ?? "it couldn't start"))
                : .finished(ok: rs == "succeeded", code: run["code"] as? Int)
            var result = (run["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = (run["steps"] as? [[String: Any]] ?? []).filter { !(($0["output"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if result.isEmpty, !steps.isEmpty {
                result = steps.map { "\(SayWords.spokenName($0["name"] as? String ?? "")):\n\((($0["output"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n")
            }
            if let problem = run["problem"] as? String, !problem.isEmpty { result = result.isEmpty ? problem : result + "\n" + problem }
            e.result = result
            e.ended = (run["ended"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } ?? Date()
        }
        if !e.state.open {
            if e.ended == nil { e.ended = Date() }
            // Collected by Peter: handed over, so Tool Mac Tool Run's open list is clear of it.
            _ = await toolMac.request(id.uuidString, peek: false)
        }
    }

    /// One change, in a sentence.
    static func newsLine(_ e: SayLog.Entry) -> String {
        let s = e.short
        switch e.state {
        case .running: return "\(s) has started."
        case let .finished(ok, code):
            let result = (e.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // What it printed comes with the news, when it's short enough to be read at once.
            let printed = result.isEmpty ? "" : result.count <= 600 ? " It printed:\n\(result)" : " Say \"show me \(s)\" to see what it printed."
            if ok { return result.isEmpty ? "\(s) finished (it worked, and printed nothing)." : "\(s) finished (it worked).\(printed)" }
            return "\(s) finished, but it failed\(code.map { " (code \($0))" } ?? "").\(printed)"
        case .denied: return "\(s) didn't run: it was turned down on the Mac."
        case .notAnswered: return "\(s) didn't run: no one OK'd it on the Mac in time. Say it again to try again."
        case .withdrawn: return "\(s) was taken back; nothing ran."
        case let .couldNotStart(why): return "\(s) couldn't start: \(why)"
        case .stopped: return "\(s) was stopped before it ended.\((e.result ?? "").isEmpty ? "" : " Say \"show me \(s)\" to see what it printed first.")"
        case .done: return e.result ?? "\(s) is done."
        case let .failed(why): return "\(s) didn't work: \(why)"
        case .waiting: return "\(s) hasn't started yet."
        case .answered: return "\(s) was answered."
        }
    }

    /// How a request is going, in a few words (for lists).
    static func status(_ e: SayLog.Entry) -> String {
        switch e.state {
        case .answered: return "answered"
        case .done: return "done"
        case .failed: return "it didn't work"
        case .waiting: return "not started yet: waiting to be OK'd on the Mac"
        case .running: return "running"
        case let .finished(ok, _):
            let word = ok ? "it worked" : "it failed"
            return e.shown || (e.result ?? "").isEmpty || e.muted ? word : "\(word); not shown yet: say \"show me number \(e.number)\""
        case .denied: return "turned down on the Mac"
        case .notAnswered: return "not OK'd on the Mac in time"
        case .withdrawn: return "taken back"
        case .couldNotStart: return "it couldn't start"
        case .stopped: return "stopped"
        }
    }

    // MARK: about what was asked for

    /// The `requests` tool: what this client asked for, how each went, and stopping one. Its
    /// answer is said (`said`).
    func requestsTool(_ a: [String: Any], client: String, about: Numbers) async -> (content: String, failed: Bool) {
        let entries = await sayLog.entries(client)
        let op = (Self.text(a["op"]) ?? "list").lowercased()
        let which = Self.text(a["which"]) ?? ""
        // What happened to something is about what ran, or ran later, first: not the words that asked for it.
        func one() -> SayLog.Entry? { SayRefs.resolve(which, in: entries.filter(\.asks)) ?? SayRefs.resolve(which, in: entries) }
        let unknown = Self.fail("I can't tell which request \"\(which)\" is: say a word from it, the time it was asked, or its number (list gives them).")
        switch op {
        case "list":
            let cal = Calendar.current
            let now = Date()
            let since: Date?
            var heading: String
            switch (Self.text(a["since"]) ?? "today").lowercased() {
            case "today", "":
                since = cal.startOfDay(for: now); heading = "Today it asked for"
            case "recently", "lately", "all":
                since = nil; heading = "Lately it asked for"
            case let other:
                since = SayRefs.time(other, now: now)
                heading = since.map { "Since \(cal.isDateInToday($0) ? SayWords.time($0) : DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)) it asked for" } ?? "Lately it asked for"
            }
            var picked = entries.filter { since == nil || $0.asked >= since! }
            if since == nil { picked = Array(picked.suffix(10)) }
            guard !picked.isEmpty else { return Self.ok(entries.isEmpty ? "It hasn't asked for anything yet." : "Nothing then.") }
            return Self.ok(heading + " (each with its number):\n" + picked.map { "\($0.number). \($0.what) (\(Self.status($0)))" }.joined(separator: "\n"))
        case "status":
            guard let e = one() else { return unknown }
            var now = e
            if let id = e.request, e.state.open {
                await sayFollow(&now, id)
                await sayLog.update(client, e.number) { [now] x in x.state = now.state; x.result = now.result; x.ended = now.ended; x.told = now.state.key }
            }
            about.add(e.number)
            return Self.ok(Self.story(now))
        case "show":
            guard let e = one() else { return unknown }
            about.add(e.number)
            if e.state.open { return Self.ok(Self.story(e)) }
            guard let result = e.result, !result.isEmpty else { return Self.ok(Self.capitalized(e.short) + " gave back nothing to show.") }
            await sayLog.update(client, e.number) { $0.shown = true }
            let head: String
            switch e.state {
            case let .finished(ok, _): head = "\(Self.capitalized(e.short)) \(ok ? "worked" : "failed")\(e.ended.map { " at \(SayWords.time($0))" } ?? ""). It printed:\n"
            case .stopped: head = "\(Self.capitalized(e.short)) was stopped. Before that it printed:\n"
            default: head = ""
            }
            return Self.ok(head + result)
        case "stop":
            guard let e = one() else { return unknown }
            about.add(e.number)
            return Self.ok(await sayStop(e, client: client).answer)
        case "done":
            guard let e = one() else { return unknown }
            about.add(e.number)
            await sayLog.update(client, e.number) { $0.muted = true; $0.shown = true }
            let more = e.state.open ? " It's still \(e.state == .waiting ? "waiting on the Mac" : "running"): stop it to stop it." : ""
            return Self.ok("All right: no more news of \(e.short).\(more)")
        default:
            return Self.fail("requests takes op list, status, show, stop or done, not \(op).")
        }
    }

    /// Stopping a request: taken back while it waits for the click, stopped while it runs.
    func sayStop(_ e: SayLog.Entry, client: String) async -> SayReply {
        guard let id = e.request else {
            if e.state == .waiting { return SayReply(answer: "\(Self.capitalized(e.short)) hasn't started, and can't be taken back from here: it can be turned down on the Mac.", about: [e.number]) }
            return SayReply(answer: "\(Self.capitalized(e.short)) is over already.", about: [e.number])
        }
        var now = e
        let (_, j) = await toolMac.request(id.uuidString, peek: true)
        await sayFollow(&now, id)
        switch now.state {
        case .waiting:
            if await toolMac.withdraw(id.uuidString) {
                await sayLog.update(client, e.number) { $0.state = .withdrawn; $0.told = "withdrawn"; $0.ended = Date() }
                return SayReply(answer: "Taken back: \(e.short) won't run.", about: [e.number])
            }
            return SayReply(answer: "\(Self.capitalized(e.short)) hasn't started, and can't be taken back right now.", about: [e.number])
        case .running:
            if let run = j["run_id"] as? String, await toolMac.stop(run: run) {
                await sayLog.update(client, e.number) { $0.told = "running" }
                return SayReply(answer: "Stopping \(e.short). I'll tell you when it has.", about: [e.number])
            }
            return SayReply(answer: "\(Self.capitalized(e.short)) couldn't be stopped: it may have just ended.", about: [e.number])
        default:
            await sayLog.update(client, e.number) { [now] x in x.state = now.state; x.result = now.result; x.ended = now.ended }
            return SayReply(answer: "\(Self.capitalized(e.short)) is over already (\(Self.status(now))).", about: [e.number])
        }
    }

    /// How a request has gone, in a sentence or two.
    static func story(_ e: SayLog.Entry) -> String {
        let s = capitalized(e.short)
        let at = SayWords.time(e.asked)
        switch e.state {
        case .waiting: return "\(s) hasn't started yet: it's waiting for someone at the Mac to OK it (asked at \(at)). Nothing has run. I'll tell you when it starts."
        case .running: return "\(s) is running (asked at \(at)). I'll tell you when it's done."
        case let .finished(ok, code):
            var out = "\(s) finished\(e.ended.map { " at \(SayWords.time($0))" } ?? "") and \(ok ? "worked" : "failed\(code.map { " (code \($0))" } ?? "")")."
            if !(e.result ?? "").isEmpty { out += " Say \"show me number \(e.number)\" to see what it printed." }
            return out
        case .answered, .done:
            let first = (e.result ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "That was \(e.state == .done ? "done" : "answered") at \(at)\(first.isEmpty ? "." : ": \(first)")"
        case let .failed(why): return "That didn't work (at \(at)): \(why)"
        case .denied: return "\(s) didn't run: it was turned down on the Mac."
        case .notAnswered: return "\(s) didn't run: no one OK'd it on the Mac in time."
        case .withdrawn: return "\(s) was taken back before anyone answered; nothing ran."
        case let .couldNotStart(why): return "\(s) couldn't start: \(why)"
        case .stopped: return "\(s) was stopped before it ended."
        }
    }

    /// "what can you do": a few lines of what there is, each a template to say.

    // MARK: the schedule

    /// The `schedule` tool: a reminder or a request for later, set; what's set, listed; one
    /// taken off. Its answer is said (`said`).
    func scheduleTool(_ a: [String: Any], client: String) async -> (content: String, failed: Bool) {
        let now = Date()
        let op = (Self.text(a["op"]) ?? "").lowercased()
        switch op {
        case "remind", "later":
            let whenSaid = Self.text(a["when"]) ?? ""
            guard let due = When.parse(whenSaid, now: now) else {
                return Self.fail("I couldn't read when (\"\(whenSaid)\"). Say it like: in 20 minutes, at 17:30, tomorrow 8am, Friday 9:00, or 2026-10-30 14:00.")
            }
            var repeats: When.Repeat?
            if let r = Self.text(a["repeat"]), !r.isEmpty {
                guard let parsed = When.Repeat.parse(r) else { return Self.fail("I couldn't read how often (\"\(r)\"): \(When.Repeat.choices.joined(separator: ", ")).") }
                repeats = parsed
            }
            let text = (Self.text(a["text"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Self.fail(op == "remind" ? "Say what to tell the client then, with every detail." : "Say the whole request to carry out then.") }
            let replyTo = await sayLog.with(client) { $0.replyTo }
            do {
                let item = try await schedule.add(client: client, kind: op == "remind" ? .remind : .later, text: text, due: due, repeats: repeats, replyTo: replyTo, now: now)
                var said = "Set for \(When.long(item.due, now: now)) (\(When.fromNow(item.due, now: now)))\(repeats.map { ", then \($0.said)" } ?? ""): \(item.what). Its number is \(item.id)."
                said += op == "remind" ? " I'll tell you then." : " I'll do it then, and tell you how it went."
                if replyTo == nil { said += " (I have no address to call you on, so you'll hear when you next say something.)" }
                return Self.ok(said)
            } catch {
                return Self.fail("\(error)")
            }
        case "list":
            let items = await schedule.list(client)
            guard !items.isEmpty else { return Self.ok("Nothing is scheduled.") }
            return Self.ok("Scheduled, the soonest first:\n" + items.map { Schedule.line($0, now: now) }.joined(separator: "\n"))
        case "cancel":
            let phrase = Self.text(a["which"]) ?? ""
            let gone = await schedule.cancel(phrase, client: client)
            guard !gone.isEmpty else {
                let items = await schedule.list(client)
                if items.isEmpty { return Self.ok("Nothing is scheduled.") }
                return Self.fail("I can't tell which of these \"\(phrase)\" is: say its number.\n" + items.map { Schedule.line($0, now: now) }.joined(separator: "\n"))
            }
            return Self.ok("Taken off the schedule: " + gone.map { "\($0.id). \($0.what)" }.joined(separator: "; ") + ".")
        default:
            return Self.fail("schedule takes op remind, later, list or cancel, not \(op).")
        }
    }

    /// Something scheduled, due: a reminder said back to its client, or a request done (by his
    /// model, as if the client had just asked it) and how it went said back. Told the moment
    /// it's due when the client gave an address, else at the start of its next answer.
    func due(_ item: Schedule.Item, late: Bool) async {
        let client = item.client
        if let url = item.replyTo { await sayLog.with(client) { c in if c.replyTo == nil { c.replyTo = url } } }
        let lateNote = late ? " (late: it came due \(When.long(item.due)), while Peter was closed)" : ""
        let head = "\(item.repeats.map { "Scheduled \($0.said)" } ?? "Scheduled") \(When.long(item.created)), number \(item.id)\(lateNote)"
        let text: String
        switch item.kind {
        case .remind:
            text = "Reminder (\(head)): \(item.text)"
        case .later:
            let reply = await sayAnswer(item.text, client: client, scheduled: item)
            text = "Done as scheduled (\(head)): \(item.text)\n\(SayWords.whole(reply.answer))"
        }
        let n = await sayLog.add(client, said: item.text, form: item.kind == .remind ? "reminder" : "later", what: item.what, short: item.what, state: .done, asks: true, result: text)
        await sayLog.update(client, n) { $0.told = nil }
        if await sayLog.needsWatch(client) { sayWatch(client) }
    }

    func scheduleRoute(_ fields: [String: Any], client: String, _ req: HTTPRequest) async throws -> HTTPResponse {
        let kind: Schedule.Kind = (Self.text(fields["kind"])?.lowercased() == "later") ? .later : .remind
        guard let whenSaid = Self.text(fields["when"]) ?? Self.text(fields["at"]), let due = When.parse(whenSaid) else {
            throw HTTPError(status: 400, code: "bad_request", message: "say when: {\"when\": \"in 20 minutes\" | \"17:30\" | \"tomorrow 8am\" | \"2026-10-30 14:00\"}")
        }
        var repeats: When.Repeat?
        if let r = Self.text(fields["repeat"]), !r.isEmpty {
            guard let parsed = When.Repeat.parse(r) else { throw HTTPError(status: 400, code: "bad_request", message: "repeat is one of: \(When.Repeat.choices.joined(separator: ", ")), or every N minutes") }
            repeats = parsed
        }
        let replyTo = try Self.replyAddress(req, fields)
        if let replyTo { await sayLog.with(client) { $0.replyTo = replyTo } }
        let known = await sayLog.with(client) { $0.replyTo }
        do {
            let item = try await schedule.add(client: client, kind: kind, text: Self.text(fields["text"]) ?? "", due: due, repeats: repeats, replyTo: replyTo ?? known)
            return JSON.response(["ok": true, "schedule": Schedule.json(item)])
        } catch {
            throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
        }
    }

    // MARK: telling a client

    /// The news to a client: `{"client", "text", "entries": [as /api/say/log has them]}`.
    public struct SayNews: Sendable {
        public let url: URL
        public let body: Data
    }

    /// How many times news that couldn't be delivered is tried again (a while apart) before it waits for the next reply.
    static let sayRetries = 40

    /// Where a client said to be told: an http address on this Mac; nil when none was said.
    static func replyAddress(_ req: HTTPRequest, _ fields: [String: Any]) throws -> URL? {
        guard let said = (req.header("x-reply-to") ?? text(fields["reply_to"]))?.trimmingCharacters(in: .whitespaces), !said.isEmpty else { return nil }
        guard let url = URL(string: said), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw HTTPError(status: 400, code: "bad_request", message: "reply_to is an http address on this Mac, like http://127.0.0.1:8769/api/peter")
        }
        return url
    }

    /// Delivers news: true once the client took it (a 2xx).
    public static let deliverLive: @Sendable (SayNews) async -> Bool = { news in
        var r = URLRequest(url: news.url, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(ToolMac.client, forHTTPHeaderField: "X-Client")
        r.httpBody = news.body
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            URLSession.shared.dataTask(with: r) { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                done.resume(returning: error == nil && (200..<300).contains(status))
            }.resume()
        }
    }

    /// Follows a client's requests while it has somewhere to be told and something still going:
    /// one watch a client, ended when nothing is left to tell.
    func sayWatch(_ client: String) {
        Task { [self] in
            guard await sayLog.watch(client) else { return }
            var failed = 0
            while true {
                guard let url = await sayLog.with(client, { $0.replyTo }) else { break }
                switch await sayPush(client, to: url) {
                case .failed:
                    failed += 1
                    if failed >= Self.sayRetries { await sayLog.unwatch(client); return }
                case .sent, .nothing:
                    failed = 0
                }
                if failed == 0, await sayLog.unwatchIfIdle(client) { return }
                try? await Task.sleep(nanoseconds: sayEvery * (failed > 0 ? 15 : 1))
            }
            await sayLog.unwatch(client)
        }
    }

    enum SayPushed { case nothing, sent, failed }

    /// The news of the client's requests that are over and not told yet, delivered to `url`: told
    /// once it's taken (told before it's sent, so a reply meanwhile doesn't tell it too, and
    /// untold again when it couldn't be delivered).
    func sayPush(_ client: String, to url: URL) async -> SayPushed {
        var over: [SayLog.Entry] = []
        for var e in await sayLog.entries(client) where e.asks {
            if e.state.open, let id = e.request {
                await sayFollow(&e, id)
                await sayLog.update(client, e.number) { [e] x in x.state = e.state; x.result = e.result; x.ended = e.ended }
            }
            guard !e.state.open, e.state.key != e.told else { continue }
            if e.muted {
                await sayLog.update(client, e.number) { [key = e.state.key] x in x.told = key }
                continue
            }
            over.append(e)
        }
        guard !over.isEmpty else { return .nothing }
        let before = Dictionary(uniqueKeysWithValues: over.map { ($0.number, $0.told) })
        for e in over { await sayLog.update(client, e.number) { [key = e.state.key] x in x.told = key } }
        let lines = over.map { Self.capitalized(Self.newsLine($0)) }
        let text = lines.count == 1 ? "Meanwhile: " + lines[0] : "Meanwhile:\n" + lines.map { "- " + $0 }.joined(separator: "\n")
        let body = JSON.data(["client": client, "text": text, "entries": over.map(Self.entryJSON)])
        if await deliver(SayNews(url: url, body: body)) { return .sent }
        for e in over { await sayLog.update(client, e.number) { [told = before[e.number] ?? nil] x in x.told = told } }
        return .failed
    }

    static func entryJSON(_ e: SayLog.Entry) -> [String: Any] {
        var out: [String: Any] = ["number": e.number, "asked": JSON.date(e.asked), "said": e.said, "template": e.form, "what": e.what,
                                  "state": e.state.key, "shown": e.shown, "muted": e.muted, "waits_for_the_mac": e.asks]
        if let r = e.request { out["request"] = r.uuidString }
        if let ended = e.ended { out["ended"] = JSON.date(ended) }
        if let result = e.result { out["result"] = result }
        return out
    }

    // MARK: Peter's model

    /// `GET /api/model`: the model's settings, its instructions and tools, and its latest
    /// requests, each tool call with what it gave back; `POST`: its settings changed.
    func modelRoute(_ method: String, _ fields: [String: Any]) async throws -> HTTPResponse {
        if method == "POST" {
            do {
                try await brain.change(fields)
            } catch {
                throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
            }
        }
        let catalog = await toolMac.catalog()
        let settings = await brain.settings
        let ready = await brain.ready
        let calls = await brain.calls.suffix(20).reversed().map { c -> [String: Any] in
            var d: [String: Any] = ["at": JSON.date(c.at), "client": c.client, "message": c.run.user, "model": c.run.model,
                                    "seconds": JSON.round(c.run.seconds), "answer": c.run.answer,
                                    "steps": c.run.steps.map { ["tool": $0.name, "arguments": $0.arguments, "result": Self.clean($0.result, limit: 600), "failed": $0.failed] as [String: Any] }]
            if let e = c.run.error { d["error"] = e }
            return d
        }
        return JSON.response(["ok": true, "settings": settings.json, "ready": ready, "picked": await brain.pickedModel ?? NSNull(),
                              "instructions": Self.instructions(catalog.guide), "tools": Self.tools(catalog).map(\.name), "calls": calls,
                              "note": "Every request is read by the model, alone: the instructions, the client's message, and the tool calls it makes for it. Nothing else, and nothing kept for the next one."])
    }

    // MARK: reading what was sent

    static func plainText(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", data: Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
    }

    /// A string, or a number or true/false as written.
    static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            #endif
            return n.stringValue
        default: return nil
        }
    }

    /// A query's true or false: "true", "1", "yes" (or there with nothing after it).
    static func flag(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return ["", "true", "1", "yes"].contains(v)
    }

    /// Who's asking: what it calls itself, else its User-Agent's product ("curl/8.4" → "curl").
    static func client(_ req: HTTPRequest, _ fields: [String: Any]) -> String {
        // The person's own names are never an app's (an app can't say yes for itself through Peter).
        func app(_ n: String) -> String { personClients.contains(n) ? n + " (an app)" : n }
        if let named = text(fields["client"]).map({ clean($0, limit: 60) }), !named.isEmpty { return app(named) }
        if let named = req.header("x-client").map({ clean($0, limit: 60) }), !named.isEmpty { return app(named) }
        if let agent = req.header("user-agent"), let product = agent.split(separator: " ").first?.split(separator: "/").first {
            let p = clean(String(product), limit: 40)
            if !p.isEmpty { return p }
        }
        return "An app"
    }

    /// One line, no control characters, at most `limit` characters.
    static func clean(_ s: String, limit: Int) -> String {
        let one = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        let t = one.trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }
}
