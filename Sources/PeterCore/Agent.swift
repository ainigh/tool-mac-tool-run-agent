import Foundation

/// How a request is done: Peter's model is given his instructions, the client's message (who
/// it's from, and the time), and his tools, and works it through; each tool it calls is done
/// here. Nothing of one request goes into the next (a client's own instructions say so: his
/// answers don't). How it went is told by what his tools did, not by his words: `Outcome`.
extension Peter {
    /// How a request went, from what his tools did (never from what his model says): sent with
    /// the answer as `X-Peter-Outcome`, so a client needn't guess from the words.
    public enum Outcome: String, Sendable {
        /// A tool did what was asked (or found what was asked), and no run was asked for.
        case done
        /// A run was asked for on the Mac: it waits for the person to click Run, and the client is told how it went.
        case asked
        /// No tool did anything: he needs something, can't do it, or said how to ask.
        case nothing
        /// He couldn't work it through: his model out of reach, or too many steps.
        case error
    }

    /// The instructions: the same for every request (so a server can cache them), but for Tool
    /// Mac Tool Run's own guide to its tools.
    public static func instructions(_ guide: [String]) -> String {
        var out = """
        You are Peter. Apps on this Mac (your clients) send you requests in plain words, one message at a time, and you remember none of them: each message is all you have. Carry out what it asks with your tools, then answer in one to three plain sentences: what you did and the result, with the specifics (the address opened, the time set, what you found). Never claim more than your tools gave back.

        - "How would I ask you to …?": do nothing. Say whether you can, and the exact words to ask with.
        - Something you need is missing or unclear: do nothing. Say what's missing, and how to ask, like "Ask again with the address: open https://… in Chrome."
        - You can't do it: say why, and what would work instead.
        - Do only what's asked. Don't start a run, drive Chrome, show a window or write anything the request didn't ask for: if that's what it would take, say so, and how to ask for it.
        - A message for someone else (a text, an email, a note to them) goes word for word as given: add nothing, change nothing.
        - Use find before you guess which of the person's scripts or flows to run, and the web before you say you don't know.
        - A script, a flow or Flow code waits for the person to click Run on the Mac: start it and say "Asked for …". Don't wait for it: the client is told how it went when it's over.
        - Something for later ("remind me in 20 minutes…", "every weekday at 8, …"): schedule. What the client asked you for before, and how it went: requests.
        - The person's notes, MEMORY and the mind: library, remember, recall, memory, mind. Super Face's own notes (its standing instructions, its playbook): space_notes. Keep what you're asked to keep word for word.
        - Answer in plain text: no markdown, no JSON, and never a tool's name (say "fill in the search in Chrome", not "straw").
        """
        if !guide.isEmpty { out += "\n\nAbout Tool Mac Tool Run's tools:\n" + guide.map { "- " + $0 }.joined(separator: "\n") }
        return out
    }

    /// The message, as the model gets it: who it's from, when, and what was said.
    static func message(_ text: String, client: String, now: Date = Date(), scheduled: Schedule.Item? = nil) -> String {
        let from = scheduled.map { "\(client) (scheduled \(When.long($0.created, now: now)); due now)" } ?? client
        return "From: \(from)\nNow: \(stamp(now))\n\n\(text)"
    }

