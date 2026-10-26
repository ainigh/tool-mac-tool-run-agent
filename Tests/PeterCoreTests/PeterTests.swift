import Foundation
@testable import PeterCore
import XCTest

/// Peter: a request in plain words, worked through by his model with his tools (Tool Mac Tool
/// Run's, and his own), and answered in its words. No conversation is kept: each request is all
/// the model sees. What's still going is followed, and the client told the moment it's over.
final class PeterTests: XCTestCase {
    var home: URL!
    var mac: FakeToolMac!
    var model: FakeModel!
    var inbox: Inbox!
    var peter: Peter!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("peter-\(UUID().uuidString)", isDirectory: true)
        mac = FakeToolMac()
        model = FakeModel()
        inbox = Inbox()
        var s = Brain.Settings()
        s.model = "qwen3:8b"
        peter = Peter(toolMac: ToolMac(fresh: 0, send: mac.send), storage: StorageSpaces.none(), brain: Brain(file: nil, settings: s, send: model.send),
                      schedule: Schedule(file: home.appendingPathComponent("schedule.json")), sayEvery: 5_000_000, deliver: inbox.deliver)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Says something as a client, over HTTP, and gives back the words it got.
    @discardableResult
    func say(_ text: String, client: String = "Tester", replyTo: String? = nil) async -> String {
        var headers = ["Content-Type": "text/plain", "X-Client": client]
        if let replyTo { headers["X-Reply-To"] = replyTo }
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: headers, body: Data(text.utf8)))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "text/plain; charset=utf-8")
        return String(decoding: r.bodyData ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Says something as a client, over HTTP, and gives back how it went (X-Peter-Outcome) with the words.
    func sayOutcome(_ text: String, client: String = "Tester") async -> (outcome: String, text: String) {
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: ["Content-Type": "text/plain", "X-Client": client], body: Data(text.utf8)))
        return (r.header("X-Peter-Outcome") ?? "", String(decoding: r.bodyData ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func json(_ r: HTTPResponse) -> [String: Any] { JSON.object(r.bodyData ?? Data()) ?? [:] }

    /// The model says back what the last tool it called said (`said`), or its error.
    static let echo = FakeModel.Move.reads { messages in
        let last = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let j = JSON.object(Data(last.utf8)) ?? [:]
        return .says(j["said"] as? String ?? j["error"] as? String ?? last)
    }

    // MARK: a request, worked through

    func testARequestIsDoneByTheModelWithTheToolsAndAnsweredInItsWords() async throws {
        model.plays(.call("web_search", ["q": "Louvre opening hours"]), .says("The Louvre is open from 9am to 6pm."))
        let out = await say("when does the louvre open?")
        XCTAssertEqual(out, "The Louvre is open from 9am to 6pm.")
        let call = try XCTUnwrap(mac.calls(to: "/api/tools/web_search").last)
        XCTAssertEqual((call.body["arguments"] as? [String: Any])?["q"] as? String, "Louvre opening hours")
        XCTAssertEqual(model.count, 2, "one round of tools, then the answer")
        // What it was given: the instructions, the message (who, when), and every tool but say.
        let first = try XCTUnwrap(model.asked.first)
        let messages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        let system = messages[0]["content"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix("You are Peter."), system)
        XCTAssertTrue(system.contains("\"How would I ask you to …?\": do nothing."), system)
        XCTAssertTrue(system.contains("- Do only what's asked."), system)
        XCTAssertTrue(system.contains("goes word for word as given"), system)
        XCTAssertFalse(system.contains("send the whole request again"), "a client's own instructions say he keeps no conversation: his answers don't")
        XCTAssertTrue(system.contains("- Use find before guessing a script's name."), "Tool Mac Tool Run's guide")
        let user = messages[1]["content"] as? String ?? ""
        XCTAssertTrue(user.hasPrefix("From: Tester\nNow: "), user)
        XCTAssertTrue(user.hasSuffix("\n\nwhen does the louvre open?"), user)
        let tools = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(tools.contains("web_search") && tools.contains("run_script") && tools.contains("schedule") && tools.contains("requests") && tools.contains("access") && tools.contains("space_notes"), "\(tools)")
        XCTAssertFalse(tools.contains("say"), "say is Peter's own")
        let search = try XCTUnwrap((first["tools"] as? [[String: Any]])?.first { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" }?["function"] as? [String: Any])
        let schema = try XCTUnwrap(search["parameters"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["q"])
        XCTAssertEqual(((schema["properties"] as? [String: Any])?["limit"] as? [String: Any])?["type"] as? String, "integer")
        // Ollama is asked on its own address, with room enough to read it all.
        XCTAssertEqual((first["options"] as? [String: Any])?["num_ctx"] as? Int, 16384)
        // What the tool gave back went to it.
        XCTAssertTrue(model.lastResult.contains("Open 9am to 6pm"), model.lastResult)
    }

    func testNoConversationIsKept() async throws {
        model.plays(.says("Which page? Ask again with the address: open https://… in Chrome."))
        let asked = await say("open the page")
        XCTAssertEqual(asked, "Which page? Ask again with the address: open https://… in Chrome.", "nothing added to it")
        model.plays(.says("Opened."))
        _ = await say("https://example.com")
        let messages = model.lastMessages
        XCTAssertEqual(messages.count, 2, "the instructions and this message: nothing of the one before")
        XCTAssertFalse(messages.contains { ($0["content"] as? String ?? "").contains("open the page") })
    }

    func testARunWaitsForTheMacAndTheClientIsToldTheMomentItsOver() async throws {
        model.plays(.call("run_script", ["script": "nightly-backup.sh"]), Self.echo)
        let asked = await say("run the nightly backup", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertEqual(asked, "Asked for the nightly backup. The client is told how it went the moment it's over.")
        let run = try XCTUnwrap(mac.calls(to: "/api/tools/run_script").last)
        XCTAssertEqual(run.body["async"] as? Bool, true)
        XCTAssertTrue((run.body["why"] as? String ?? "").contains("Tester asked in words: “run the nightly backup”"))
        let id = try XCTUnwrap(mac.requestIDs.first)
        model.plays(.call("requests", ["op": "status", "which": "the backup"]), Self.echo)
        let waiting = await say("what happened to the backup")
        XCTAssertTrue(waiting.contains("waiting for someone at the Mac to OK it"), waiting)
        // Clicked, and over.
        mac.set(id, ["state": "succeeded", "ok": true, "run_id": "R1", "run": ["state": "succeeded", "output": "backed up 12 files\n", "code": 0]])
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first)
        XCTAssertEqual(news["client"] as? String, "Tester")
        XCTAssertEqual(news["text"] as? String, "Meanwhile: The nightly backup finished (it worked). It printed:\nbacked up 12 files")
        // Told once: not again in the next reply.
        model.plays(.says("Nothing."))
        let next = await say("anything new?")
        XCTAssertFalse(next.contains("Meanwhile"), next)
    }

    func testNewsThatCouldntBeDeliveredComesFirstInTheNextReply() async throws {
        inbox.refuse = true
        model.plays(.call("run_script", ["script": "greet.sh", "args": ["Sam"]]), .says("Asked for the greet."))
        _ = await say("greet Sam", replyTo: "http://127.0.0.1:8769/api/peter")
        let id = try XCTUnwrap(mac.requestIDs.first)
        mac.set(id, ["state": "denied", "ok": false])
        // Once it's been turned away and is untold again (not while a try is still going).
        await until {
            guard self.inbox.refused > 0, let e = await self.peter.sayLog.entries("Tester").first(where: { $0.asks }) else { return false }
            return e.state.key == "denied" && e.told != e.state.key
        }
        model.plays(.says("Nothing is scheduled."))
        let next = await say("what's scheduled")
        XCTAssertTrue(next.hasPrefix("Meanwhile: The greet didn't run: it was turned down on the Mac.\n\nNothing is scheduled."), next)
    }

    func testStopTakesBackWhatsStillWaiting() async throws {
        model.plays(.call("run_script", ["script": "nightly-backup.sh"]), .says("Asked for the nightly backup."))
        _ = await say("run the nightly backup")
        model.plays(.call("requests", ["op": "stop", "which": "the backup"]), Self.echo)
        let stopped = await say("stop the backup")
        XCTAssertEqual(stopped, "Taken back: the nightly backup won't run.")
        model.plays(.call("requests", ["op": "list"]), Self.echo)
        let list = await say("what have I asked for today")
        XCTAssertTrue(list.contains("1. run the nightly backup (answered)"), list)
        XCTAssertTrue(list.contains("2. the nightly backup (taken back)"), list)
        XCTAssertTrue(list.contains("3. stop the backup (answered)"), list)
        model.plays(.call("requests", ["op": "show", "which": "number 2"]), Self.echo)
        let byNumber = await say("show me number 2")
        XCTAssertFalse(byNumber.contains("I can't tell which"), byNumber)
    }

    func testWhatGoesWrongIsSaid() async throws {
        // Tool Mac Tool Run closed (it was open before): the model is told, and says so.
        _ = await peter.health()
        mac.down = true
        model.plays(.call("web_search", ["q": "cats"]), Self.echo)
        let down = await say("search the web for cats")
        XCTAssertTrue(down.contains("Tool Mac Tool Run isn't answering"), down)
        XCTAssertTrue((model.lastMessages[1]["content"] as? String ?? "").hasPrefix("(Tool Mac Tool Run isn't answering right now"))
        mac.down = false
        // A tool there isn't.
        model.plays(.call("teleport", ["to": "Lagos"]), Self.echo)
        let none = await say("take me to Lagos")
        XCTAssertTrue(none.hasPrefix("There's no tool called teleport. The tools: access, browser,"), none)
        // A model that won't stop calling.
        model.plays(.call("web_search", ["q": "again"]))
        let endless = await say("keep searching")
        XCTAssertTrue(endless.hasPrefix("I couldn't do that: that took more than 8 steps, so I stopped"), endless)
        XCTAssertFalse(endless.contains("send the whole request again"), endless)
        // The model out of reach.
        model.fails = true
        let out = await say("search the web for cats")
        XCTAssertTrue(out.hasPrefix("I couldn't do that: my model couldn't be reached"), out)
        let log = json(await peter.route(HTTPRequest(method: "GET", target: "/api/say/log", headers: ["X-Client": "Tester"])))
        XCTAssertEqual((log["entries"] as? [[String: Any]])?.first?["state"] as? String, "failed")
    }

    func testHowItWentIsToldByWhatTheToolsDidNotByTheWords() async throws {
        // Something done (whatever the words say it couldn't find).
        model.plays(.call("web_search", ["q": "Lagos rain"]), .says("80% rain tomorrow. I couldn't find the hours it'll fall."))
        let done = await sayOutcome("will it rain in Lagos tomorrow?")
        XCTAssertEqual(done.outcome, "done", done.text)
        // A run asked for, put in any words.
        model.plays(.call("run_script", ["script": "nightly-backup.sh"]), .says("I've asked for the backup: it waits for you to click Run."))
        let asked = await sayOutcome("back up my documents")
        XCTAssertEqual(asked.outcome, "asked", asked.text)
        // No tool called: he needs something, or said how to ask.
        model.plays(.says("Which page? Ask again with the address: open https://… in Chrome."))
        let needs = await sayOutcome("open the page")
        XCTAssertEqual(needs.outcome, "nothing", needs.text)
        // Every tool it called failed: nothing done.
        model.plays(.call("teleport", ["to": "Lagos"]), .says("I can't do that."))
        let cant = await sayOutcome("take me to Lagos")
        XCTAssertEqual(cant.outcome, "nothing", cant.text)
        // His model out of reach.
        model.fails = true
        let broken = await sayOutcome("search the web for cats")
        XCTAssertEqual(broken.outcome, "error", broken.text)
        XCTAssertFalse(broken.text.contains("send the whole request again"), broken.text)
    }

    func testACallWrittenAsWordsIsStillMade() async throws {
        model.plays(.says(#"<tool_call>{"name": "web_search", "arguments": {"q": "cats"}}</tool_call>"#), .says("Cats are popular."))
        let out = await say("tell me about cats")
        XCTAssertEqual(out, "Cats are popular.")
        XCTAssertEqual((mac.calls(to: "/api/tools/web_search").last?.body["arguments"] as? [String: Any])?["q"] as? String, "cats")
        XCTAssertNil(Brain.callInText(#"{"name": "nope", "arguments": {}}"#, tools: ["web_search"]), "only a tool there is")
        XCTAssertEqual(Brain.withoutThinking("<think>hm</think>\nHello."), "Hello.")
    }

    // MARK: his model

    func testAutoIsTheBestModelOllamaHas() async {
        var s = Brain.Settings()
        XCTAssertEqual(s.model, "auto")
        s.on = true
        let b = Brain(file: nil, settings: s, send: model.send)
        model.plays(.says("Hi."))
        _ = await b.run(system: "", user: "hi", tools: [], client: "Tester") { _ in ("", false) }
        XCTAssertEqual(model.asked.last?["model"] as? String, "qwen3:8b")
        XCTAssertEqual(Brain.best(["llama3.2:3b", "mistral:7b"]), "llama3.2:3b")
        XCTAssertEqual(Brain.best(["nomic-embed-text", "whatever:1b"]), "whatever:1b")
    }

    func testTheModelPlaysWhileItWorks() async {
        let flips = LockedList()
        await peter.brain.observe { busy in flips.add(busy) }
        model.plays(.says("Done."))
        _ = await say("zzz qqq")
        XCTAssertEqual(flips.items, [true, false])
    }

    func testOpenAIAndAnthropicAreAskedTheirOwnWay() throws {
        let call = Brain.ToolCall(id: "t1", name: "web_search", arguments: ["q": "cats"])
        let turns: [Brain.Turn] = [.user("search cats"), .assistant("", [call], nil), .results([(call, "{\"ok\":true}", false)])]
        let tool = Brain.Tool(name: "web_search", description: "Searches", schema: ["type": "object", "properties": ["q": ["type": "string"]]])
        // A chat completions address: functions, the arguments as text, the result by the call's id.
        var o = Brain.Settings()
        o.url = "http://127.0.0.1:1234/v1/chat/completions"
        let or = try Brain.request(o, system: "sys", turns: turns, tools: [tool])
        XCTAssertEqual(or.url?.path, "/v1/chat/completions")
        let ob = try XCTUnwrap(or.httpBody.flatMap(JSON.object))
        let om = try XCTUnwrap(ob["messages"] as? [[String: Any]])
        XCTAssertEqual(om.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual((((om[2]["tool_calls"] as? [[String: Any]])?.first?["function"]) as? [String: Any])?["arguments"] as? String, #"{"q":"cats"}"#)
        XCTAssertEqual(om[3]["tool_call_id"] as? String, "t1")
        let oreply = try XCTUnwrap(Brain.reply(JSON.data(["choices": [["message": ["role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "c9", "type": "function", "function": ["name": "web_search", "arguments": #"{"q":"dogs"}"#]]]]]]]), o, tools: ["web_search"]))
        XCTAssertEqual(oreply.calls.first?.id, "c9")
        XCTAssertEqual(oreply.calls.first?.arguments["q"] as? String, "dogs")
        // Anthropic: tools with input_schema, the system apart, the result a tool_result block.
        var a = Brain.Settings()
        a = try a.changed(by: ["api": "anthropic", "key": "k"])
        XCTAssertEqual(a.model, "claude-opus-5-5")
        let ar = try Brain.request(a, system: "sys", turns: turns, tools: [tool])
        XCTAssertEqual(ar.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(ar.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let ab = try XCTUnwrap(ar.httpBody.flatMap(JSON.object))
        XCTAssertEqual(ab["system"] as? String, "sys")
        XCTAssertNotNil((ab["tools"] as? [[String: Any]])?.first?["input_schema"])
        let am = try XCTUnwrap(ab["messages"] as? [[String: Any]])
        XCTAssertEqual(((am[2]["content"] as? [[String: Any]])?.first)?["type"] as? String, "tool_result")
        XCTAssertEqual(((am[2]["content"] as? [[String: Any]])?.first)?["tool_use_id"] as? String, "t1")
        let blocks: [[String: Any]] = [["type": "thinking", "thinking": "", "signature": "s"], ["type": "tool_use", "id": "tu1", "name": "web_search", "input": ["q": "owls"]]]
        let areply = try XCTUnwrap(Brain.reply(JSON.data(["stop_reason": "tool_use", "content": blocks]), a, tools: ["web_search"]))
        XCTAssertEqual(areply.calls.first?.arguments["q"] as? String, "owls")
        // Its blocks go back as they came (the thinking with them).
        let again = Brain.anthropicMessages([.assistant(areply.text, areply.calls, areply.raw)])
        XCTAssertEqual((again.first?["content"] as? [[String: Any]])?.count, 2)
        let declined = try XCTUnwrap(Brain.reply(JSON.data(["stop_reason": "refusal", "content": [] as [Any]]), a, tools: []))
        XCTAssertNotNil(declined.declined)
    }

    func testTheTranslatorsSettingsCarryOver() throws {
        let old = #"{"on": true, "api": "openai", "url": "http://127.0.0.1:11434/v1/chat/completions", "model": "qwen3:8b", "key": "", "timeout": 20, "sure": 0.75, "format": "json_object", "effort": "low"}"#
        let s = try JSONDecoder().decode(Brain.Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.model, "qwen3:8b")
        XCTAssertEqual(s.timeout, 120, "the translator's short wait isn't kept")
        let kept = try JSONDecoder().decode(Brain.Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(kept, s)
    }

    // MARK: the schedule

    func testAReminderIsSaidBackWhenItsDue() async throws {
        model.plays(.call("schedule", ["op": "remind", "when": "in 20 minutes", "text": "call Sam"]), Self.echo)
        let set = await say("remind me in 20 minutes to call Sam", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertTrue(set.hasPrefix("Set for today at") || set.hasPrefix("Set for tomorrow at"), set)
        XCTAssertTrue(set.contains("(in 20 minutes): a reminder: call Sam. Its number is 1. I'll tell you then."), set)
        model.plays(.call("schedule", ["op": "list"]), Self.echo)
        let list = await say("what's scheduled")
        XCTAssertTrue(list.contains("1. ") && list.contains("a reminder: call Sam"), list)
        // It comes due: said back without the model.
        let before = model.count
        await peter.start()
        await peter.schedule.tick(now: Date().addingTimeInterval(21 * 60))
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first?["text"] as? String)
        XCTAssertTrue(news.hasPrefix("Meanwhile: Reminder (Scheduled today at") || news.hasPrefix("Meanwhile: Reminder (Scheduled tomorrow at"), news)
        XCTAssertTrue(news.hasSuffix("number 1): call Sam"), news)
        XCTAssertEqual(model.count, before)
    }

    func testARequestForLaterIsDoneThenAndARepeatingOneGoesOn() async throws {
        model.plays(.call("schedule", ["op": "later", "when": "tomorrow 7am", "repeat": "every day", "text": "search the web for Lagos weather"]), Self.echo)
        let set = await say("every day at 7am, search the web for Lagos weather", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertTrue(set.contains("then every day: search the web for Lagos weather"), set)
        let items = await peter.schedule.items
        let item = try XCTUnwrap(items.first)
        // When it's due, the model does it, as if the client had just asked.
        model.plays(.call("web_search", ["q": "Lagos weather"]), .says("Sunny in Lagos, 31°C."))
        await peter.start()
        await peter.schedule.tick(now: item.due.addingTimeInterval(1))
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first?["text"] as? String)
        XCTAssertTrue(news.contains("Done as scheduled (Scheduled every day"), news)
        XCTAssertTrue(news.contains("Sunny in Lagos, 31°C."), news)
        let user = model.asked.first { (($0["messages"] as? [[String: Any]])?.last?["content"] as? String ?? "").contains("due now") }
        XCTAssertNotNil(user, "it's told the request was scheduled, and is due now")
        let nextItems = await peter.schedule.items
        let next = try XCTUnwrap(nextItems.first)
        XCTAssertEqual(next.due.timeIntervalSince(item.due), 86400, accuracy: 3700, "the next day")
        model.plays(.call("schedule", ["op": "cancel", "which": "lagos"]), Self.echo)
        let cancelled = await say("cancel the lagos weather")
        XCTAssertTrue(cancelled.hasPrefix("Taken off the schedule: 1. search the web for Lagos weather."), cancelled)
    }

    func testTheScheduleOutlastsARestart() async throws {
        model.plays(.call("schedule", ["op": "remind", "when": "tomorrow 9am", "text": "stand up"]), Self.echo)
        _ = await say("remind me tomorrow at 9 to stand up")
        let again = Schedule(file: home.appendingPathComponent("schedule.json"))
        let kept = await again.items
        XCTAssertEqual(kept.map(\.text), ["stand up"])
        XCTAssertEqual(kept.first?.client, "Tester")
    }

    func testWhen() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T21:40:00Z")) // a Sunday
        func at(_ s: String) -> String? { When.parse(s, now: now, calendar: cal).map { ISO8601DateFormatter().string(from: $0) } }
        XCTAssertEqual(at("in 20 minutes"), "2026-10-25T22:00:00Z")
        XCTAssertEqual(at("in an hour"), "2026-10-25T22:40:00Z")
        XCTAssertEqual(at("20 min"), "2026-10-25T22:00:00Z")
        XCTAssertEqual(at("in 1 hour 30 minutes"), "2026-10-25T23:10:00Z")
        XCTAssertEqual(at("at 17:30"), "2026-10-26T17:30:00Z", "passed today: tomorrow")
        XCTAssertEqual(at("11pm"), "2026-10-25T23:00:00Z")
        XCTAssertEqual(at("tomorrow 8am"), "2026-10-26T08:00:00Z")
        XCTAssertEqual(at("tomorrow at 8"), "2026-10-26T08:00:00Z")
        XCTAssertEqual(at("friday 9:00"), "2026-10-30T09:00:00Z")
        XCTAssertEqual(at("on Monday"), "2026-10-26T09:00:00Z")
        XCTAssertEqual(at("2026-11-03 14:00"), "2026-11-03T14:00:00Z")
        XCTAssertEqual(at("3 November at noon"), "2026-11-03T12:00:00Z")
        XCTAssertEqual(at("tomorrow morning"), "2026-10-26T09:00:00Z")
        XCTAssertNil(at("whenever you like"))
        XCTAssertEqual(When.Repeat.parse("every day"), .daily)
        XCTAssertEqual(When.Repeat.parse("every 15 minutes"), .every(900))
        XCTAssertEqual(When.Repeat.parse("weekdays"), .weekdays)
        XCTAssertNil(When.Repeat.parse("sometimes"))
        let friday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: When.Repeat.weekdays.next(after: friday, now: friday, calendar: cal)), "2026-11-02T09:00:00Z", "Friday, then Monday")
    }

    // MARK: the routes

    func testTheRoutes() async throws {
        let health = json(await peter.route(HTTPRequest(method: "GET", target: "/api/health")))
        XCTAssertEqual(health["service"] as? String, "peter")
        XCTAssertEqual((health["tool_mac_tool_run"] as? [String: Any])?["reachable"] as? Bool, true)
        let away = await peter.route(HTTPRequest(method: "GET", target: "/api/health", fromLoopback: false))
        XCTAssertEqual(away.status, 403, "only programs on this Mac")
        let made = await peter.route(HTTPRequest(method: "POST", target: "/api/schedules", headers: ["Content-Type": "application/json", "X-Client": "App"],
                                                  body: JSON.data(["kind": "remind", "text": "tea", "when": "in 5 minutes"])))
        XCTAssertEqual(made.status, 200)
        let listed = json(await peter.route(HTTPRequest(method: "GET", target: "/api/schedules?client=App")))
        XCTAssertEqual((listed["schedules"] as? [[String: Any]])?.first?["text"] as? String, "tea")
        let gone = await peter.route(HTTPRequest(method: "DELETE", target: "/api/schedules/1"))
        XCTAssertEqual(gone.status, 200)
        let bad = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: ["X-Reply-To": "http://example.com/x"], body: Data("hi".utf8)))
        XCTAssertEqual(bad.status, 400, "reply_to is an address on this Mac")
        let forms = await peter.route(HTTPRequest(method: "GET", target: "/api/say/forms?q=remind"))
        XCTAssertEqual(forms.status, 410, "no templates any more")
        let log = json(await peter.route(HTTPRequest(method: "GET", target: "/api/say/log", headers: ["X-Client": "App"])))
        XCTAssertEqual(log["client"] as? String, "App")
        // His model: its settings, instructions and tools; changed from this Mac.
        let changed = json(await peter.route(HTTPRequest(method: "POST", target: "/api/model", headers: ["Content-Type": "application/json"], body: JSON.data(["steps": 4]))))
        XCTAssertEqual((changed["settings"] as? [String: Any])?["steps"] as? Int, 4)
        XCTAssertTrue((changed["instructions"] as? String ?? "").hasPrefix("You are Peter."))
        XCTAssertTrue((changed["tools"] as? [String] ?? []).contains("schedule"))
        let howTo = String(decoding: (await peter.route(HTTPRequest(method: "GET", target: "/api/say"))).bodyData ?? Data(), as: UTF8.self)
        XCTAssertTrue(howTo.contains("there are no templates or formats to learn"), howTo)
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Bool] = []
    var items: [Bool] { lock.withLock { _items } }
    func add(_ b: Bool) { lock.withLock { _items.append(b) } }
}
