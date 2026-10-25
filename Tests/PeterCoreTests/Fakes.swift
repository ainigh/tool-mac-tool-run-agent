import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PeterCore
import XCTest

/// A pretend Tool Mac Tool Run: its tools, a folder of scripts and flows, and requests that wait
/// for Run on the Mac until a test says how they went. It keeps every call it was sent.
final class FakeToolMac: @unchecked Sendable {
    private let lock = NSLock()
    struct Call { let method: String; let path: String; let body: [String: Any] }
    private var _calls: [Call] = []
    private var _requests: [String: [String: Any]] = [:]
    private var _down = false
    private var _tools: [[String: Any]] = FakeToolMac.defaultTools
    /// What a tool answers: by its name (and op), a status and JSON.
    var answers: [String: (Int, [String: Any])] = [:]

    var calls: [Call] { lock.withLock { _calls } }
    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    var tools: [[String: Any]] { get { lock.withLock { _tools } } set { lock.withLock { _tools = newValue } } }

    static let defaultTools: [[String: Any]] = [
        ["name": "web_search", "description": "Searches the web", "on": true, "asks_on_the_mac": false,
         "args": [["name": "q", "type": "string", "required": true, "about": "what to search for"], ["name": "limit", "type": "integer", "about": "how many"]]],
        ["name": "run_script", "description": "Runs a script from the folder", "on": true, "asks_on_the_mac": true,
         "args": [["name": "script", "type": "string", "required": true, "about": "its name"], ["name": "args", "type": "list", "about": "its inputs"]]],
    ] + ["web_fetch", "browser", "library", "remember", "recall", "memory", "mind", "show", "copy", "docs", "runs",
         "check_flow", "say", "find", "call_api"].map { ["name": $0, "on": true, "asks_on_the_mac": false] }
        + ["run_flow", "run_flow_code", "straw"].map { ["name": $0, "on": true, "asks_on_the_mac": true] }

    static let guide = ["Use find before guessing a script's name."]

    static let scripts: [[String: Any]] = [
        ["name": "nightly-backup.sh", "title": "nightly-backup", "group": "scripts", "summary": "Backs up the folder every night", "inputs": [] as [Any]],
        ["name": "utilities/weather.py", "title": "weather", "group": "utilities", "summary": "The weather now",
         "inputs": [["prompt": "A place (where you are unless set)", "kind": "argument", "optional": true]]],
        ["name": "greet.sh", "title": "greet", "group": "scripts", "summary": "Says hello to someone", "say": ["greet {a name}"],
         "inputs": [["prompt": "A name", "kind": "argument", "optional": false]]],
        ["name": "postcard.sh", "title": "postcard", "group": "scripts", "summary": "Sends a postcard",
         "inputs": [["prompt": "To whom", "kind": "argument", "optional": false], ["prompt": "The message", "kind": "argument", "optional": false, "why": "It's printed on the card"]]],
    ]

    func calls(to path: String) -> [Call] { calls.filter { $0.path.hasPrefix(path) } }

    /// The request a run was asked for with, and how it's going now.
    func request(_ id: String) -> [String: Any]? { lock.withLock { _requests[id] } }
    func set(_ id: String, _ state: [String: Any]) { lock.withLock { _requests[id] = state } }
    var requestIDs: [String] { lock.withLock { Array(_requests.keys) } }

