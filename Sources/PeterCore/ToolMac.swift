import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A script or a flow in the person's folder, as Tool Mac Tool Run lists it (`GET /api/scripts`,
/// `GET /api/flows`): what Peter makes its template from.
public struct FolderItem: Sendable, Equatable {
    /// Its name, as Tool Mac Tool Run runs it by ("utilities/weather.py", "translate.flow").
    public var id: String
    /// Its file name without the extension ("weather").
    public var title: String
    /// scripts, utilities, browser, or composer (a flow).
    public var group: String
    public var summary: String?
    public var inputs: [ScriptInput]
    public var tags: [String]
    /// Its header's `# Say:` lines.
    public var say: [String]
    public var dangers: [String]

    public var isFlow: Bool { group == "composer" }

    public init(id: String, title: String, group: String, summary: String? = nil, inputs: [ScriptInput] = [], tags: [String] = [], say: [String] = [], dangers: [String] = []) {
        self.id = id
        self.title = title
        self.group = group
        self.summary = summary
        self.inputs = inputs
        self.tags = tags
        self.say = say
        self.dangers = dangers
    }

    /// From the JSON Tool Mac Tool Run gives it in.
    static func from(_ j: [String: Any], flow: Bool) -> FolderItem? {
        guard let id = j["name"] as? String, !id.isEmpty else { return nil }
        let title = j["title"] as? String ?? ((id as NSString).lastPathComponent as NSString).deletingPathExtension
        let inputs = (j["inputs"] as? [[String: Any]] ?? []).map { i in
            ScriptInput(prompt: i["prompt"] as? String ?? "", kind: (i["kind"] as? String) == "stdin" ? .text : .argument,
                        optional: i["optional"] as? Bool ?? false, why: i["why"] as? String)
        }
        return FolderItem(id: id, title: title, group: flow ? "composer" : j["group"] as? String ?? "scripts", summary: j["summary"] as? String,
                          inputs: inputs, tags: j["tags"] as? [String] ?? [], say: j["say"] as? [String] ?? [], dangers: j["dangers"] as? [String] ?? [])
    }
}

/// One of Tool Mac Tool Run's tools (`GET /api/tools`): its name, what it does, what it takes.
public struct ToolInfo: Sendable, Equatable {
    public struct Arg: Sendable, Equatable {
        public var name: String
        public var type: String
        public var required: Bool
        public var about: String
    }

    public var name: String
    public var description: String
    public var args: [Arg]
    /// It waits for the person to click Run on the Mac.
    public var asks: Bool

    public init(name: String, description: String = "", args: [Arg] = [], asks: Bool = false) {
        self.name = name
        self.description = description
        self.args = args
        self.asks = asks
    }

    static func from(_ j: [String: Any]) -> ToolInfo? {
        guard let name = j["name"] as? String, !name.isEmpty, j["on"] as? Bool != false else { return nil }
        let args = (j["args"] as? [[String: Any]] ?? []).compactMap { a -> Arg? in
            guard let n = a["name"] as? String else { return nil }
            return Arg(name: n, type: a["type"] as? String ?? "string", required: a["required"] as? Bool ?? false, about: a["about"] as? String ?? "")
        }
        return ToolInfo(name: name, description: j["description"] as? String ?? "", args: args, asks: j["asks_on_the_mac"] as? Bool ?? false)
    }
}

/// What Tool Mac Tool Run has now: its tools, and the scripts and flows in the person's folder.
/// Peter's templates are made from it, so what Tool Mac Tool Run adds is there the day it ships.
public struct Catalog: Sendable {
    public var tools: [ToolInfo] = []
    public var scripts: [FolderItem] = []
    public var flows: [FolderItem] = []
    /// It answered.
    public var reachable = false
    /// Why there's nothing, or less than there should be.
    public var error: String?
    public var fetched = Date.distantPast
    /// Its version, as `GET /api/health` says.
    public var version: String?

    public init(tools: [ToolInfo] = [], scripts: [FolderItem] = [], flows: [FolderItem] = [], reachable: Bool = true) {
        self.tools = tools
        self.scripts = scripts
        self.flows = flows
        self.reachable = reachable
    }

    public func tool(_ name: String) -> ToolInfo? { tools.first { $0.name == name } }
}