    /// "Sunday 25 October 2026, 21:40 (UTC+01:00)".
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let off = TimeZone.current.secondsFromGMT(for: d) / 60
        let tz = String(format: "UTC%@%02d:%02d", off >= 0 ? "+" : "-", abs(off) / 60, abs(off) % 60)
        return "\(f.string(from: d)) (\(tz))"
    }

    // MARK: the tools

    /// Every tool his model is given: Tool Mac Tool Run's (but `say`, which is Peter's own), then his.
    static func tools(_ c: Catalog) -> [Brain.Tool] {
        c.tools.filter { $0.name != "say" }.map(spec) + own
    }

    /// One of Tool Mac Tool Run's tools, as a JSON schema.
    static func spec(_ t: ToolInfo) -> Brain.Tool {
        var properties: [String: Any] = [:]
        for a in t.args {
            var p: [String: Any]
            switch a.type.lowercased() {
            case "list", "array": p = ["type": "array", "items": ["type": "string"]]
            case "integer", "int": p = ["type": "integer"]
            case "number", "double": p = ["type": "number"]
            case "boolean", "bool": p = ["type": "boolean"]
            case "object": p = ["type": "object"]
            default: p = ["type": "string"]
            }
            if !a.about.isEmpty { p["description"] = a.about }
            properties[a.name] = p
        }
        return Brain.Tool(name: t.name, description: t.description, schema: ["type": "object", "properties": properties, "required": t.args.filter(\.required).map(\.name)])
    }

    static func string(_ about: String) -> [String: Any] { ["type": "string", "description": about] }

    static func choice(_ about: String, _ values: [String]) -> [String: Any] { ["type": "string", "enum": values, "description": about] }

    /// Peter's own tools.
    static let own: [Brain.Tool] = [
        Brain.Tool(name: "schedule",
                   description: "Something for later, kept by Peter: a reminder (said back to the client when it's due) or a request (done then, as if the client had asked it then, and how it went said back). Also lists what's scheduled for this client, and takes one off.",
                   schema: ["type": "object", "required": ["op"], "properties": [
                       "op": choice("remind, later, list or cancel", ["remind", "later", "list", "cancel"]),
                       "when": string("remind, later: when, as said: in 20 minutes, at 17:30, tomorrow 8am, Friday 9:00, 2026-10-30 14:00"),
                       "repeat": string("remind, later (optional): how often after that: \(When.Repeat.choices.joined(separator: ", ")), or every N minutes"),
                       "text": string("remind: what to tell the client then, with every detail; later: the whole request to carry out then"),
                       "which": string("cancel: its number, a word from it, or all"),
                   ] as [String: Any]]),
        Brain.Tool(name: "requests",
                   description: "What this client asked you for before (each numbered), how each went, what a run printed, and stopping one. A run waiting for Run on the Mac is taken back; a running one is stopped.",
                   schema: ["type": "object", "required": ["op"], "properties": [
                       "op": choice("list, status, show (what it gave back, in full), stop, or done (no more news of it)", ["list", "status", "show", "stop", "done"]),
                       "which": string("status, show, stop, done: its number, a word from it (\"the backup\"), a time (\"the one around 3\"), or \"the last one\""),
                       "since": string("list: today (the default), recently, or a time (since 9am)"),
                   ] as [String: Any]]),
        Brain.Tool(name: "access",
                   description: "Who may get into Storage Spaces (the person's notes, MEMORY and the mind; Super Face's notes): the requests waiting for a yes or a no, a yes or a no to one, letting an app in, and taking back what it was let into. Only the person, in Peter's window, can say yes: an app can't, through you.",
                   schema: ["type": "object", "required": ["op"], "properties": [
                       "op": choice("requests, approve, deny, grant or revoke", ["requests", "approve", "deny", "grant", "revoke"]),
                       "number": ["type": "integer", "description": "approve, deny: the request's number"],
                       "app": string("grant, revoke: the app's name"),
                       "place": string("grant: what of theirs: my library, my memory, the mind, Super Face's prompt, Super Face's memory"),
                       "access": choice("grant: read or write", ["read", "write"]),
                       "hours": ["type": "number", "description": "approve (optional): for how long"],
                   ] as [String: Any]]),
        Brain.Tool(name: "space_notes",
                   description: "Notes in Storage Spaces outside the person's library: super/prompt (Super Face's standing instructions, the note \"instructions\"), super/memory (Super Face's playbook, the note \"playbook\"), or an app's own, other/<its name in lower case with dashes>. Read, write (replaces it), append (a line at its end), list, search or delete.",
                   schema: ["type": "object", "required": ["place", "op"], "properties": [
                       "place": string("super/prompt, super/memory, or other/<app>"),
                       "op": choice("read, write, append, list, search or delete", ["read", "write", "append", "list", "search", "delete"]),
                       "name": string("the note's name: instructions, playbook…"),
                       "text": string("write, append: the text, word for word"),
                       "q": string("search: the words"),
                   ] as [String: Any]]),
    ]

    // MARK: one request

    /// The numbers of the requests a reply was about, as its tool calls go (their news isn't told twice).
    final class Numbers: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Int] = []
        func add(_ n: Int) { lock.withLock { list.append(n) } }
        var all: [Int] { lock.withLock { list } }
    }

    /// The answer to what was said: his model works it through with his tools. `scheduled`:
    /// it's a request for later, come due.
    func sayAnswer(_ raw: String, client: String, scheduled: Schedule.Item? = nil) async -> SayReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return SayReply(answer: "Say what you want done, in plain words, with every detail it needs.", outcome: .nothing)
        }
        let catalog = await toolMac.catalog()
        let about = Numbers()
        // Numbered as it's asked (the runs it starts come after it), its answer filled in after.
        let first = Self.firstLine(text)
        let n = await sayLog.add(client, said: first, form: scheduled == nil ? "said" : "later", what: Self.clean(first, limit: 80), short: Self.clean(first, limit: 50), state: .answered)
        var message = Self.message(text, client: client, scheduled: scheduled)
        if !catalog.reachable { message = "(Tool Mac Tool Run isn't answering right now: only Peter's own tools work.)\n" + message }
        let run = await brain.run(system: Self.instructions(catalog.guide), user: message, tools: Self.tools(catalog), client: client) { [self] call in
            await self.act(call, client: client, said: text, catalog: catalog, about: about)
        }
        var answer = run.answer
        if let e = run.error {
            answer = "I couldn't do that: \(e)."
            if !catalog.reachable { answer += " (Tool Mac Tool Run isn't answering either.)" }
        }
        await sayLog.update(client, n) { [answer, error = run.error] e in
            e.state = error.map { .failed($0) } ?? .answered
            e.told = e.state.key
            e.result = answer
        }
        return SayReply(answer: answer, about: about.all + [n], outcome: Self.outcome(run, catalog))
    }

    /// How a request went, from its tool calls: a run asked for, something done, or nothing.
    static func outcome(_ run: Brain.Run, _ catalog: Catalog) -> Outcome {
        if run.error != nil { return .error }
        let worked = run.steps.filter { !$0.failed }
        if worked.contains(where: { catalog.tool($0.name)?.asks ?? false }) { return .asked }
        return worked.isEmpty ? .nothing : .done
    }

    /// One tool call of his model's, done: what it gave back (JSON, as the model reads it), and whether it failed.
    func act(_ call: Brain.ToolCall, client: String, said: String, catalog: Catalog, about: Numbers) async -> (content: String, failed: Bool) {
        let args = call.arguments
        switch call.name {
        case "schedule":
            return await scheduleTool(args, client: client)
        case "requests":
            return await requestsTool(args, client: client, about: about)
        case "access":
            let (status, j) = await accessTool(args, client: client)
            return (Self.result(j), Self.failed(status, j))
        case "space_notes":
            return await spaceNotes(args)
        default:
            let asks = catalog.tool(call.name)?.asks ?? false
            let (status, j) = await callTool(call.name, args, why: Self.sayWhy(client, said), async: asks)
            if asks { return await asked(call.name, args, status, j, client: client, said: said, about: about) }
            return (Self.result(j), Self.failed(status, j))
        }
    }

    /// A run asked for on the Mac: kept, followed, and the client told how it went once it's over.
    func asked(_ tool: String, _ args: [String: Any], _ status: Int, _ j: [String: Any], client: String, said: String, about: Numbers) async -> (content: String, failed: Bool) {
        guard status == 202, let id = (j["request"] as? String).flatMap(UUID.init(uuidString:)) else { return (Self.result(j), true) }
        let short: String
        switch tool {
        case "run_script", "run_flow":
            let name = Self.text(args["script"]) ?? Self.text(args["flow"]) ?? Self.text(args["name"]) ?? tool
            short = "the " + SayWords.spokenName(name)
        case "run_flow_code": short = Self.text(args["name"]).map { "the Flow code \($0)" } ?? "the Flow code"
        default: short = "the " + tool.replacingOccurrences(of: "_", with: " ")
        }
        let n = await sayLog.add(client, said: Self.firstLine(said), form: tool, what: short, short: short, state: .waiting, asks: true, request: id)
        about.add(n)
        return (JSON.string(["ok": true, "number": n, "state": "waiting for the person to click Run on the Mac",
                             "said": "Asked for \(short). The client is told how it went the moment it's over."]), false)
    }

    /// The `space_notes` tool: a notes store of Super Face's space, or an app's own.
    func spaceNotes(_ a: [String: Any]) async -> (content: String, failed: Bool) {
        let place = (Self.text(a["place"]) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let parts = place.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, (parts[0] == "super" && ["prompt", "memory"].contains(parts[1])) || (parts[0] == "other" && !parts[1].isEmpty) else {
            return Self.fail("place is super/prompt, super/memory, or other/<app>, not \"\(place)\". The person's own notes are the library tool's.")
        }
        guard await storage.ready() else { return Self.fail(await storage.problem ?? "Storage Spaces isn't answering. Is it open?") }
        var body = a
        body["place"] = nil
        let (status, j) = await storage.notes(parts[0], parts[1], body)
        return (Self.result(j), Self.failed(status, j))
    }

    /// What a tool gave back, as the model reads it: its JSON, without what's only for programs,
    /// and no longer than a model can take in.
    static func result(_ j: [String: Any]) -> String {
        var j = j
        j["next"] = nil
        let s = JSON.string(j)
        return s.count > 8000 ? String(s.prefix(8000)) + "… (cut short)" : s
    }

    static func ok(_ said: String) -> (content: String, failed: Bool) { (JSON.string(["ok": true, "said": said]), false) }

    static func fail(_ error: String) -> (content: String, failed: Bool) { (JSON.string(["ok": false, "error": error]), true) }
}
