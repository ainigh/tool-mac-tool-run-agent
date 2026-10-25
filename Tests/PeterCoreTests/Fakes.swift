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

    static let defaultTools: [[String: Any]] = ["web_search", "web_fetch", "browser", "library", "remember", "recall", "memory", "mind", "show", "copy", "docs", "runs",
                                                "check_flow", "say", "find", "call_api"].map { ["name": $0, "on": true, "asks_on_the_mac": false] }
        + ["run_script", "run_flow", "run_flow_code", "straw"].map { ["name": $0, "on": true, "asks_on_the_mac": true] }

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
            case ("GET", "/api/tools"): return json(["tools": tools])
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

/// A pretend model: answers what it's told to, and keeps what it was asked.
final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [String] = []
    private var _fails = false
    private(set) var asked: [URLRequest] = []

    var fails: Bool { get { lock.withLock { _fails } } set { lock.withLock { _fails = newValue } } }
    var count: Int { lock.withLock { asked.count } }

    /// What it says next (several: one a call, the last again after).
    func says(_ json: String...) { lock.withLock { _answers = json } }

    var send: SayTranslator.Send {
        { [self] request in
            let (fails, answer) = lock.withLock { () -> (Bool, String) in
                asked.append(request)
                let a = _answers.count > 1 ? _answers.removeFirst() : _answers.first ?? "{}"
                return (_fails, a)
            }
            if fails { throw URLError(.cannotConnectToHost) }
            if request.url?.path == "/api/tags" {
                return (try JSONSerialization.data(withJSONObject: ["models": [["name": "nomic-embed-text"], ["name": "llama3.2:3b"], ["name": "qwen3:8b"]]]), 200)
            }
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": answer]]]]
            return (try JSONSerialization.data(withJSONObject: body), 200)
        }
    }

    /// The prompt it was last given.
    var lastUser: String {
        guard let r = lock.withLock({ asked.last }), let body = r.httpBody,
              let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = o["messages"] as? [[String: Any]] else { return "" }
        return messages.last?["content"] as? String ?? ""
    }

    var lastModel: String {
        guard let r = lock.withLock({ asked.last }), let body = r.httpBody,
              let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        return o["model"] as? String ?? ""
    }
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