    var send: ToolMac.Send {
        { [self] request in
            let url = request.url!
            let path = url.path + (url.query.map { "?" + $0 } ?? "")
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let method = request.httpMethod ?? "GET"
            let (down, tools): (Bool, [[String: Any]]) = lock.withLock {
                _calls.append(Call(method: method, path: path, body: body))
                return (_down, _tools)
            }
            if down { throw URLError(.cannotConnectToHost) }
            func json(_ o: Any, _ status: Int = 200) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: o), status) }
            switch (method, url.path) {
            case ("GET", "/api/tools"): return json(["tools": tools, "guide": Self.guide])
            case ("GET", "/api/scripts"): return json(["scripts": Self.scripts])
            case ("GET", "/api/flows"): return json(["flows": [["name": "translate.flow", "title": "translate", "inputs": [["prompt": "What to translate", "kind": "argument"]]]]])
            case ("GET", "/api/health"): return json(["ok": true, "version": "0.1.99"])
            default: break
            }
            if url.path.hasPrefix("/api/requests/") {
                let id = String(url.path.dropFirst("/api/requests/".count))
                if method == "DELETE" {
                    guard let r = self.request(id), r["state"] as? String == "waiting" else { return json(["ok": false, "error": "not waiting"], 409) }
                    set(id, ["state": "withdrawn", "ok": false])
                    return json(["ok": true])
                }
                guard let r = self.request(id) else { return json(["ok": false, "error": "no such request"], 404) }
                return json(r)
            }
            if url.path.hasPrefix("/api/runs/"), url.path.hasSuffix("/stop") { return json(["ok": true]) }
            if url.path.hasPrefix("/api/tools/") {
                let name = String(url.path.dropFirst("/api/tools/".count))
                let args = body["arguments"] as? [String: Any] ?? [:]
                if body["async"] as? Bool == true {
                    let id = UUID().uuidString
                    set(id, ["state": "waiting", "request": id, "name": args["script"] ?? args["flow"] ?? name])
                    return json(["ok": true, "request": id, "state": "waiting"], 202)
                }
                let key = (args["op"] as? String).map { "\(name):\($0)" } ?? name
                if let a = answers[key] ?? answers[name] { return json(a.1, a.0) }
                switch name {
                case "web_search":
                    let q = args["q"] as? String ?? ""
                    return json(["ok": true, "q": q, "results": [["title": "Hours, admission | Louvre", "url": "https://www.louvre.fr/en/visit/hours", "snippet": "Open 9am to 6pm"]]])
                case "library":
                    let n = args["name"] as? String ?? ""
                    switch args["op"] as? String {
                    case "read": return n == "nope" ? json(["ok": false, "error": "There's no note called nope.", "code": "not_found"], 404) : json(["ok": true, "name": n, "text": "- eggs\n- milk"])
                    case "write": return json(["ok": true, "name": n, "new": true])
                    case "delete": return json(["ok": true, "name": n])
                    default: return json(["ok": true])
                    }
                case "remember": return json(["ok": true, "file": args["category"] ?? "", "node": args["about"] ?? ""])
                default: return json(["ok": true, "said": "Done: \(name)."])
                }
            }
            return json(["ok": false, "error": "no such route"], 404)
        }
    }
}

/// A pretend model, answering as Ollama does on `/api/chat`: each answer in turn calls a tool
/// or says something, as a test tells it to. It keeps every request it was sent.
final class FakeModel: @unchecked Sendable {
    enum Move {
        case call(String, [String: Any])
        case says(String)
        /// Its answer worked out from what it was sent (the messages so far).
        case reads(@Sendable ([[String: Any]]) -> Move)
    }

    private let lock = NSLock()
    private var _moves: [Move] = []
    private var _fails = false
    private var _asked: [URLRequest] = []

    var fails: Bool { get { lock.withLock { _fails } } set { lock.withLock { _fails = newValue } } }
    /// The chat requests it was sent (not the ones asking what models there are).
    var asked: [[String: Any]] { lock.withLock { _asked.filter { $0.url?.path != "/api/tags" }.compactMap { $0.httpBody.flatMap(JSON.object) } } }
    var count: Int { asked.count }

    /// What it does next, one answer each, in order (the last, again and again after).
    func plays(_ moves: Move...) { lock.withLock { _moves = moves } }

    var send: Brain.Send {
        { [self] request in
            let (fails, move) = lock.withLock { () -> (Bool, Move?) in
                _asked.append(request)
                if request.url?.path == "/api/tags" { return (_fails, nil) }
                return (_fails, _moves.count > 1 ? _moves.removeFirst() : _moves.first)
            }
            if fails { throw URLError(.cannotConnectToHost) }
            if request.url?.path == "/api/tags" {
                return (try JSONSerialization.data(withJSONObject: ["models": [["name": "nomic-embed-text"], ["name": "llama3.2:3b"], ["name": "qwen3:8b"]]]), 200)
            }
            let messages = request.httpBody.flatMap(JSON.object)?["messages"] as? [[String: Any]] ?? []
            var m = move ?? .says("(nothing to say)")
            if case let .reads(f) = m { m = f(messages) }
            let message: [String: Any]
            switch m {
            case let .call(name, args): message = ["role": "assistant", "content": "", "tool_calls": [["function": ["name": name, "arguments": args]]]]
            case let .says(text): message = ["role": "assistant", "content": text]
            case .reads: message = ["role": "assistant", "content": ""]
            }
            return (try JSONSerialization.data(withJSONObject: ["model": "qwen3:8b", "message": message, "done": true]), 200)
        }
    }

    /// The messages of the request it was last sent.
    var lastMessages: [[String: Any]] { asked.last?["messages"] as? [[String: Any]] ?? [] }

    /// What the last tool it called gave back, as it was sent to it.
    var lastResult: String { (lastMessages.last { $0["role"] as? String == "tool" }?["content"] as? String) ?? "" }
}

