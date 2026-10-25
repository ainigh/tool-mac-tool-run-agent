import Foundation
@testable import PeterCore
import XCTest

/// Peter: a request in words, read into a template (by its words, or by his model), done on Tool
/// Mac Tool Run, and answered in words by a script. No conversation is kept; what's still going
/// is followed, and the client told the moment it's over.
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
        var s = SayTranslator.Settings()
        s.on = false
        peter = Peter(toolMac: ToolMac(fresh: 0, send: mac.send), storage: StorageSpaces.none(), translator: SayTranslator(file: nil, settings: s, send: model.send),
                      schedule: Schedule(file: home.appendingPathComponent("schedule.json")), sayEvery: 5_000_000, deliver: inbox.deliver)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Peter with his model on, answering as the fake does.
    func withModel() {
        var s = SayTranslator.Settings()
        s.model = "llama3.2"
        peter = Peter(toolMac: ToolMac(fresh: 0, send: mac.send), storage: StorageSpaces.none(), translator: SayTranslator(file: nil, settings: s, send: model.send),
                      schedule: Schedule(file: home.appendingPathComponent("schedule.json")), sayEvery: 5_000_000, deliver: inbox.deliver)
    }

    /// Says something as a client, over HTTP, and gives back the words it got.
    @discardableResult
    func say(_ text: String, client: String = "Tester", replyTo: String? = nil) async -> String {
        var headers = ["Content-Type": "text/plain", "X-Client": client]
        if let replyTo { headers["X-Reply-To"] = replyTo }
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: headers, body: Data(text.utf8)))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "text/plain; charset=utf-8")
        let out = String(decoding: r.bodyData ?? Data(), as: UTF8.self)
        // Never JSON, routes or ids.
        XCTAssertFalse(out.contains("/api/"), out)
        XCTAssertFalse(out.contains("{\""), out)
        XCTAssertNil(out.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-"#, options: .regularExpression), out)
        return out
    }

    func json(_ r: HTTPResponse) -> [String: Any] { JSON.object(r.bodyData ?? Data()) ?? [:] }

    // MARK: the grammar (moved from Tool Mac Tool Run as it was)

    func testAnInlineTemplateTakesItsValueExactlyAndForgivesItsOwnWords() throws {
        let form = try XCTUnwrap(SayForms.tools.first { $0.title == "Search the web" })
        let (filled, score) = try XCTUnwrap(SayMatch.inline("search the web for flights to Lagos", form))
        XCTAssertEqual(filled.at(0), "flights to Lagos", "a fixed word inside a value stays in it")
        XCTAssertEqual(score, 1, accuracy: 0.001)
        let (typo, typoScore) = try XCTUnwrap(SayMatch.inline("serch web for \"Café Kranzler\"?", form))
        XCTAssertEqual(typo.at(0), "Café Kranzler", "quotes and the sentence's end are taken off")
        XCTAssertLessThan(typoScore, 1)
        XCTAssertGreaterThanOrEqual(typoScore, SayMatch.floor)
    }

    func testTheLabeledShapeTakesLinesInAnyOrderFencesAndCorrectsChoices() throws {
        let form = try XCTUnwrap(SayForms.tools.first { $0.title == "Remember something" })
        let lines = try XCTUnwrap(SayMatch.lines("remember somethin\n- fact: rain: likely\n- about: Lagos trip\n- Category: event date"))
        guard case let .filled(f, _) = SayMatch.labeled(lines, form, titleScore: SayMatch.titleScore("remember somethin", form)) else { return XCTFail("not filled") }
        XCTAssertEqual(f["category"], "EVENT-DATES")
        XCTAssertEqual(f["fact"], "rain: likely", "a colon in a value stays")
        let note = try XCTUnwrap(SayForms.tools.first { $0.title == "Write a note" })
        let fenced = try XCTUnwrap(SayMatch.lines("Write a note\n- name: groceries\n- text:\n```\n- eggs\n- milk: 2\n```"))
        guard case let .filled(n, _) = SayMatch.labeled(fenced, note, titleScore: 1) else { return XCTFail("not filled") }
        XCTAssertEqual(n["text"], "- eggs\n- milk: 2")
    }

    func testEveryTemplateHasItsOwnTitleAndToolsComeFromToolMacToolRun() async throws {
        let forms = SayForms.all(catalog: await peter.toolMac.catalog())
        let titles = forms.map { $0.title.lowercased() }
        XCTAssertEqual(Set(titles).count, titles.count, "each title once")
        for f in forms { for n in f.next { XCTAssertTrue(forms.contains { $0.title == n }, "\(f.title) → \(n)") } }
        XCTAssertTrue(forms.contains { $0.title == "Greet" && $0.short == "greet {a name}" }, "a script's # Say: line")
        XCTAssertTrue(forms.contains { $0.title == "Postcard" && $0.fields.count == 2 }, "two inputs: the labeled shape")
        XCTAssertTrue(forms.contains { $0.title == "Weather" && $0.short == "what's the weather in {a place}" }, "an example's own sentence")
        XCTAssertTrue(forms.contains { $0.title == "Remind me" })
        XCTAssertFalse(forms.contains { $0.title == "Run something by itself" }, "Tool Mac Tool Run's automation is gone: the schedule is Peter's")
        // A tool it doesn't have: no template. A tool it has added since: one made from its arguments.
        mac.tools = mac.tools.filter { $0["name"] as? String != "web_search" } + [["name": "screen_shot", "description": "Takes a picture of the screen. Saved on the Desktop.", "on": true,
                                                                                  "args": [["name": "region", "type": "string", "required": false, "about": "the part of the screen"]]]]
        let now = SayForms.all(catalog: await peter.toolMac.catalog())
        XCTAssertFalse(now.contains { $0.title == "Search the web" })
        let made = try XCTUnwrap(now.first { $0.title == "Screen shot (a tool)" })
        XCTAssertEqual(made.fields.map(\.label), ["region"])
        XCTAssertTrue(made.fields[0].optional)
        XCTAssertFalse(now.contains { $0.title.lowercased().hasPrefix("find (a tool)") || $0.title.lowercased().hasPrefix("say (a tool)") })
    }

    // MARK: talking

    func testSomethingNotATemplateYetIsAnsweredWithTheTemplatesThatWouldDoIt() async {
        let out = await say("I need to know if it'll rain in Lagos tomorrow")
        XCTAssertTrue(out.hasPrefix("These can do that:"), out)
        XCTAssertTrue(out.contains("Weather\n     what's the weather in {a place}"), out)
        XCTAssertTrue(out.contains("search the web for {what to look for}"), out)
        let title = await say("Remember something")
        XCTAssertTrue(title.contains("- category: [PEOPLE | ORGANIZATIONS"), title)
    }

    func testAFilledTemplateIsDoneAtOnceAndSaidInWords() async throws {
        let found = await say("search the web for louvre hours")
        XCTAssertTrue(found.contains("1. Hours, admission | Louvre\n   https://www.louvre.fr/en/visit/hours"), found)
        let call = try XCTUnwrap(mac.calls(to: "/api/tools/web_search").last)
        XCTAssertEqual((call.body["arguments"] as? [String: Any])?["q"] as? String, "louvre hours")
        XCTAssertEqual(call.body["client"] as? String, "Peter")
        XCTAssertEqual(call.body["why"] as? String, "Tester asked in words: “search the web for louvre hours”", "the card says who asked, in their words")
        let remembered = await say("Remember something\n- category: people\n- about: Ada\n- fact: my sister\n- date: 03-14")
        XCTAssertTrue(remembered.hasPrefix("Remembered under PEOPLE: Ada."), remembered)
        let read = await say("read the note groceries")
        XCTAssertTrue(read.hasPrefix("The note groceries:\n- eggs\n- milk"), read)
        // A failure is a sentence, and the template that fixes it (no model: as it is).
        let missing = await say("read the note nope")
        XCTAssertTrue(missing.contains("There's no note called nope."), missing)
    }

    func testNoConversationIsKept() async {
        let yes = await say("yes")
        XCTAssertTrue(yes.contains("I keep no conversation"), yes)
        let more = await say("more")
        XCTAssertTrue(more.contains("every answer comes whole"), more)
        // An uncertain change isn't waiting for a yes: it says what to say, and that, said back, does it.
        let unsure = await say("Write a nte\n- name: shopping\n- txt: eggs")
        XCTAssertTrue(unsure.contains("Nothing was done. To do it, say it like this:"), unsure)
        XCTAssertTrue(mac.calls(to: "/api/tools/library").isEmpty, "nothing written")
        let exact = String(unsure[unsure.range(of: "say it like this:\n\n")!.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let done = await say(exact)
        XCTAssertTrue(done.hasPrefix("Wrote a new note, shopping."), done)
    }

    func testARunWaitsForTheMacAndTheClientIsToldTheMomentItsOver() async throws {
        let asked = await say("run the nightly backup", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertTrue(asked.hasPrefix("Asked for the nightly backup. I'll tell you how it goes."), asked)
        let run = try XCTUnwrap(mac.calls(to: "/api/tools/run_script").last)
        XCTAssertEqual(run.body["async"] as? Bool, true)
        XCTAssertEqual((run.body["arguments"] as? [String: Any])?["script"] as? String, "nightly-backup.sh")
        let id = try XCTUnwrap(mac.requestIDs.first)
        let waiting = await say("what happened to the backup")
        XCTAssertTrue(waiting.contains("waiting for someone at the Mac to OK it"), waiting)
        // Clicked, and over.
        mac.set(id, ["state": "succeeded", "ok": true, "run_id": "R1", "run": ["state": "succeeded", "output": "backed up 12 files\n", "code": 0]])
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first)
        XCTAssertEqual(news["client"] as? String, "Tester")
        XCTAssertEqual(news["text"] as? String, "Meanwhile: The nightly backup finished (it worked). It printed:\nbacked up 12 files")
        XCTAssertTrue(mac.calls.contains { $0.method == "GET" && $0.path == "/api/requests/\(id)" }, "collected, so Tool Mac Tool Run's open list is clear of it")
        // Told once: not again in the next reply.
        let next = await say("what's scheduled")
        XCTAssertFalse(next.contains("Meanwhile"), next)
    }

    func testNewsThatCouldntBeDeliveredComesFirstInTheNextReply() async throws {
        inbox.refuse = true
        _ = await say("greet Sam", replyTo: "http://127.0.0.1:8769/api/peter")
        let id = try XCTUnwrap(mac.requestIDs.first)
        mac.set(id, ["state": "denied", "ok": false])
        try await Task.sleep(nanoseconds: 50_000_000)
        let next = await say("what's scheduled")
        XCTAssertTrue(next.hasPrefix("Meanwhile: The greet didn't run: it was turned down on the Mac."), next)
    }

    func testAScriptsInputsComeFromItsTemplate() async throws {
        _ = await say("Postcard\n- to whom: Sam\n- the message: hello there")
        let run = try XCTUnwrap(mac.calls(to: "/api/tools/run_script").last)
        let args = run.body["arguments"] as? [String: Any]
        XCTAssertEqual(args?["script"] as? String, "postcard.sh")
        XCTAssertEqual(args?["args"] as? [String], ["Sam", "hello there"])
    }

    func testStopTakesBackWhatsStillWaiting() async throws {
        _ = await say("run the nightly backup")
        let stopped = await say("stop the backup")
        XCTAssertTrue(stopped.hasPrefix("Taken back: the nightly backup won't run."), stopped)
        let list = await say("what have I asked for today")
        XCTAssertTrue(list.contains("1. run the nightly backup (taken back)"), list)
        let byNumber = await say("show me number 1")
        XCTAssertFalse(byNumber.contains("I can't tell which"), byNumber)
    }

    func testWhenToolMacToolRunIsntThereItSaysSo() async {
        mac.down = true
        let out = await say("search the web for cats")
        XCTAssertTrue(out.contains("Tool Mac Tool Run isn't answering"), out)
    }

    // MARK: Peter's model

    func testWordsNoTemplateFitsAreReadByTheModelAndSaidHowTheyWereTaken() async throws {
        withModel()
        model.says(#"{"meaning": "rain in Lagos", "suggestions": [{"title": "Search the web", "say": "search the web for rain in Lagos tomorrow", "confidence": 0.9}], "question": ""}"#)
        let out = await say("gonna need an umbrella in Lagos tomorrow?")
        XCTAssertTrue(out.hasPrefix("Taken as: search the web for rain in Lagos tomorrow"), out)
        XCTAssertTrue(out.contains("Hours, admission | Louvre"), out)
        XCTAssertTrue(model.lastUser.hasPrefix("Said: \"gonna need an umbrella in Lagos tomorrow?\""), model.lastUser)
        XCTAssertFalse(model.lastUser.contains("Tester"), "the model sees no client, no history")
    }

    func testExactNeverAsksTheModel() async {
        withModel()
        model.says(#"{"meaning": "", "suggestions": [{"title": "Search the web", "say": "search the web for x", "confidence": 0.9}], "question": ""}"#)
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say?exact=true", headers: ["X-Client": "Tester"], body: Data("gonna need an umbrella?".utf8)))
        let out = String(decoding: r.bodyData ?? Data(), as: UTF8.self)
        XCTAssertFalse(out.contains("Taken as"), out)
        XCTAssertEqual(model.count, 0, "the model isn't asked")
        let read = await peter.say("read the note groceries", client: "Tester", exact: true)
        XCTAssertTrue(read.hasPrefix("The note groceries:"), read)
    }

    func testAutoIsTheBestModelOllamaHas() async {
        var s = SayTranslator.Settings()
        XCTAssertEqual(s.model, "auto")
        s.on = true
        let t = SayTranslator(file: nil, settings: s, send: model.send)
        model.says(#"{"meaning": "", "suggestions": [], "question": "what?"}"#)
        _ = await t.translate("hm", why: .nothing, forms: SayForms.builtins, closest: 0)
        XCTAssertEqual(model.lastModel, "qwen3:8b")
        XCTAssertEqual(SayTranslator.best(["llama3.2:3b", "mistral:7b"]), "llama3.2:3b")
        XCTAssertEqual(SayTranslator.best(["nomic-embed-text", "whatever:1b"]), "whatever:1b")
    }

    func testTheModelPlaysWhileItWorks() async {
        withModel()
        let seen = Inbox()
        let flips = LockedList()
        await peter.translator.observe { busy in flips.add(busy) }
        _ = seen
        model.says(#"{"meaning": "", "suggestions": [], "question": ""}"#)
        _ = await say("zzz qqq")
        XCTAssertEqual(flips.items, [true, false])
    }

    func testAFailureIsLookedAtByTheModelAndTriedOnceAnotherWay() async throws {
        withModel()
        model.says(#"{"meaning": "the note is called groceries, not nope", "suggestions": [{"title": "Read a note", "say": "read the note groceries", "confidence": 0.9}], "question": ""}"#)
        let out = await say("read the note nope")
        XCTAssertTrue(out.hasPrefix("There's no note called nope.\nTried instead: read the note groceries"), out)
        XCTAssertTrue(out.contains("The note groceries:"), out)
        XCTAssertTrue(model.lastUser.contains("and it failed: There's no note called nope."), model.lastUser)
        // Nothing it can do: the failure, and what it makes of it.
        model.says(#"{"meaning": "there's no such note", "suggestions": [], "question": "Which note did you mean?"}"#)
        let none = await say("read the note nope")
        XCTAssertTrue(none.hasPrefix("There's no note called nope.\nThere's no such note.\nWhich note did you mean?"), none)
    }

    // MARK: the schedule

    func testAReminderIsSaidBackWhenItsDue() async throws {
        let set = await say("Remind me\n- when: in 20 minutes\n- message: call Sam", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertTrue(set.hasPrefix("Set for today at") || set.hasPrefix("Set for tomorrow at"), set)
        XCTAssertTrue(set.contains("(in 20 minutes): a reminder: call Sam. Its number is 1. I'll tell you then."), set)
        let list = await say("what's scheduled")
        XCTAssertTrue(list.contains("1. ") && list.contains("a reminder: call Sam"), list)
        // It comes due.
        await peter.start()
        await peter.schedule.tick(now: Date().addingTimeInterval(21 * 60))
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first?["text"] as? String)
        XCTAssertTrue(news.hasPrefix("Meanwhile: Reminder (Scheduled today at"), news)
        XCTAssertTrue(news.hasSuffix("number 1): call Sam"), news)
        let after = await say("what's scheduled")
        XCTAssertTrue(after.contains("Nothing is scheduled."), after)
    }

    func testARequestForLaterIsDoneThenAndARepeatingOneGoesOn() async throws {
        let set = await say("Do something later\n- when: tomorrow 7am\n- repeat: every day\n- what: search the web for Lagos weather", replyTo: "http://127.0.0.1:8769/api/peter")
        XCTAssertTrue(set.contains("then every day: search the web for Lagos weather"), set)
        let items = await peter.schedule.items
        let item = try XCTUnwrap(items.first)
        await peter.start()
        await peter.schedule.tick(now: item.due.addingTimeInterval(1))
        await until { !self.inbox.got.isEmpty }
        let news = try XCTUnwrap(inbox.got.first?["text"] as? String)
        XCTAssertTrue(news.contains("Done as scheduled (Scheduled every day"), news)
        XCTAssertTrue(news.contains("Hours, admission | Louvre"), news)
        let nextItems = await peter.schedule.items
        let next = try XCTUnwrap(nextItems.first)
        XCTAssertEqual(next.due.timeIntervalSince(item.due), 86400, accuracy: 3700, "the next day")
        let cancelled = await say("cancel the schedule lagos")
        XCTAssertTrue(cancelled.hasPrefix("Taken off the schedule: 1. search the web for Lagos weather."), cancelled)
    }

    func testSomethingForLaterInASentenceIsReadWithoutAModel() async throws {
        let now = Date()
        func read(_ s: String) -> LaterWords? { LaterWords.read(s, now: now) }
        XCTAssertEqual(read("remind me in 20 minutes to tell the user to call Sam"), LaterWords(kind: .remind, when: "in 20 minutes", repeats: nil, text: "tell the user to call Sam"))
        XCTAssertEqual(read("remind me at 5pm: the oven"), LaterWords(kind: .remind, when: "at 5pm", repeats: nil, text: "the oven"))
        XCTAssertEqual(read("remind me to stretch in an hour"), LaterWords(kind: .remind, when: "in an hour", repeats: nil, text: "stretch"))
        XCTAssertEqual(read("every weekday at 8am, search the web for traffic on I-35"), LaterWords(kind: .later, when: "8am", repeats: .weekdays, text: "search the web for traffic on I-35"))
        XCTAssertEqual(read("every morning: remind me to drink water"), LaterWords(kind: .remind, when: "7:00", repeats: .daily, text: "drink water"))
        XCTAssertEqual(read("in 2 hours, run the nightly backup"), LaterWords(kind: .later, when: "in 2 hours", repeats: nil, text: "run the nightly backup"))
        XCTAssertNil(read("tomorrow, what's the weather"), "a question about tomorrow")
        XCTAssertNil(read("remind me what I asked for"))
        XCTAssertNil(read("search the web for Walmart hours"))
        // Said so to Peter: set, with no model to ask.
        let set = await say("remind me in 20 minutes to tell the user to call Sam")
        XCTAssertTrue(set.contains("(in 20 minutes): a reminder: tell the user to call Sam."), set)
        XCTAssertEqual(model.count, 0)
    }

    func testTheScheduleOutlastsARestart() async throws {
        _ = await say("Remind me\n- when: tomorrow 9am\n- message: stand up")
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
        let forms = String(decoding: (await peter.route(HTTPRequest(method: "GET", target: "/api/say/forms?q=remind"))).bodyData ?? Data(), as: UTF8.self)
        XCTAssertTrue(forms.hasPrefix("Remind me"), forms)
        let log = json(await peter.route(HTTPRequest(method: "GET", target: "/api/say/log", headers: ["X-Client": "App"])))
        XCTAssertEqual(log["client"] as? String, "App")
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Bool] = []
    var items: [Bool] { lock.withLock { _items } }
    func add(_ b: Bool) { lock.withLock { _items.append(b) } }
}