/// Tool Mac Tool Run, over its HTTP API: everything Peter does, he does through it. Its tools,
/// scripts and flows (cached a few seconds), a tool called (`POST /api/tools/{name}`), and the
/// requests that wait for the Mac followed (`GET /api/requests/{id}`), taken back, or stopped.
public actor ToolMac {
    /// Sends one request: its status and body. (Tests give their own.)
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let defaultURL = "http://127.0.0.1:8768"
    /// Who Peter is to Tool Mac Tool Run (the card on the Mac says so).
    public static let client = "Peter"

    public var url: String
    let send: Send
    private var cached = Catalog(reachable: false)
    /// How long the catalog is kept before it's asked for again.
    let fresh: TimeInterval

    public init(url: String = ToolMac.defaultURL, fresh: TimeInterval = 15, send: @escaping Send = ToolMac.live) {
        self.url = url
        self.fresh = fresh
        self.send = send
    }

    public func setURL(_ u: String) {
        url = u
        cached.fetched = .distantPast
    }

    var base: String {
        var s = url.trimmingCharacters(in: .whitespaces)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// One call: its status and JSON (an error said as `{"ok": false, "error"}` when nothing answers).
    public func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 15) async -> (Int, [String: Any]) {
        guard let u = URL(string: base + path) else { return (0, ["ok": false, "error": "\(base) isn't an address"]) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(Self.client, forHTTPHeaderField: "X-Client")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = JSON.data(body)
        }
        do {
            let (data, status) = try await send(r)
            return (status, JSON.object(data) ?? (data.isEmpty ? [:] : ["text": String(decoding: data, as: UTF8.self)]))
        } catch {
            return (0, ["ok": false, "code": "unreachable", "error": "Tool Mac Tool Run isn't answering at \(base). Is it open, with its API on?"])
        }
    }

    /// What it has now (asked again once it's a few seconds old, or with `refresh`).
    public func catalog(refresh: Bool = false) async -> Catalog {
        if !refresh, Date().timeIntervalSince(cached.fetched) < fresh { return cached }
        var c = Catalog(reachable: false)
        c.fetched = Date()
        let (status, manifest) = await call("GET", "/api/tools", timeout: 5)
        guard status != 0 else {
            c.error = manifest["error"] as? String
            cached = c
            return c
        }
        c.reachable = true
        guard (200..<300).contains(status) else {
            c.error = status == 404 ? "this Tool Mac Tool Run is too old to list its tools: update it" : "it answered \(status) for its tools: \(manifest["error"] as? String ?? "")"
            cached = c
            return c
        }
        c.tools = (manifest["tools"] as? [[String: Any]] ?? []).compactMap(ToolInfo.from)
        let (ss, sj) = await call("GET", "/api/scripts", timeout: 5)
        let (fs, fj) = await call("GET", "/api/flows", timeout: 5)
        if (200..<300).contains(ss) { c.scripts = (sj["scripts"] as? [[String: Any]] ?? []).compactMap { FolderItem.from($0, flow: false) } }
        if (200..<300).contains(fs) { c.flows = (fj["flows"] as? [[String: Any]] ?? []).compactMap { FolderItem.from($0, flow: true) } }
        let (hs, hj) = await call("GET", "/api/health", timeout: 3)
        if (200..<300).contains(hs) { c.version = hj["version"] as? String }
        cached = c
        return c
    }

    /// A tool called, as Peter, for a client (`why`: in the client's own words, shown on the Mac).
    public func tool(_ name: String, _ args: [String: Any], why: String, async: Bool) async -> (Int, [String: Any]) {
        var body: [String: Any] = ["arguments": args, "client": Self.client, "why": why]
        if async { body["async"] = true }
        let path = "/api/tools/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)?next=false"
        return await call("POST", path, body, timeout: async ? 30 : 120)
    }

    /// Where a request that waits for the Mac is (`peek`: without collecting it).
    public func request(_ id: String, peek: Bool) async -> (Int, [String: Any]) {
        await call("GET", "/api/requests/\(id)\(peek ? "?peek=true" : "")", timeout: 10)
    }

    /// Takes a request back while it waits for Run (the card goes): whether it was.
    public func withdraw(_ id: String) async -> Bool {
        let (status, _) = await call("DELETE", "/api/requests/\(id)", timeout: 10)
        return (200..<300).contains(status)
    }

    /// Stops a run: whether it was asked to stop.
    public func stop(run: String) async -> Bool {
        let (status, _) = await call("POST", "/api/runs/\(run)/stop", ["client": Self.client], timeout: 10)
        return (200..<300).contains(status)
    }

    /// Over the network.
    public static let live: Send = { request in
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Data, Int), Error>) in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return done.resume(throwing: error) }
                done.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }
}