/// What a client was told, by its callback.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var _got: [[String: Any]] = []
    private var _refuse = false
    var got: [[String: Any]] { lock.withLock { _got } }
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }

    var deliver: @Sendable (Peter.SayNews) async -> Bool {
        { [self] news in
            lock.withLock {
                if _refuse { return false }
                _got.append((try? JSONSerialization.jsonObject(with: news.body)) as? [String: Any] ?? [:])
                return true
            }
        }
    }
}

extension XCTestCase {
    /// Waits (a little at a time, up to two seconds) until something's true.
    func until(_ what: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await what() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A pretend Storage Spaces: Peter's records, the person's notes (answered as the real one
/// answers them), and requests for access. It keeps every call it was sent.
final class FakeStorage: @unchecked Sendable {
    private let lock = NSLock()
    struct Call { let method: String; let path: String; let body: Any? }
    private var _calls: [Call] = []
    private var _records: [String: (value: Any, updated: Date)] = [:]
    private var _requests: [[String: Any]] = [["id": 3, "client": "Super Voice", "space": "user", "store": "memory", "access": "read", "state": "open", "why": "to greet people"]]
    private var _grants: [[String: Any]] = []
    private var _down = false
    var calls: [Call] { lock.withLock { _calls } }
    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    var requests: [[String: Any]] { lock.withLock { _requests } }
    var grants: [[String: Any]] { lock.withLock { _grants } }

    func record(_ path: String) -> Any? { lock.withLock { _records[path]?.value } }
    func set(_ path: String, _ value: Any, updated: Date = Date()) { lock.withLock { _records[path] = (value, updated) } }

    var send: StorageSpaces.Send {
        { [self] request in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            let down = lock.withLock { () -> Bool in
                _calls.append(Call(method: method, path: url.path + (url.query.map { "?" + $0 } ?? ""), body: body))
                return _down
            }
            if down { throw URLError(.cannotConnectToHost) }
            func json(_ o: Any, _ status: Int = 200) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: o), status) }
            let path = url.path
            switch (method, path) {
            case ("POST", "/api/clients/register"): return json(["ok": true, "key": "k3y"])
            case ("GET", "/api/access/check"): return json(["ok": true, "allowed": true])
            case ("POST", "/api/library"):
                let b = body as? [String: Any] ?? [:]
                return json(["ok": true, "op": b["op"] ?? "", "name": b["name"] ?? "", "text": "- bread (from Storage Spaces)"])
            case ("GET", "/api/memory/recall"): return json(["ok": true, "found": true, "lines": ["| PEOPLE | ada"]])
            case ("GET", "/api/access/requests"): return json(["ok": true, "requests": lock.withLock { _requests.filter { $0["state"] as? String == "open" } }])
            case ("GET", "/api/access/grants"): return json(["ok": true, "grants": grants])
            case ("POST", "/api/access/grants"):
                let b = body as? [String: Any] ?? [:]
                let g: [String: Any] = ["id": grants.count + 1, "client": b["to"] ?? "", "line": "\(b["to"] ?? "") may \(b["access"] ?? "") \((b["space"] as? String ?? "").uppercased())/\((b["store"] as? String ?? "").uppercased())"]
                lock.withLock { _grants.append(g) }
                return json(["ok": true, "grant": g])
            default: break
            }
            if path.hasPrefix("/api/access/requests/"), method == "POST" {
                let parts = path.split(separator: "/")
                let n = Int(parts[3]) ?? 0, yes = parts[4] == "approve"
                return lock.withLock {
                    guard let k = _requests.firstIndex(where: { $0["id"] as? Int == n }) else { return json(["ok": false, "error": "there's no request \(n)"], 404) }
                    _requests[k]["state"] = yes ? "approved" : "denied"
                    if yes { _requests[k]["grant"] = ["line": "Super Voice may read USER/MEMORY"] }
                    return json(["ok": true, "request": _requests[k]])
                }
            }
            if path.hasPrefix("/api/access/grants/"), method == "DELETE" {
                let id = Int(path.split(separator: "/").last ?? "") ?? 0
                lock.withLock { _grants.removeAll { $0["id"] as? Int == id } }
                return json(["ok": true])
            }
            if path.hasPrefix("/api/spaces/peter/") {
                let key = String(path.dropFirst("/api/spaces/peter/".count)).replacingOccurrences(of: "/records/", with: "/")
                if method == "PUT" {
                    set(key, body ?? NSNull())
                    return json(["ok": true, "version": 1])
                }
                guard let r = lock.withLock({ _records[key] }) else { return json(["ok": false, "code": "not_found"], 404) }
                return json(["ok": true, "key": key, "value": r.value, "updated": r.updated.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))])
            }
            return json(["ok": true, "said": "done on Storage Spaces"])
        }
    }
}
