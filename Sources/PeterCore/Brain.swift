import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Peter's model: it reads what a client asked, does it with Peter's tools (Tool Mac Tool Run's,
/// and his own: the schedule, what a client asked for, access, the notes in Storage Spaces), and
/// writes the answer in plain words. Every request is read by it: there are no templates, and
/// nothing a client says has to fit a shape.
///
/// It's stateless: each request is one exchange, the instructions, the client's message, and the
/// tool calls it makes for that message, then the answer. Nothing of it is kept for the next one.
///
/// Any model behind an OpenAI-style chat completions address (LM Studio, llama.cpp, vLLM,
/// OpenAI, OpenRouter…), Ollama (asked on its own `/api/chat`, so its context can be set), or
/// Anthropic's Messages API. Its settings are a file of their own (`model.json` in Peter's
/// Application Support folder, or where `PETER_MODEL` says), changed with `POST /api/model`.
/// With Ollama and the model "auto" (the default), it's the best one Ollama has.
public actor Brain {
    /// How to reach the model, and how far it may go for one request.
    public struct Settings: Codable, Equatable, Sendable {
        /// Asked at all (without it, Peter can do nothing).
        public var on = true
        /// "openai" (a chat completions address, Ollama's too) or "anthropic" (the Messages API).
        public var api = "openai"
        public var url = Settings.ollama
        public var model = Settings.auto
        /// Sent as a bearer token (openai) or `x-api-key` (anthropic); empty: none, or the
        /// provider's own environment variable when the address is the provider's.
        public var key = ""
        /// Seconds to wait for each of the model's answers.
        public var timeout: Double = 120
        /// anthropic: `output_config.effort` ("low" by default; empty: not sent).
        public var effort = "low"
        /// Ollama: how many tokens it reads (`num_ctx`). Its own default is smaller than the
        /// instructions and the tools, and it cuts without saying so.
        public var context = 16384
        /// The most rounds of tool calls for one request.
        public var steps = 8

        public static let ollama = "http://127.0.0.1:11434/v1/chat/completions"
        /// The model: the best one Ollama has.
        public static let auto = "auto"
        public static let anthropicURL = "https://api.anthropic.com/v1/messages"
        public static let anthropicModel = "claude-opus-5-5"
        public static let anthropicVersion = "2026-10-21"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let d = Settings()
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
            api = try c.decodeIfPresent(String.self, forKey: .api) ?? d.api
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? d.key
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
            context = try c.decodeIfPresent(Int.self, forKey: .context) ?? d.context
            steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? d.steps
            // The translator's settings ("sure" was its own) waited 20 seconds for one short
            // answer: a request that does things takes longer.
            timeout = c.contains(.sure) ? d.timeout : try c.decodeIfPresent(Double.self, forKey: .timeout) ?? d.timeout
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(on, forKey: .on)
            try c.encode(api, forKey: .api)
            try c.encode(url, forKey: .url)
            try c.encode(model, forKey: .model)
            try c.encode(key, forKey: .key)
            try c.encode(timeout, forKey: .timeout)
            try c.encode(effort, forKey: .effort)
            try c.encode(context, forKey: .context)
            try c.encode(steps, forKey: .steps)
        }

        enum Key: String, CodingKey { case on, api, url, model, key, timeout, effort, context, steps, sure }

        var isAnthropic: Bool { api.lowercased() == "anthropic" }

        /// It's Ollama: an OpenAI-style address on Ollama's port (11434). It's asked on its own
        /// `/api/chat` instead, which takes how much it reads.
        public var isOllama: Bool { !isAnthropic && (URL(string: url)?.port == 11434) }

        /// The settings changed by what was sent (`{"on", "api", "url", "model", "key",
        /// "timeout", "effort", "context", "steps"}`; anything else is left alone); a new `api`
        /// without a `url` or `model` takes that api's own.
        public func changed(by f: [String: Any]) throws -> Settings {
            var s = self
            func string(_ k: String) -> String? {
                if let v = f[k] as? String { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            }
            func number(_ k: String) -> Double? {
                if let n = f[k] as? NSNumber { return n.doubleValue }
                return (f[k] as? String).flatMap(Double.init)
            }
            if let v = f["on"] as? Bool { s.on = v } else if let v = string("on") { s.on = ["1", "true", "yes", "on"].contains(v.lowercased()) }
            if let api = string("api")?.lowercased() {
                guard ["openai", "anthropic"].contains(api) else { throw BrainError("api is \"openai\" (a chat completions address: Ollama, LM Studio, OpenAI…) or \"anthropic\"") }
                if api != s.api.lowercased() {
                    s.api = api
                    if f["url"] == nil { s.url = api == "anthropic" ? Self.anthropicURL : Self.ollama }
                    if f["model"] == nil { s.model = api == "anthropic" ? Self.anthropicModel : Settings().model }
                }
            }
            if let v = string("url") {
                guard let u = URL(string: v), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
                    throw BrainError("url is the model's address, like \(Self.ollama)")
                }
                s.url = v
            }
            if let v = string("model") { s.model = v.isEmpty ? Self.auto : v }
            if let v = string("key") { s.key = v }
            if let v = number("timeout") { s.timeout = max(5, min(600, v)) }
            if let v = string("effort")?.lowercased() { s.effort = v }
            if let v = number("context") { s.context = max(2048, min(262_144, Int(v))) }
            if let v = number("steps") { s.steps = max(1, min(20, Int(v))) }
            return s
        }

        /// As they're kept in Storage Spaces (PETER/SETTINGS/model): everything but the key.
        public var kept: [String: Any] {
            ["on": on, "api": api, "url": url, "model": model, "timeout": timeout, "effort": effort, "context": context, "steps": steps]
        }

        /// As `GET /api/model` shows them: the key only as whether there is one.
        public var json: [String: Any] {
            var out = kept
            out["key"] = key.isEmpty ? (envKey == nil ? "" : "from the environment") : "set"
            return out
        }

        /// The provider's own key from the environment, only for the provider's own address.
        var envKey: String? {
            let host = URL(string: url)?.host?.lowercased() ?? ""
            let env = ProcessInfo.processInfo.environment
            if isAnthropic, host == "api.anthropic.com" { return env["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
            if !isAnthropic, host == "api.openai.com" { return env["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
            return nil
        }
    }

    /// One of Peter's tools, as the model is given it: a JSON schema for its arguments.
    public struct Tool: @unchecked Sendable {
        public var name: String
        public var description: String
        public var schema: [String: Any]

        public init(name: String, description: String, schema: [String: Any]) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    /// A tool the model called, with its arguments.
    public struct ToolCall: @unchecked Sendable {
        public var id: String
        public var name: String
        public var arguments: [String: Any]
    }

    /// One tool call, done: what it gave back.
    public struct Step: @unchecked Sendable {
        public var name: String
        public var arguments: [String: Any]
        public var result: String
        public var failed: Bool
    }

    /// One request, start to end: the answer, the tool calls on the way, and what it was given.
    public struct Run: @unchecked Sendable {
        public var answer = ""
        public var steps: [Step] = []
        /// Why there's no answer: it's off, it couldn't be reached, it declined, it ran out of steps.
        public var error: String?
        public var model = ""
        public var seconds = 0.0
        public var system = ""
        public var user = ""
    }

    /// One request, kept for `GET /api/model` (the latest 50).
    public struct Call: Sendable {
        public let at: Date
        public let client: String
        public let run: Run
    }

    /// Sends one request to the model: its body and status.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    public static var defaultFile: URL {
        if let path = ProcessInfo.processInfo.environment["PETER_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Peter.support.appendingPathComponent("model.json")
    }

    let file: URL?
    let send: Send
    public private(set) var settings: Settings
    public private(set) var calls: [Call] = []
    /// After the model couldn't be reached, it isn't asked again for a while (each request would wait).
    var resting: Date?
    static let rest: TimeInterval = 30
    /// Told when the model starts and stops working (the app plays a sound while it does).
    var onBusy: (@Sendable (Bool) -> Void)?
    /// How many requests are being worked on now.
    public private(set) var working = 0
    /// What "auto" was last taken as, and when (Ollama's models are asked again after a while).
    var picked: (model: String, at: Date)?

    public func observe(_ busy: @escaping @Sendable (Bool) -> Void) { onBusy = busy }

    /// Settings from `file` (nil: kept in memory only), or as given.
    public init(file: URL? = Brain.defaultFile, settings: Settings? = nil, send: @escaping Send = Brain.live) {
        self.file = file
        self.send = send
        if let settings {
            self.settings = settings
        } else if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = Settings()
        }
    }

    /// Changes the settings, and keeps them (the file only its owner can read: it may hold a key).
    @discardableResult
    public func change(_ f: [String: Any]) throws -> Settings {
        let changed = try settings.changed(by: f)
        guard changed != settings else { return settings }
        settings = changed
        resting = nil
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return settings
    }

    /// When the settings' file was last written (nil: none, or kept in memory only).
    public var savedAt: Date? {
        file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
    }

    /// What "auto" was last taken as.
    public var pickedModel: String? { picked?.model }

    /// Whether it would be asked now.
    public var ready: Bool { settings.on && (resting.map { Date() >= $0 } ?? true) }

    /// The models Ollama has (`GET /api/tags`, at the address the settings' URL has, else
    /// Ollama's own), A to Z, the embedding ones left out: what the person picks from. Nil when
    /// Ollama isn't answering.
    public func ollamaModels() async -> [String]? {
        var c = URLComponents(string: settings.isAnthropic ? Settings.ollama : settings.url) ?? URLComponents(string: Settings.ollama)!
        c.path = "/api/tags"
        c.query = nil
        guard let url = c.url, let (data, status) = try? await send(URLRequest(url: url, timeoutInterval: 3)), (200..<300).contains(status),
              let list = JSON.object(data)?["models"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }.filter { !$0.contains("embed") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The models Peter likes best, in order: the first Ollama has is "auto". Each calls tools.
    static let preferred = ["qwen3", "qwen2.5", "llama3.3", "llama3.1", "mistral-small", "llama3.2", "mistral"]

    /// What "auto" is: the best model Ollama has (asked again every five minutes); nil when it has none.
    func pick(_ s: Settings) async -> String? {
        if s.isAnthropic { return Settings.anthropicModel }
        if let p = picked, Date().timeIntervalSince(p.at) < 300 { return p.model }
        guard var c = URLComponents(string: s.url) else { return nil }
        c.path = "/api/tags"
        c.query = nil
        guard let url = c.url else { return nil }
        guard let (data, status) = try? await send(URLRequest(url: url, timeoutInterval: 3)), (200..<300).contains(status),
              let names = (JSON.object(data)?["models"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }), !names.isEmpty else { return nil }
        let model = Self.best(names)
        picked = (model, Date())
        return model
    }

    /// The best of the models there are, by `preferred` (the first there is, else the first).
    public static func best(_ names: [String]) -> String {
        for p in preferred { if let hit = names.first(where: { $0.lowercased().hasPrefix(p) && !$0.contains("embed") }) { return hit } }
        return names.first { !$0.contains("embed") } ?? names[0]
    }

    // MARK: one request

    /// What was said to the model, and what it said, in the order they came.
    enum Turn {
        case user(String)
        /// Its answer: its words, the tools it called, and the answer as it came (Anthropic's
        /// content blocks go back exactly as they were).
        case assistant(String, [ToolCall], Any?)
        case results([(call: ToolCall, content: String, failed: Bool)])
    }

    /// One request worked through: the model is given the instructions, the message and the
    /// tools, and each tool it calls is done (`execute`, one at a time, in order) and given back,
    /// until it answers in words or has used up its steps.
    public func run(system: String, user: String, tools: [Tool], client: String,
                    execute: @Sendable (ToolCall) async -> (content: String, failed: Bool)) async -> Run {
        var s = settings
        var run = Run()
        run.model = s.model
        run.system = system
        run.user = user
        guard s.on else {
            run.error = "my model is off (it's switched on in my window, or with POST /api/model {\"on\": true})"
            return run
        }
        if let r = resting, Date() < r {
            run.error = "my model couldn't be reached a moment ago; it's asked again after \(Int(Self.rest)) seconds"
            return run
        }
        let started = Date()
        working += 1
        if working == 1 { onBusy?(true) }
        defer {
            working -= 1
            if working == 0 { onBusy?(false) }
        }
        if s.model == Settings.auto || s.model.isEmpty {
            guard let model = await pick(s) else {
                run.error = "there's no model to ask: Ollama has none (ollama pull qwen3:8b), or isn't running"
                resting = Date().addingTimeInterval(Self.rest)
                record(client, run)
                return run
            }
            s.model = model
            run.model = model
        }
        var turns: [Turn] = [.user(user)]
        let names = Set(tools.map(\.name))
        var round = 0
        while true {
            let reply: Reply
            do {
                let request = try Self.request(s, system: system, turns: turns, tools: tools)
                let (data, status) = try await send(request)
                guard (200..<300).contains(status) else {
                    run.error = "my model answered \(status): " + String(decoding: data.prefix(300), as: UTF8.self)
                    break
                }
                guard let r = Self.reply(data, s, tools: names) else {
                    run.error = "my model's answer couldn't be read: " + String(decoding: data.prefix(300), as: UTF8.self)
                    break
                }
                reply = r
            } catch {
                run.error = "my model couldn't be reached at \(s.url): \(error.localizedDescription)"
                resting = Date().addingTimeInterval(Self.rest)
                break
            }
            if let declined = reply.declined {
                run.error = declined
                break
            }
            resting = nil
            guard !reply.calls.isEmpty else {
                run.answer = reply.text
                if run.answer.isEmpty { run.error = "my model answered with nothing" }
                break
            }
            if round >= s.steps {
                run.error = "that took more than \(s.steps) steps, so I stopped (I had used: \(run.steps.map(\.name).joined(separator: ", ")))"
                break
            }
            round += 1
            turns.append(.assistant(reply.text, reply.calls, reply.raw))
            var results: [(call: ToolCall, content: String, failed: Bool)] = []
            for call in reply.calls {
                let (content, failed): (String, Bool)
                if names.contains(call.name) {
                    (content, failed) = await execute(call)
                } else {
                    (content, failed) = ("{\"ok\": false, \"error\": \"There's no tool called \(call.name). The tools: \(names.sorted().joined(separator: ", ")).\"}", true)
                }
                results.append((call, content, failed))
                run.steps.append(Step(name: call.name, arguments: call.arguments, result: content, failed: failed))
            }
            turns.append(.results(results))
        }
        run.seconds = Date().timeIntervalSince(started)
        record(client, run)
        return run
    }

    func record(_ client: String, _ run: Run) {
        calls.append(Call(at: Date(), client: client, run: run))
        if calls.count > 50 { calls.removeFirst(calls.count - 50) }
    }

    // MARK: the three ways of asking

    enum Flavor { case ollama, openai, anthropic }

    static func flavor(_ s: Settings) -> Flavor { s.isAnthropic ? .anthropic : s.isOllama ? .ollama : .openai }

    static func request(_ s: Settings, system: String, turns: [Turn], tools: [Tool]) throws -> URLRequest {
        let flavor = flavor(s)
        guard var c = URLComponents(string: s.url), c.host != nil else { throw BrainError("\(s.url) isn't an address") }
        if flavor == .ollama {
            c.path = "/api/chat"
            c.query = nil
        }
        guard let url = c.url else { throw BrainError("\(s.url) isn't an address") }
        var r = URLRequest(url: url, timeoutInterval: s.timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = s.key.isEmpty ? s.envKey ?? "" : s.key
        var body: [String: Any]
        switch flavor {
        case .anthropic:
            r.setValue(Settings.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { r.setValue(key, forHTTPHeaderField: "x-api-key") }
            body = ["model": s.model, "max_tokens": 16000, "system": system, "messages": anthropicMessages(turns),
                    "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }]
            if !s.effort.isEmpty { body["output_config"] = ["effort": s.effort] }
            // On Anthropic's own API, a request its safeguards decline goes to another model.
            if url.host?.lowercased() == "api.anthropic.com" {
                r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .ollama:
            body = ["model": s.model, "stream": false, "keep_alive": "30m", "messages": [["role": "system", "content": system]] + ollamaMessages(turns),
                    "tools": functions(tools), "options": ["num_ctx": s.context, "temperature": 0] as [String: Any]]
        case .openai:
            if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": s.model, "stream": false, "temperature": 0, "messages": [["role": "system", "content": system]] + openaiMessages(turns),
                    "tools": functions(tools)]
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func functions(_ tools: [Tool]) -> [[String: Any]] {
        tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema] as [String: Any]] }
    }

    static func ollamaMessages(_ turns: [Turn]) -> [[String: Any]] {
        turns.flatMap { t -> [[String: Any]] in
            switch t {
            case let .user(text): return [["role": "user", "content": text]]
            case let .assistant(text, calls, _):
                return [["role": "assistant", "content": text, "tool_calls": calls.map { ["function": ["name": $0.name, "arguments": $0.arguments] as [String: Any]] }]]
            case let .results(rs): return rs.map { ["role": "tool", "tool_name": $0.call.name, "content": $0.content] }
            }
        }
    }

    static func openaiMessages(_ turns: [Turn]) -> [[String: Any]] {
        turns.flatMap { t -> [[String: Any]] in
            switch t {
            case let .user(text): return [["role": "user", "content": text]]
            case let .assistant(text, calls, _):
                return [["role": "assistant", "content": text.isEmpty ? NSNull() : text as Any,
                         "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": JSON.string($0.arguments)] as [String: Any]] as [String: Any] }]]
            case let .results(rs): return rs.map { ["role": "tool", "tool_call_id": $0.call.id, "content": $0.content] }
            }
        }
    }

    static func anthropicMessages(_ turns: [Turn]) -> [[String: Any]] {
        turns.map { t -> [String: Any] in
            switch t {
            case let .user(text): return ["role": "user", "content": text]
            case let .assistant(text, calls, raw):
                if let blocks = raw as? [[String: Any]] { return ["role": "assistant", "content": blocks] }
                var blocks: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
                blocks += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.arguments] }
                return ["role": "assistant", "content": blocks]
            case let .results(rs):
                return ["role": "user", "content": rs.map { ["type": "tool_result", "tool_use_id": $0.call.id, "content": $0.content, "is_error": $0.failed] as [String: Any] }]
            }
        }
    }

    /// What the model answered: its words, the tools it called, and why it declined, if it did.
    struct Reply {
        var text = ""
        var calls: [ToolCall] = []
        var raw: Any?
        var declined: String?
    }

    static func reply(_ data: Data, _ s: Settings, tools: Set<String>) -> Reply? {
        guard let o = JSON.object(data) else { return nil }
        var r = Reply()
        switch flavor(s) {
        case .anthropic:
            if o["stop_reason"] as? String == "refusal" {
                r.declined = "my model declined to do that"
                return r
            }
            guard let blocks = o["content"] as? [[String: Any]] else { return nil }
            r.raw = blocks
            r.text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            r.calls = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { b in
                guard let name = b["name"] as? String else { return nil }
                return ToolCall(id: b["id"] as? String ?? UUID().uuidString, name: name, arguments: b["input"] as? [String: Any] ?? [:])
            }
        case .ollama, .openai:
            let message = (o["message"] as? [String: Any]) ?? ((o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            guard let message else { return nil }
            r.text = message["content"] as? String ?? ""
            r.calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { c in
                let f = c["function"] as? [String: Any] ?? c
                guard let name = f["name"] as? String else { return nil }
                return ToolCall(id: c["id"] as? String ?? "call_" + UUID().uuidString.prefix(8).lowercased(), name: name, arguments: arguments(f["arguments"]))
            }
        }
        r.text = withoutThinking(r.text)
        // A small model sometimes writes its call as words instead of calling it.
        if r.calls.isEmpty, let call = callInText(r.text, tools: tools) {
            r.calls = [call]
            r.text = ""
        }
        return r
    }

    /// A tool's arguments, as an object or as the JSON text of one.
    static func arguments(_ v: Any?) -> [String: Any] {
        if let d = v as? [String: Any] { return d }
        if let s = v as? String, let d = JSON.object(Data(s.utf8)) { return d }
        return [:]
    }

    /// Its words without what it thought first (`<think>…</think>`).
    static func withoutThinking(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool call written out as its answer: `{"name": "web_search", "arguments": {…}}`, alone
    /// (in a fence, or in `<tool_call>` tags, at most), naming one of the tools.
    static func callInText(_ text: String, tools: Set<String>) -> ToolCall? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"^```(json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^<tool_call>\s*|\s*</tool_call>$"#, with: "", options: .regularExpression)
        guard t.hasPrefix("{"), t.hasSuffix("}"), let o = JSON.object(Data(t.utf8)), let name = o["name"] as? String, tools.contains(name) else { return nil }
        return ToolCall(id: "call_" + UUID().uuidString.prefix(8).lowercased(), name: name, arguments: arguments(o["arguments"] ?? o["parameters"]))
    }

    /// The model asked over the network.
    public static let live: Send = { request in
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Data, Int), Error>) in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return done.resume(throwing: error) }
                done.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }
}

public struct BrainError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ d: String) { description = d }
}
