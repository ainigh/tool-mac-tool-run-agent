import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Peter: requests in plain words, carried out on Tool Mac Tool Run, answered in plain words.
///
/// A client says what it wants (`POST /api/say`). Peter reads it into one of his templates (the
/// sentences or short forms each of Tool Mac Tool Run's tools, scripts and flows can be asked
/// with): at once when the words fit one, else with his model, which is asked only then. He makes
/// the call on Tool Mac Tool Run, and a script (not a model) says how it went. When it failed,
/// his model looks at why, and he tries once more another way if it says what would do it. He
/// keeps no conversation: every request is whole in itself, and his model never sees a history.
/// What he does keep is what a client asked for that's still going (a run waiting for Run on the
/// Mac, or running), so he can tell it the moment it's over (`X-Reply-To`), and the schedule:
/// reminders and requests for later, said back to the client when they're due.
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
    public let translator: SayTranslator
    public let sayLog = SayLog()
    public let schedule: Schedule
    public let version: String
    /// How often a client's runs are looked at while it waits to be told (nanoseconds).
    let sayEvery: UInt64
    /// Delivers news to a client (tests give their own).
    let deliver: @Sendable (SayNews) async -> Bool

    public init(toolMac: ToolMac = ToolMac(), translator: SayTranslator = SayTranslator(), schedule: Schedule = Schedule(), version: String = "dev",
                sayEvery: UInt64 = 2_000_000_000, deliver: @escaping @Sendable (SayNews) async -> Bool = Peter.deliverLive) {
        self.toolMac = toolMac
        self.translator = translator
        self.schedule = schedule
        self.version = version
        self.sayEvery = sayEvery
        self.deliver = deliver
    }

    /// Starts the schedule's clock.
    public func start(onChange: (@Sendable () -> Void)? = nil) async {
        await schedule.start(onDue: { [weak self] item, late in await self?.due(item, late: late) }, onChange: onChange)
    }

    // MARK: the HTTP API

    /// Every route there is: `GET /api` lists them.
    public static let routes: [(String, String, String)] = [
        ("POST", "/api/say", "say what you want, as text (text/plain, or {\"text\"}): the answer is plain text. ?client= (or X-Client): who's talking. ?exact=true (or X-Exact): only what fits a template, without the model. X-Reply-To (an http address on this Mac): where to be told the moment a run is over, and when something scheduled is due"),
        ("GET", "/api/say", "how to talk to Peter, as text"),
        ("GET", "/api/say/forms", "every template there is now (?q=words: the ones that fit, best first; ?format=json)"),
        ("GET", "/api/say/log", "what this client asked for, and how each went (JSON, the newest first)"),
        ("POST", "/api/say/stop", "call off one of this client's requests by its number {\"number\": 3}"),
        ("POST", "/api/say/reset", "forget what this client asked for"),
        ("POST", "/api/say/translate", "Peter's model alone, stateless {\"text\", \"dry\"?, \"model\"?…}: the prompt, what it answered, which templates came of it"),
        ("GET", "/api/say/translator", "Peter's model: its settings, whether it's ready, its latest calls"),
        ("POST", "/api/say/translator", "change its settings, from this Mac {\"api\", \"url\", \"model\", \"key\", \"sure\", \"on\"}"),
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
            return JSON.response(["ok": true, "service": Self.service, "about": "Peter: say what you want in plain words (POST /api/say), and he carries it out on Tool Mac Tool Run.",
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
            // exact: only what fits a template is done, without the model (quick, for a client reading its own notes).
            let exact = Self.flag(req.query["exact"].map { $0 } ?? req.header("x-exact")) || (fields["exact"] as? Bool ?? false)
            return Self.plainText(await say(text, client: client, exact: exact))
        case ("GET", "/api/say"):
            return Self.plainText(Self.howTo)
        case ("GET", "/api/say/forms"):
            let forms = SayForms.all(catalog: await toolMac.catalog())
            let q = (req.query["q"] ?? "").trimmingCharacters(in: .whitespaces)
            let used = await sayLog.with(client) { $0.used }
            let picked = q.isEmpty ? forms : SayForms.search(q, in: forms, used: used, limit: 20)
            if req.query["format"]?.lowercased() == "json" {
                return JSON.response(["ok": true, "count": picked.count, "q": q, "forms": picked.map(\.json),
                                      "note": "What POST /api/say takes. Say a template back with its blanks filled; the title stays the same from version to version."])
            }
            return Self.plainText(picked.isEmpty ? "No template matches \"\(q)\"." : picked.map(\.template).joined(separator: "\n\n"))
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
        case ("POST", "/api/say/translate"):
            return try await translateRoute(fields, req)
        case ("GET", "/api/say/translator"), ("POST", "/api/say/translator"):
            return try await translatorRoute(method, fields, req)
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
        default:
            if Self.routes.contains(where: { $0.1 == req.path }) {
                throw HTTPError(status: 405, code: "bad_request", message: "\(req.path) doesn't take \(req.method) (GET /api lists what each takes)")
            }
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api lists them)")
        }
    }

    public func health() async -> [String: Any] {
        let c = await toolMac.catalog()
        let s = await translator.settings
        var tm: [String: Any] = ["url": await toolMac.url, "reachable": c.reachable, "tools": c.tools.count, "scripts": c.scripts.count, "flows": c.flows.count]
        if let e = c.error { tm["error"] = e }
        if let v = c.version { tm["version"] = v }
        return ["ok": true, "service": Self.service, "version": version, "tool_mac_tool_run": tm,
                "model": ["on": s.on, "api": s.api, "model": s.model, "ready": await translator.ready, "working": await translator.working > 0],
                "scheduled": await schedule.items.count]
    }

    /// What `GET /api/say` says: how to talk to Peter, for a person setting a client up.
    public static let howTo = """
    Talk to Peter in plain words: he carries out what you ask on this Mac, through Tool Mac Tool Run (the web, Chrome, the person's scripts and flows, notes, MEMORY and the mind, showing and copying), and keeps a schedule.

    POST /api/say with what you want, as text (Content-Type: text/plain), and say who you are (?client=My App, or an X-Client header). The answer is text too.

    For a model's instructions, this is enough:
      To get anything done on the Mac or the web, ask Peter in plain words. If he answers with templates, fill one in and say it back.

    How it goes:
    - Say what you want, in your own words. Peter reads it into one of his templates (by its words, or with his model when they don't settle it) and does it. The answer starts "Taken as: …" when his model read it: say it that way next time.
    - If he can't tell, he answers with a few templates that would do it: {…} is a blank to fill, [a | b] a choice of one, (optional) a line that may be left out. Copy one, fill it in, say it back.
    - Every request is whole in itself: Peter keeps no conversation (no "yes", no "the second one", no "more"). Say the whole thing each time.
    - A run (a script, a flow) waits for the person at the Mac to click Run. Peter says it's asked for, and tells you how it went the moment it's over (with X-Reply-To), or at the start of your next answer.
    - For later: "remind me in 20 minutes to call Sam", "every morning at 7, what's the weather in Lagos". When it's due, Peter tells you (the reminder), or does it and tells you how it went.

    Always there:
      what can you do
      what happened to {something you asked for}
      what have I asked for [today | recently | since {a time}]
      show me {something you asked for}
      stop {something you asked for}
      I'm done with {something you asked for}
      what's scheduled
      cancel the schedule {its number, a word from it, or all}

    {something you asked for} is "the last one", a word from it ("the backup"), a time ("the one around 3"), or its number in "what have I asked for".

    To be told the moment a run is over or something scheduled is due, rather than in your next answer, say where (X-Reply-To: http://127.0.0.1:{port}/{path}, an address on this Mac): it's POSTed there as JSON, {"client", "text", "entries": […]}.

    Also: GET /api/say/forms (every template; ?q=words, ?format=json), GET /api/say/log (what you asked for, as JSON), POST /api/say/stop ({"number": 3}), GET /api/schedules, POST /api/say/translate ({"text"}: Peter's model alone).
    """

    // MARK: saying

    /// One reply, before it's put together: the answer, the templates that usually follow, and
    /// the requests it was about (their news isn't told twice).
    struct SayReply {
        var answer: String
        var next: [SayForm] = []
        var about: [Int] = []
    }

    /// Who's talking, and every template there is now.
    struct SayContext {
        let client: String
        let forms: [SayForm]
        let catalog: Catalog
        /// Without the model: only what fits a template is done.
        var exact = false

        func form(_ title: String) -> SayForm? { forms.first { $0.title == title } }
        func forms(_ titles: [String]) -> [SayForm] { titles.compactMap(form) }
    }

    func context(_ client: String, exact: Bool = false) async -> SayContext {
        let c = await toolMac.catalog()
        return SayContext(client: client, forms: SayForms.all(catalog: c), catalog: c, exact: exact)
    }

    /// Everything a reply says: the news, the answer, and what can be said next.
    public func say(_ text: String, client: String, exact: Bool = false) async -> String {
        let ctx = await context(client, exact: exact)
        var news = await sayNews(client, tell: true)
        let reply = await sayAnswer(text, ctx)
        await sayLog.with(client) { $0.lastSpoke = Date() }
        news.removeAll { reply.about.contains($0.number) }
        var parts: [String] = []
        if !news.isEmpty {
            let lines = news.map { Self.capitalized($0.line) }
            parts.append(lines.count == 1 ? "Meanwhile: " + lines[0] : "Meanwhile:\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        }
        parts.append(SayWords.whole(reply.answer))
        let next = reply.next.prefix(2)
        if !next.isEmpty {
            if next.count == 1, let one = next.first {
                parts.append(one.isInline ? "You can also say: " + one.short : "You can also say:\n" + one.template)
            } else {
                parts.append("You can also say:\n" + next.map { $0.isInline ? "- " + $0.short : "- " + $0.template.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
            }
        }
        if await sayLog.needsWatch(client) { sayWatch(client) }
        return parts.joined(separator: "\n\n")
    }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    /// The answer to what was said: a filled template (the labeled shape, then the inline), a
    /// title alone, or what his model makes of it; else the templates that fit.
    func sayAnswer(_ raw: String, _ ctx: SayContext) async -> SayReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return await sayBuiltin(.whatCanYouDo, SayFilled(), said: text, ctx) }
        let (entries, used) = await sayLog.with(ctx.client) { ($0.entries, $0.used) }

        // The labeled shape: a title, and a line for each value.
        if let lines = SayMatch.lines(text), let reply = await sayLabeled(lines, text, ctx) { return reply }

        // Something for later, said in a sentence ("remind me in 20 minutes to call Sam"): read by its words.
        if let later = LaterWords.read(text) {
            var f = SayFilled()
            f.values = ["when": later.when, "repeat": later.repeats?.said ?? "", later.kind == .remind ? "message" : "what": later.text]
            if let form = ctx.form(later.kind == .remind ? "Remind me" : "Do something later") {
                return await sayScheduling(later.kind == .remind ? .remind : .later, form, f, said: text, ctx)
            }
        }

        // The inline shape: the closest sentence.
        var found: [(form: SayForm, filled: SayFilled, score: Double, fixed: Int)] = []
        for f in ctx.forms where f.isInline {
            if let (filled, score, fixed) = SayMatch.inlineWeighed(text, f), score >= SayMatch.floor { found.append((f, filled, score, fixed)) }
        }
        found.sort { a, b in
            if abs(a.score - b.score) > 0.001 { return a.score > b.score }
            if a.fixed != b.fixed { return a.fixed > b.fixed }
            return (used[a.form.title] ?? 0) > (used[b.form.title] ?? 0)
        }
        var unresolved: (SayForm, String)?
        var usable: [(form: SayForm, filled: SayFilled, score: Double)] = []
        for c in found {
            // One about a request it can't tell: not this one.
            if case let .builtin(b) = c.form.action, Self.takesRequest(b) {
                let phrase = c.filled.at(0) ?? ""
                if SayRefs.resolve(phrase, in: entries) == nil {
                    if unresolved == nil { unresolved = (c.form, phrase) }
                    continue
                }
            }
            if !usable.contains(where: { $0.form.title == c.form.title }) { usable.append((c.form, c.filled, c.score)) }
        }
        if let top = usable.first {
            // Two about as close, and one changes something: which?
            if usable.count > 1, usable[1].score >= top.score - 0.03, top.form.changes || usable[1].form.changes,
               found.first(where: { $0.form.title == usable[1].form.title })?.fixed == found.first?.fixed {
                let two = Array(usable.prefix(2))
                if let r = await sayTranslate(text, .between(two.map(\.form.title)), ctx, list: false) { return r }
                return SayReply(answer: "Did you mean one of these? Say the one you mean:\n" + two.map { "- " + Self.filledIn($0.form, $0.filled).replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
            }
            if top.score < SayMatch.certain(top.form), top.form.changes, top.form.kind != "builtin" {
                if top.score < SayMatch.clean, let r = await sayTranslate(text, .weak(top.form.title), ctx, list: false) { return r }
                return sayConfirm(top.form, top.filled)
            }
            return await sayAct(top.form, top.filled, said: text, ctx)
        }
        if let (form, phrase) = unresolved, case let .builtin(b) = form.action, b != .showMe || !entries.isEmpty {
            return SayReply(answer: entries.isEmpty
                            ? "You haven't asked me for anything yet."
                            : "I can't tell which request \"\(phrase)\" is. Say \"what have I asked for today\" for the list, then say it with its number (\"show me number 3\").",
                            next: ctx.forms(["What have I asked for"]))
        }

        // A title alone: the template, to fill (or, needing nothing, done).
        let titled = ctx.forms.filter { $0.kind != "builtin" }.map { ($0, SayMatch.titleScore(text, $0)) }.max { $0.1 < $1.1 }
        if let (form, score) = titled, score >= 0.85 {
            if Self.needsNothing(form) { return await sayAct(form, SayFilled(), said: text, ctx) }
            return SayReply(answer: "Fill in the blanks and say it back:\n\n" + form.template)
        }
        // Nothing matched closely: what the model makes of it, else the templates that fit the words.
        if let r = await sayTranslate(text, .nothing, ctx, list: true) { return r }
        return await sayOffer(text, ctx)
    }

    /// The labeled shape: which template its title (or its labels) mean, and what it gave.
    func sayLabeled(_ l: SayMatch.Lines, _ text: String, _ ctx: SayContext) async -> SayReply? {
        let candidates = ctx.forms.filter { $0.kind != "builtin" }
        var target: (SayForm, Double)?
        if let title = l.title {
            let scored = candidates.map { ($0, SayMatch.titleScore(title, $0)) }.filter { $0.1 >= SayMatch.floor }.sorted { $0.1 > $1.1 }
            // Two titles about as close: the one all its lines belong to.
            if scored.count > 1, scored[1].1 >= scored[0].1 - 0.02 {
                target = scored.prefix(4).first { f in if case .filled = SayMatch.labeled(l, Self.labeledForm(f.0), titleScore: f.1) { return true }; return false } ?? scored[0]
            } else {
                target = scored.first
            }
            // A title it doesn't know, with lines: the lines say which.
            if target == nil, let byLabels = SayMatch.formByLabels(l, candidates.map(Self.labeledForm)) { target = byLabels }
        } else {
            target = SayMatch.formByLabels(l, candidates.map(Self.labeledForm))
        }
        guard let (found, titleScore) = target, let form = ctx.form(found.title) else { return nil }
        let shaped = Self.labeledForm(form)
        switch SayMatch.labeled(l, shaped, titleScore: titleScore) {
        case let .filled(filled, score):
            if score < SayMatch.certain(form), form.changes, form.kind != "schedule" { return sayConfirm(shaped, filled) }
            return await sayAct(form, filled, said: text, ctx)
        case let .incomplete(filled, missing, _):
            if filled.values.values.allSatisfy(\.isEmpty) { return SayReply(answer: "Fill in the blanks and say it back:\n\n" + form.template) }
            return SayReply(answer: "That needs \(Self.listed(missing.map(\.label))) too. Here it is to fill in:\n\n" + Self.template(shaped, with: filled))
        case let .badChoice(field, given, _):
            return SayReply(answer: "\(Self.capitalized(field.label)) is one of \(field.choices.joined(separator: ", ")); \"\(given)\" isn't one of them.\n\n" + form.template)
        case let .unknownLabel(label, _):
            return SayReply(answer: "\(form.title) has no line called \"\(label)\". Its lines:\n\n" + form.template)
        }
    }

    /// An inline form, as lines: a field for each blank of its first sentence (so a client can
    /// fill it either way). A labeled form as it is.
    static func labeledForm(_ form: SayForm) -> SayForm {
        guard form.fields.isEmpty, let v = form.variants.first else { return form }
        let blanks: [SayForm.Field] = v.pieces.compactMap { if case let .blank(b) = $0 { return .init(b, b) }; return nil }
        return SayForm(form.title, fields: blanks, formerly: form.formerly, words: form.words, about: form.about, changes: form.changes,
                       asks: form.asks, next: form.next, kind: form.kind, action: form.action)
    }

    /// A labeled template with what was given already in it.
    static func template(_ form: SayForm, with filled: SayFilled) -> String {
        ([form.title] + form.fields.map { f -> String in
            guard let v = filled[f.label] else { return f.shown }
            if f.multiline || v.contains("\n") { return "- \(f.label):\n```\n\(v)\n```" }
            return "- \(f.label): \(v)"
        }).joined(separator: "\n")
    }

    /// "a, b and c".
    static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// A filled template in a line: "Delete a note (shopping)".
    static func described(_ form: SayForm, _ filled: SayFilled) -> String {
        let values = (filled.ordered.isEmpty ? Array(filled.values.values) : filled.ordered).filter { !$0.isEmpty }
            .map { $0.count > 60 ? String($0.prefix(57)) + "…" : $0 }.map { $0.replacingOccurrences(of: "\n", with: " ") }
        return form.title + (values.isEmpty ? "" : " (\(values.joined(separator: ", ")))")
    }

    /// An uncertain match that would change something: nothing done, and what to say to do it.
    /// (Peter keeps no conversation, so there's no "yes" to wait for: said back as it's shown, it's sure.)
    func sayConfirm(_ form: SayForm, _ filled: SayFilled) -> SayReply {
        let corrected = filled.corrections.isEmpty ? "" : " (" + filled.corrections.joined(separator: "; ") + ")"
        let exact = Self.filledIn(form, filled)
        return SayReply(answer: "Did you mean: \(Self.described(form, filled))\(corrected)? Nothing was done. To do it, say it like this:\n\n\(exact)")
    }

    /// It takes nothing: saying its title does it.
    static func needsNothing(_ form: SayForm) -> Bool {
        // Its own sentence takes nothing (another way of saying it that takes nothing isn't enough).
        if let first = form.sentences.first { return !first.contains("{") }
        return form.fields.allSatisfy(\.optional)
    }

    static func takesRequest(_ b: SayBuiltin) -> Bool { [.whatHappened, .showMe, .stop, .done].contains(b) }

    /// Nothing matched: the templates that would do it.
    func sayOffer(_ text: String, _ ctx: SayContext) async -> SayReply {
        let used = await sayLog.with(ctx.client) { $0.used }
        var picked = SayForms.search(text, in: ctx.forms, used: used, limit: 5)
        // The web answers most questions: offered second for a question (after the best fit, if
        // there's one), and last when little else fits.
        if let web = ctx.form("Search the web") {
            if Self.isQuestion(text) {
                picked.removeAll { $0.title == web.title }
                picked.insert(web, at: min(1, picked.count))
            } else if picked.count < 3, !picked.contains(where: { $0.title == web.title }) {
                picked.append(web)
            }
        }
        guard !picked.isEmpty else {
            return SayReply(answer: "I don't know how to do that yet.", next: ctx.forms(["What can you do"]))
        }
        return SayReply(answer: "These can do that:\n" + Self.offered(Array(picked.prefix(5))) + "\nFill one in and say it back.")
    }

    /// A question about the world ("when does the louvre open?"), not a request to do something.
    static func isQuestion(_ text: String) -> Bool {
        let words = SayText.words(text)
        guard let first = words.first else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            || ["when", "where", "who", "whom", "whose", "why", "how", "which", "what", "whats", "is", "are", "was", "were", "does", "do", "did"].contains(first)
    }

    /// Templates in a numbered list, each indented under its number.
    static func offered(_ forms: [SayForm]) -> String {
        forms.enumerated().map { k, f in
            let body = (f.isInline ? [f.short] : Array(f.template.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()).map(String.init))
            return "\(k + 1). \(f.title)\n" + body.map { "     " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: doing it

    /// A filled template, done: the call it stands for made, the request logged, the answer said.
    /// `mending`: it's already another try after a failure (so a failure now isn't tried again).
    func sayAct(_ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext, mending: Bool = false) async -> SayReply {
        switch form.action {
        case let .builtin(b):
            return await sayBuiltin(b, filled, said: said, ctx)
        case let .tool(name, build):
            let args: [String: Any]
            do {
                args = try build(filled)
            } catch {
                return SayReply(answer: "\(error)", next: [form])
            }
            return await sayTool(name, args, form, filled, said: said, ctx, mending: mending)
        case let .script(item), let .flow(item):
            return await sayRun(item, form, filled, said: said, ctx, mending: mending)
        case let .schedule(op):
            return await sayScheduling(op, form, filled, said: said, ctx)
        }
    }

    /// What the card on the Mac shows as the reason: the client's own words.
    static func sayWhy(_ client: String, _ said: String) -> String {
        let first = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
        return "\(client) asked in words: “\(clean(first, limit: 160))”"
    }

    /// What a request was, in words, for the log: the client's own sentence, or the template's
    /// title and its first value.
    static func what(_ form: SayForm, _ filled: SayFilled, said: String) -> String {
        let first = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? said
        if form.isInline, SayMatch.lines(said) == nil { return clean(first, limit: 80) }
        let value = form.fields.first { $0.choices.isEmpty && filled[$0.label] != nil }.flatMap { filled[$0.label] }
            ?? filled.ordered.first { !$0.isEmpty } ?? ""
        let v = clean(value.replacingOccurrences(of: "\n", with: " "), limit: 50)
        return form.title.prefix(1).lowercased() + form.title.dropFirst() + (v.isEmpty ? "" : ": \(v)")
    }

    static func firstLine(_ s: String) -> String { clean(s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s, limit: 200) }

    static func failed(_ status: Int, _ json: [String: Any]) -> Bool { status < 200 || status >= 400 || json["ok"] as? Bool == false }

    func sayTool(_ name: String, _ args: [String: Any], _ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext, mending: Bool) async -> SayReply {
        let (status, json) = await toolMac.tool(name, args, why: Self.sayWhy(ctx.client, said), async: form.asks)
        let what = Self.what(form, filled, said: said)
        if form.asks {
            return await sayWaiting(status, json, form: form, filled: filled, what: what, short: what, said: said, ctx, mending: mending)
        }
        var text = SayWords.answer(tool: name, args: args, status: status, json: json)
        let ok = !Self.failed(status, json)
        if !ok, !mending, status != 0, let mended = await sayMend(form, filled, failure: text, said: said, ctx) { return mended }
        if !filled.corrections.isEmpty { text = Self.capitalized(filled.corrections.joined(separator: "; ")) + ". " + text }
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: what,
                                 state: ok ? (form.changes ? .done : .answered) : .failed(text), result: text)
        return SayReply(answer: text, next: ok ? ctx.forms(form.next) : [form], about: [n])
    }

    /// A run asked for: on the Mac now, waiting for the click.
    func sayWaiting(_ status: Int, _ json: [String: Any], form: SayForm, filled: SayFilled, what: String, short: String, said: String, _ ctx: SayContext, mending: Bool) async -> SayReply {
        guard status == 202, let id = (json["request"] as? String).flatMap(UUID.init(uuidString:)) else {
            let text = SayWords.answer(tool: "", args: [:], status: max(status, 400), json: json)
            if !mending, status != 0, let mended = await sayMend(form, filled, failure: text, said: said, ctx) { return mended }
            let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: short, state: .failed(text), result: text)
            return SayReply(answer: text, next: [form], about: [n])
        }
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: what, short: short, state: .waiting, asks: true, request: id)
        // The client needn't know it waits for an OK on the Mac (the card says what it does): it's
        // asked for, and how it goes comes as news, or when it asks.
        return SayReply(answer: "Asked for \(short). I'll tell you how it goes.", next: ctx.forms(["What happened"]), about: [n])
    }

    /// A script or a flow: its inputs from the values, in order, then asked for on the Mac.
    func sayRun(_ item: FolderItem, _ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext, mending: Bool) async -> SayReply {
        let answers: [String] = form.isInline && SayMatch.lines(said) == nil ? filled.ordered : form.fields.isEmpty ? filled.ordered : form.fields.map { filled[$0.label] ?? "" }
        if let missing = ScriptInput.missing(item.inputs, answers: answers) {
            return SayReply(answer: "That needs a value for \(missing.replacingOccurrences(of: " — this one is needed.", with: "")).\n\n" + form.template)
        }
        var (args, stdin) = ScriptInput.split(item.inputs, answers: answers)
        // A sentence with more blanks than the header has inputs: the rest are arguments too.
        if answers.count > item.inputs.count { args += answers.dropFirst(item.inputs.count).filter { !$0.isEmpty } }
        var arguments: [String: Any] = [item.isFlow ? "flow" : "script": item.id, "args": args]
        if let stdin, !item.isFlow { arguments["stdin"] = stdin }
        let (status, json) = await toolMac.tool(item.isFlow ? "run_flow" : "run_script", arguments, why: Self.sayWhy(ctx.client, said), async: true)
        let short = "the " + SayForms.spoken(item.title)
        let what = form.isInline && SayMatch.lines(said) == nil ? Self.clean(Self.firstLine(said), limit: 80) : short + (args.isEmpty ? "" : " (\(Self.clean(args.joined(separator: ", "), limit: 50)))")
        return await sayWaiting(status, json, form: form, filled: filled, what: what, short: short, said: said, ctx, mending: mending)
    }

    // MARK: Peter's model

    /// One suggestion of the model's, read back: its template, what it filled, and whether that's all it needs.
    struct SayReading {
        let form: SayForm
        let filled: SayFilled
        /// As the model filled it (blanks it couldn't fill left as they were).
        let say: String
        let confidence: Double
        /// Every value it needs is there.
        let complete: Bool
    }

    /// The templates the model is given, and how many of them are the closest: the ones the
    /// words were between, the ones search finds; then the tools', the schedule's, the ones about
    /// what was asked for, and the folder's (never yes, no or more).
    static func translatorForms(_ text: String, _ why: SayTranslator.Why, _ forms: [SayForm], used: [String: Int]) -> (forms: [SayForm], closest: Int) {
        var first: [String] = []
        switch why {
        case let .between(t): first = t
        case let .weak(t): first = [t]
        case .nothing, .failed: break
        }
        first += SayForms.search(text, in: forms, used: used, limit: 10).map(\.title)
        var seen = Set<String>()
        var out: [SayForm] = []
        func add(_ f: SayForm) {
            guard !seen.contains(f.title), !["Yes", "No", "More"].contains(f.title) else { return }
            seen.insert(f.title)
            out.append(f)
        }
        for t in first { if let f = forms.first(where: { $0.title == t }) { add(f) } }
        let closest = out.count
        forms.filter { $0.kind == "tool" }.forEach(add)
        forms.filter { $0.kind == "schedule" }.forEach(add)
        forms.filter { $0.kind == "builtin" }.forEach(add)
        forms.forEach(add)
        return (out, closest)
    }

    /// A value that's still a blank: "{a place}".
    static func isBlank(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (t.hasPrefix("{") && t.hasSuffix("}") && !t.dropFirst().contains("{"))
    }

    /// Whether a filled template has every value it needs.
    static func complete(_ form: SayForm, _ filled: SayFilled) -> Bool {
        if filled.values.values.contains(where: { isBlank($0) && !$0.isEmpty }) { return false }
        if form.isInline {
            // Its values, or a way of saying it that takes none ("what's the weather").
            return !filled.ordered.isEmpty || form.variants.contains { v in !v.pieces.contains { if case .blank = $0 { return true }; return false } }
        }
        return form.fields.allSatisfy { $0.optional || !isBlank(filled.values[$0.label] ?? "") }
    }

    /// A filled template as a client would say it back: an inline sentence with its values in
    /// place, or the labeled lines with theirs.
    static func filledIn(_ form: SayForm, _ filled: SayFilled) -> String {
        guard let sentence = form.sentences.first else { return template(form, with: filled) }
        var out = ""
        var values = filled.ordered.makeIterator()
        var s = Substring(sentence)
        while let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
            out += s[..<open]
            let v = values.next() ?? ""
            out += v.isEmpty ? String(s[open...close]) : v
            s = s[s.index(after: close)...]
        }
        return out + s
    }

    /// The model's suggestion read back against the template it names: nil when it names none there is.
    static func reading(_ s: SayTranslator.Suggestion, _ forms: [SayForm]) -> SayReading? {
        let candidates = forms.filter { !["Yes", "No", "More"].contains($0.title) }
        let form = candidates.first { $0.title.lowercased() == s.title.lowercased() || $0.formerly.contains { $0.lowercased() == s.title.lowercased() } }
            ?? candidates.map { ($0, SayMatch.titleScore(s.title, $0)) }.filter { $0.1 >= 0.85 }.max { $0.1 < $1.1 }?.0
        guard let form else { return nil }
        let say = s.say.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing filled: the template as it is.
        guard !say.isEmpty, say.lowercased() != form.title.lowercased() else {
            return SayReading(form: form, filled: SayFilled(), say: form.short, confidence: s.confidence, complete: needsNothing(form))
        }
        // The labeled shape (or an inline template sent as lines).
        if let lines = SayMatch.lines(say) {
            switch SayMatch.labeled(lines, labeledForm(form), titleScore: 1) {
            case let .filled(filled, _):
                return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: complete(labeledForm(form), filled))
            case let .incomplete(filled, _, _):
                return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: false)
            case .badChoice, .unknownLabel:
                break
            }
        }
        // The inline shape: its own sentence, as closely as a client's would have to be.
        if form.isInline, let (filled, score) = SayMatch.inline(say, form), score >= SayMatch.clean {
            return SayReading(form: form, filled: filled, say: say, confidence: s.confidence, complete: complete(form, filled))
        }
        // A filling that isn't the template's: the template, to fill.
        return SayReading(form: form, filled: SayFilled(), say: form.short, confidence: min(s.confidence, 0.5), complete: false)
    }

    /// The model's readings, the best first, one a template.
    static func readings(_ t: SayTranslator.Translation, _ forms: [SayForm]) -> [SayReading] {
        var out: [SayReading] = []
        for s in t.suggestions {
            guard let r = reading(s, forms), !out.contains(where: { $0.form.title == r.form.title }) else { continue }
            out.append(r)
        }
        return out
    }

    /// What the model makes of it, done or offered; nil when it has nothing to add (it's off or
    /// out of reach, or it found nothing). With `list` false, only a reading it's sure of counts
    /// (Peter has an answer of his own to fall back on).
    func sayTranslate(_ text: String, _ why: SayTranslator.Why, _ ctx: SayContext, list: Bool) async -> SayReply? {
        guard !ctx.exact, await translator.ready else { return nil }
        let used = await sayLog.with(ctx.client) { $0.used }
        let (forms, closest) = Self.translatorForms(text, why, ctx.forms, used: used)
        let t = await translator.translate(text, why: why, forms: forms, closest: closest)
        guard t.error == nil else { return nil }
        let readings = Self.readings(t, ctx.forms)
        let sure = await translator.settings.sure
        if let top = readings.first, top.complete, top.confidence >= sure {
            var reply = await sayAct(top.form, top.filled, said: text, ctx)
            reply.answer = "Taken as: " + (top.say.contains("\n") ? "\n" + top.say : top.say) + "\n\n" + reply.answer
            return reply
        }
        guard list, !readings.isEmpty else { return nil }
        let shown = Array(readings.prefix(3))
        var answer = t.meaning.isEmpty ? "" : "It sounds like: \(t.meaning).\n"
        answer += "You might mean:\n" + shown.enumerated().map { k, r in
            let body = r.say.contains("\n") ? r.say.split(separator: "\n", omittingEmptySubsequences: false).map { "     " + $0 }.joined(separator: "\n") : "     " + r.say
            return "\(k + 1). \(r.form.title)\n" + body
        }.joined(separator: "\n")
        answer += "\nNothing was done. Say one of them back (filled in, changed if need be)."
        if !t.question.isEmpty { answer += "\n" + t.question }
        return SayReply(answer: answer)
    }

    /// It failed: the model looks at why. If it says what would do it instead (another template,
    /// or other values), that's done once, and the answer says so; if not, the failure with what
    /// it makes of it. Nil when the model has nothing to add.
    func sayMend(_ form: SayForm, _ filled: SayFilled, failure: String, said: String, _ ctx: SayContext) async -> SayReply? {
        guard !ctx.exact, await translator.ready else { return nil }
        let done = Self.filledIn(form, filled)
        let why = SayTranslator.Why.failed(done, failure)
        let used = await sayLog.with(ctx.client) { $0.used }
        var (forms, closest) = Self.translatorForms(said, why, ctx.forms, used: used)
        if let k = forms.firstIndex(where: { $0.title == form.title }), k >= closest {
            forms.insert(forms.remove(at: k), at: 0)
            closest += 1
        }
        let t = await translator.translate(said, why: why, forms: forms, closest: closest)
        guard t.error == nil else { return nil }
        let sure = await translator.settings.sure
        if let top = Self.readings(t, ctx.forms).first(where: { r in r.complete && Self.filledIn(r.form, r.filled) != done }), top.confidence >= sure {
            var reply = await sayAct(top.form, top.filled, said: said, ctx, mending: true)
            reply.answer = "\(failure)\nTried instead: " + (top.say.contains("\n") ? "\n" + top.say : top.say) + "\n\n" + reply.answer
            return reply
        }
        var answer = failure
        if !t.meaning.isEmpty, t.meaning.lowercased() != failure.lowercased() { answer += "\n" + Self.capitalized(t.meaning) + (t.meaning.hasSuffix(".") ? "" : ".") }
        if !t.question.isEmpty { answer += "\n" + t.question }
        let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: Self.what(form, filled, said: said),
                                 short: Self.what(form, filled, said: said), state: .failed(failure), result: answer)
        return SayReply(answer: answer, next: [form], about: [n])
    }

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

    func sayBuiltin(_ b: SayBuiltin, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let entries = await sayLog.entries(ctx.client)
        let entry = filled.at(0).flatMap { SayRefs.resolve($0, in: entries) }
        switch b {
        case .whatCanYouDo:
            return SayReply(answer: Self.overview(ctx))
        case .whatHappened:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            var now = e
            if let id = e.request, e.state.open {
                await sayFollow(&now, id)
                await sayLog.update(ctx.client, e.number) { [now] x in x.state = now.state; x.result = now.result; x.ended = now.ended; x.told = now.state.key }
            }
            return SayReply(answer: Self.story(now), about: [e.number])
        case .whatHaveIAsked:
            let cal = Calendar.current
            let now = Date()
            let since: Date?
            var heading: String
            switch filled.chose.first {
            case "today", nil:
                since = cal.startOfDay(for: now); heading = "Today you asked for"
            case "recently":
                since = nil; heading = "Lately you asked for"
            default:
                let t = filled.at(0).flatMap { SayRefs.time($0, now: now) }
                since = t
                heading = t.map { "Since \(cal.isDateInToday($0) ? SayWords.time($0) : DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)) you asked for" } ?? "Lately you asked for"
            }
            var picked = entries.filter { since == nil || $0.asked >= since! }
            if since == nil { picked = Array(picked.suffix(10)) }
            guard !picked.isEmpty else {
                return SayReply(answer: entries.isEmpty ? "You haven't asked me for anything yet." : "Nothing then. Say \"what have I asked for recently\" for the latest.")
            }
            return SayReply(answer: heading + " (each with its number):\n" + picked.map { "\($0.number). \($0.what) (\(Self.status($0)))" }.joined(separator: "\n"))
        case .showMe:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            if e.state.open { return SayReply(answer: Self.story(e), about: [e.number]) }
            guard let result = e.result, !result.isEmpty else { return SayReply(answer: Self.capitalized(e.short) + " gave back nothing to show.", about: [e.number]) }
            await sayLog.update(ctx.client, e.number) { $0.shown = true }
            let head: String
            switch e.state {
            case let .finished(ok, _): head = "\(Self.capitalized(e.short)) \(ok ? "worked" : "failed")\(e.ended.map { " at \(SayWords.time($0))" } ?? ""). It printed:\n"
            case .stopped: head = "\(Self.capitalized(e.short)) was stopped. Before that it printed:\n"
            default: head = ""
            }
            return SayReply(answer: head + result, about: [e.number])
        case .stop:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            return await sayStop(e, client: ctx.client)
        case .done:
            guard let e = entry else { return SayReply(answer: "I can't tell which request that is.", next: ctx.forms(["What have I asked for"])) }
            await sayLog.update(ctx.client, e.number) { $0.muted = true; $0.shown = true }
            let more = e.state.open ? " It's still \(e.state == .waiting ? "waiting on the Mac" : "running"): say \"stop \(e.short)\" to stop it." : ""
            return SayReply(answer: "All right: I won't mention \(e.short) again.\(more)", about: [e.number])
        case .yes, .no:
            return SayReply(answer: "I keep no conversation, so a \"\(b == .yes ? "yes" : "no")\" on its own is nothing to me. Say the whole request, as you'd like it done.")
        case .more:
            return SayReply(answer: "I keep no conversation, and every answer comes whole. To see what something you asked for gave back, say \"show me {something you asked for}\".")
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
    static func overview(_ ctx: SayContext) -> String {
        func line(_ title: String) -> String? { ctx.form(title).map { $0.isInline ? "- " + $0.short : "- " + $0.title.lowercased() + " (say it, and I'll show you its lines)" } }
        let tools = ["Search the web", "Read a web page", "Open a page in Chrome", "Remember something", "Recall something", "Read a note", "Remind me", "Do something later"].compactMap(line)
        let folder = ctx.forms.filter { $0.kind == "script" || $0.kind == "flow" }
        var out = "Say what you want, in your own words. If I'm not sure, I'll answer with a few templates to fill in and say back.\n\nSome of what you can say:\n" + tools.joined(separator: "\n")
        if !folder.isEmpty {
            let some = folder.prefix(3).map { "- " + $0.short }
            out += "\n\nThe Mac also has \(folder.count) script\(folder.count == 1 ? "" : "s") and flow\(folder.count == 1 ? "" : "s"), like:\n" + some.joined(separator: "\n")
        }
        if !ctx.catalog.reachable { out += "\n\nTool Mac Tool Run isn't answering right now, so nothing can be done on the Mac until it's open, with its API on." }
        out += "\n\nAnd about what you've asked for: what have I asked for today · what happened to {something you asked for} · show me {something you asked for} · stop {something you asked for} · what's scheduled"
        return out
    }

    // MARK: the schedule

    func sayScheduling(_ op: SayScheduling, _ form: SayForm, _ filled: SayFilled, said: String, _ ctx: SayContext) async -> SayReply {
        let now = Date()
        switch op {
        case .remind, .later:
            let whenSaid = filled["when"] ?? ""
            guard let due = When.parse(whenSaid, now: now) else {
                return SayReply(answer: "I couldn't read when (\"\(whenSaid)\"). Say it like: in 20 minutes, at 17:30, tomorrow 8am, Friday 9:00, or 2026-10-30 14:00.\n\n" + form.template)
            }
            var repeats: When.Repeat?
            if let r = filled["repeat"], !r.isEmpty {
                guard let parsed = When.Repeat.parse(r) else { return SayReply(answer: "I couldn't read how often (\"\(r)\"): \(When.Repeat.choices.joined(separator: ", ")).\n\n" + form.template) }
                repeats = parsed
            }
            let text = (op == .remind ? filled["message"] : filled["what"]) ?? ""
            let replyTo = await sayLog.with(ctx.client) { $0.replyTo }
            do {
                let item = try await schedule.add(client: ctx.client, kind: op == .remind ? .remind : .later, text: text, due: due, repeats: repeats, replyTo: replyTo, now: now)
                let n = await sayLog.add(ctx.client, said: Self.firstLine(said), form: form.title, what: "\(item.what), \(When.long(item.due, now: now))",
                                         short: item.what, state: .done, result: "Scheduled \(Schedule.line(item, now: now))")
                var answer = "Set for \(When.long(item.due, now: now)) (\(When.fromNow(item.due, now: now)))\(repeats.map { ", then \($0.said)" } ?? ""): \(item.what). Its number is \(item.id)."
                answer += op == .remind ? " I'll tell you then." : " I'll do it then, and tell you how it went."
                if replyTo == nil { answer += " (I have no address to call you on, so you'll hear when you next say something.)" }
                return SayReply(answer: answer, next: ctx.forms(["What's scheduled"]), about: [n])
            } catch {
                return SayReply(answer: "\(error)", next: [form])
            }
        case .list:
            let items = await schedule.list(ctx.client)
            guard !items.isEmpty else { return SayReply(answer: "Nothing is scheduled.") }
            return SayReply(answer: "Scheduled, the soonest first:\n" + items.map { Schedule.line($0, now: now) }.joined(separator: "\n"),
                            next: ctx.forms(["Cancel something scheduled"]))
        case .cancel:
            let phrase = filled.at(0) ?? ""
            let gone = await schedule.cancel(phrase, client: ctx.client)
            guard !gone.isEmpty else {
                let items = await schedule.list(ctx.client)
                if items.isEmpty { return SayReply(answer: "Nothing is scheduled.") }
                return SayReply(answer: "I can't tell which of these \"\(phrase)\" is: say its number.\n" + items.map { Schedule.line($0, now: now) }.joined(separator: "\n"))
            }
            return SayReply(answer: "Taken off the schedule: " + gone.map { "\($0.id). \($0.what)" }.joined(separator: "; ") + ".")
        }
    }

    /// Something scheduled, due: a reminder said back to its client, or a request done and how it
    /// went said back. Told the moment it's due when the client gave an address, else at the
    /// start of its next answer.
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
            let ctx = await context(client)
            let reply = await sayAnswer(item.text, ctx)
            text = "Done as scheduled (\(head)): \(item.text)\n\(SayWords.whole(reply.answer))"
        }
        let n = await sayLog.add(client, said: item.text, form: item.kind == .remind ? "Remind me" : "Do something later", what: item.what, short: item.what, state: .done, asks: true, result: text)
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

    // MARK: Peter's model, alone

    /// `POST /api/say/translate`: the model alone, stateless: `{"text", "why"?: "nothing" |
    /// "between" | "weak", "between"?: [titles], "dry"?: true, and any setting to try instead}`.
    func translateRoute(_ fields: [String: Any], _ req: HTTPRequest) async throws -> HTTPResponse {
        let text = (Self.text(fields["text"]) ?? Self.text(fields["q"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HTTPError(status: 400, code: "missing_argument", message: "say what to translate: {\"text\": \"will it rain in Lagos tomorrow\"}") }
        let titles: [String] = (fields["between"] as? [String]) ?? Self.text(fields["between"]).map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        let why: SayTranslator.Why
        switch Self.text(fields["why"])?.lowercased() {
        case "between": why = .between(titles)
        case "weak": why = .weak(titles.first ?? "")
        default: why = .nothing
        }
        let all = SayForms.all(catalog: await toolMac.catalog())
        let (forms, closest) = Self.translatorForms(text, why, all, used: [:])
        let trying = ["model", "url", "api", "key", "format", "effort", "timeout"].contains { fields[$0] != nil }
        var using: SayTranslator.Settings?
        if trying {
            do {
                var o = try await translator.settings.changed(by: fields)
                o.on = true
                using = o
            } catch {
                throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
            }
        }
        let dry = Self.flag(Self.text(fields["dry"]))
        let t = await translator.translate(text, why: why, forms: forms, closest: closest, using: using, dry: dry)
        let readings = Self.readings(t, all)
        var out: [String: Any] = [
            "ok": t.error == nil, "text": text, "why": why.key, "model": t.model, "seconds": JSON.round(t.seconds),
            "prompt": ["system": t.system, "user": t.user], "raw": t.raw, "meaning": t.meaning, "question": t.question,
            "suggestions": t.suggestions.map { s -> [String: Any] in
                var d: [String: Any] = ["title": s.title, "say": s.say, "confidence": s.confidence]
                if let r = Self.reading(s, all) {
                    d["template"] = r.form.title
                    d["complete"] = r.complete
                    d["taken"] = r.complete ? r.say : NSNull()
                } else {
                    d["template"] = NSNull()
                    d["complete"] = false
                }
                return d
            },
            "top": readings.first.map { $0.form.title } ?? NSNull(),
            "templates_given": forms.prefix(SayTranslator.maxForms).count,
        ]
        if dry { out["dry"] = true }
        if let e = t.error, !dry { out["error"] = e }
        return JSON.response(out)
    }

    /// `GET /api/say/translator`: the model's settings and its latest calls; `POST`: changed.
    func translatorRoute(_ method: String, _ fields: [String: Any], _ req: HTTPRequest) async throws -> HTTPResponse {
        if method == "POST" {
            do {
                try await translator.change(fields)
            } catch {
                throw HTTPError(status: 400, code: "bad_request", message: "\(error)")
            }
        }
        let settings = await translator.settings
        let ready = await translator.ready
        let calls = await translator.calls.suffix(20).reversed().map { c -> [String: Any] in
            var d: [String: Any] = ["at": JSON.date(c.at), "text": c.text, "why": c.why, "model": c.translation.model,
                                    "seconds": JSON.round(c.translation.seconds), "meaning": c.translation.meaning,
                                    "suggestions": c.translation.suggestions.map { ["title": $0.title, "say": $0.say, "confidence": $0.confidence] }]
            if let e = c.translation.error { d["error"] = e }
            return d
        }
        return JSON.response(["ok": true, "settings": settings.json, "ready": ready, "calls": calls,
                              "note": "Asked only when the words don't settle on one template, and when a request failed. Stateless: what was said, why, and the templates; nothing else."])
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
        if let named = text(fields["client"]).map({ clean($0, limit: 60) }), !named.isEmpty { return named }
        if let named = req.header("x-client").map({ clean($0, limit: 60) }), !named.isEmpty { return named }
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

extension SayForm {
    /// As `GET /api/say/forms?format=json` gives it.
    var json: [String: Any] {
        var out: [String: Any] = ["title": title, "template": template, "kind": kind, "shape": isInline ? "inline" : "labeled",
                                  "changes": changes, "waits_for_the_mac": asks]
        if !sentences.isEmpty { out["sentences"] = sentences }
        if !fields.isEmpty {
            out["fields"] = fields.map { f -> [String: Any] in
                var d: [String: Any] = ["label": f.label, "optional": f.optional, "multiline": f.multiline]
                if let b = f.blank { d["blank"] = b }
                if !f.choices.isEmpty { d["choices"] = f.choices }
                return d
            }
        }
        if !formerly.isEmpty { out["formerly"] = formerly }
        if !about.isEmpty { out["about"] = about }
        return out
    }
}
