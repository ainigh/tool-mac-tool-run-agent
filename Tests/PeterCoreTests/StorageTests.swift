import Foundation
@testable import PeterCore
import XCTest

/// Peter with Storage Spaces: the person's notes, MEMORY and mind straight from it (Tool Mac Tool
/// Run only when it isn't answering); Super Face's notes in its own space; his own things kept in
/// his space, and taken back from it when it has newer; and apps let in only by the person.
final class StorageTests: XCTestCase {
    var home: URL!
    var mac: FakeToolMac!
    var store: FakeStorage!
    var model: FakeModel!
    var peter: Peter!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("peter-storage-\(UUID().uuidString)", isDirectory: true)
        mac = FakeToolMac()
        store = FakeStorage()
        model = FakeModel()
        peter = make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func make() -> Peter {
        var s = Brain.Settings()
        s.model = "qwen3:8b"
        return Peter(toolMac: ToolMac(fresh: 0, send: mac.send),
                     storage: StorageSpaces(keyFile: home.appendingPathComponent("storage-key"), send: store.send),
                     brain: Brain(file: home.appendingPathComponent("model.json"), settings: s, send: model.send),
                     schedule: Schedule(file: home.appendingPathComponent("schedule.json")), sayEvery: 5_000_000, deliver: Inbox().deliver)
    }

    /// The model says back what the last tool gave back.
    static let echo = FakeModel.Move.reads { messages in
        let last = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let j = JSON.object(Data(last.utf8)) ?? [:]
        if let said = j["said"] as? String ?? j["error"] as? String { return .says(said) }
        if let text = j["text"] as? String { return .says("The note: " + text) }
        return .says(last)
    }

    func testTheLibraryMemoryAndMindComeStraightFromStorageSpaces() async throws {
        model.plays(.call("library", ["op": "read", "name": "groceries"]), Self.echo)
        let read = await peter.say("read the note groceries", client: "Tester")
        XCTAssertEqual(read, "The note: - bread (from Storage Spaces)")
        XCTAssertTrue(mac.calls(to: "/api/tools/library").isEmpty, "not through Tool Mac Tool Run")
        let call = try XCTUnwrap(store.calls.first { $0.path == "/api/library" })
        XCTAssertEqual((call.body as? [String: Any])?["op"] as? String, "read")
        XCTAssertTrue(store.calls.contains { $0.path == "/api/clients/register" }, "he claims his name the first time")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("storage-key"), encoding: .utf8), "k3y")
        model.plays(.call("recall", ["name": "Ada"]), Self.echo)
        _ = await peter.say("what do you know about Ada", client: "Tester")
        XCTAssertTrue(model.lastResult.contains("| PEOPLE | ada"), model.lastResult)
        XCTAssertTrue(store.calls.contains { $0.path == "/api/memory/recall?name=Ada" })
        // Storage Spaces closed: Tool Mac Tool Run, as before.
        store.down = true
        let peter2 = make()
        model.plays(.call("library", ["op": "read", "name": "groceries"]), Self.echo)
        let again = await peter2.say("read the note groceries", client: "Tester")
        XCTAssertEqual(again, "The note: - eggs\n- milk")
        XCTAssertFalse(mac.calls(to: "/api/tools/library").isEmpty)
    }

    func testHisThingsAreKeptInHisSpaceAndTakenBackWhenNewer() async throws {
        model.plays(.call("schedule", ["op": "remind", "when": "in 20 minutes", "text": "stand up"]), Self.echo)
        _ = await peter.say("remind me in 20 minutes to stand up", client: "Tester")
        _ = try await peter.brain.change(["model": "qwen3:8b", "key": "secret"])
        await peter.keepInStorage()
        await until { self.store.record("status/now") != nil && self.store.record("settings/model") != nil }
        let kept = try XCTUnwrap(store.record("schedule/schedule") as? [String: Any])
        XCTAssertEqual((kept["items"] as? [[String: Any]])?.first?["text"] as? String, "stand up")
        let settings = try XCTUnwrap(store.record("settings/model") as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, "qwen3:8b")
        XCTAssertNil(settings["key"], "the key never leaves the Mac's own file")
        XCTAssertEqual((store.record("status/now") as? [String: Any])?["service"] as? String, "peter")
        // Unchanged: not written again (but how things stand, which has the time in it).
        let puts = store.calls.filter { $0.method == "PUT" && !$0.path.hasSuffix("/now") }.count
        await peter.keepInStorage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.calls.filter { $0.method == "PUT" && !$0.path.hasSuffix("/now") }.count, puts)

        // A newer schedule in Storage Spaces (another copy of Peter wrote it): taken.
        let later = Date().addingTimeInterval(3600)
        store.set("schedule/schedule", ["next": 8, "items": [["id": 7, "client": "Super Face", "kind": "remind", "text": "drink water",
                                                              "due": ISO8601DateFormatter().string(from: later), "created": ISO8601DateFormatter().string(from: Date()), "fired": 0]]],
                  updated: Date().addingTimeInterval(60))
        store.set("following/runs", ["clients": [["client": "Super Face", "counter": 4, "entries": [[
            "number": 4, "asked": JSON.date(Date()), "said": "run the backup", "form": "nightly-backup", "what": "the nightly backup", "short": "the nightly backup",
            "state_kind": "waiting", "asks": true, "request": UUID().uuidString, "told": "waiting"]]]]])
        let fresh = make()
        await fresh.restoreFromStorage()
        let items = await fresh.schedule.items
        XCTAssertEqual(items.map(\.text), ["drink water"])
        let entries = await fresh.sayLog.entries("Super Face")
        XCTAssertEqual(entries.map(\.number), [4])
        XCTAssertEqual(entries.first?.state, .waiting)
        // An older one isn't.
        store.set("schedule/schedule", ["next": 1, "items": [] as [Any]], updated: .distantPast)
        let third = make()
        await third.restoreFromStorage()
        let kept3 = await third.schedule.items
        XCTAssertEqual(kept3.map(\.text), ["drink water"], "its own file is newer")
    }

    func testAppsAreLetInOnlyByThePerson() async throws {
        model.plays(.call("access", ["op": "requests"]), Self.echo)
        let asking = await peter.say("who's asking for access", client: "Super Voice")
        XCTAssertTrue(asking.contains("request 3: Super Voice asks to read USER/MEMORY (\"to greet people\")"), asking)
        model.plays(.call("access", ["op": "approve", "number": 3]), Self.echo)
        let itself = await peter.say("allow request 3", client: "Super Voice")
        XCTAssertTrue(itself.contains("Only the person says yes"), itself)
        XCTAssertEqual(store.requests.first?["state"] as? String, "open")
        // Over HTTP, no app can be Peter's window.
        model.plays(.call("access", ["op": "approve", "number": 3]), Self.echo)
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: ["Content-Type": "text/plain", "X-Client": "Peter's window"], body: Data("allow request 3".utf8)))
        XCTAssertTrue(String(decoding: r.bodyData ?? Data(), as: UTF8.self).contains("Only the person says yes"))
        // The person, in Peter's window.
        model.plays(.call("access", ["op": "approve", "number": 3]), Self.echo)
        let yes = await peter.say("allow request 3", client: "Peter's window")
        XCTAssertEqual(yes, "Said yes to request 3: Super Voice may read USER/MEMORY.")
        XCTAssertEqual(store.requests.first?["state"] as? String, "approved")
        model.plays(.call("access", ["op": "grant", "app": "Super Face", "place": "my memory", "access": "read"]), Self.echo)
        let let_ = await peter.say("let Super Face read my memory", client: "Peter's window")
        XCTAssertEqual(let_, "Super Face may read USER/MEMORY.")
        model.plays(.call("access", ["op": "revoke", "app": "Super Face"]), Self.echo)
        let back = await peter.say("stop letting Super Face in", client: "Tester")
        XCTAssertTrue(back.hasPrefix("Took back what Super Face was let into (1)"), back)
    }

    func testSuperFacesNotesAreInItsOwnSpace() async throws {
        model.plays(.call("space_notes", ["place": "super/prompt", "op": "append", "name": "instructions", "text": "- When the user says walmart, say only yes or no."]), .says("Added."))
        let added = await peter.say("add to Super Face's instructions: When the user says walmart, say only yes or no.", client: "Super Face")
        XCTAssertEqual(added, "Added.")
        let call = try XCTUnwrap(store.calls.first { $0.path == "/api/spaces/super/prompt" })
        let body = try XCTUnwrap(call.body as? [String: Any])
        XCTAssertEqual(body["op"] as? String, "append")
        XCTAssertEqual(body["name"] as? String, "instructions")
        XCTAssertNil(body["place"])
        // The person's own space isn't this tool's.
        model.plays(.call("space_notes", ["place": "user/library", "op": "read", "name": "x"]), Self.echo)
        let mine = await peter.say("read my note x", client: "Super Face")
        XCTAssertTrue(mine.hasPrefix("place is super/prompt, super/memory, or other/<app>"), mine)
    }

    func testWhatOfYoursAPhraseMeans() {
        XCTAssertTrue(StorageSpaces.place("my memory")! == ("user", "memory"))
        XCTAssertTrue(StorageSpaces.place("my notes")! == ("user", "library"))
        XCTAssertTrue(StorageSpaces.place("the mind")! == ("user", "mind"))
        XCTAssertTrue(StorageSpaces.place("Super Face's prompt")! == ("super", "prompt"))
        XCTAssertTrue(StorageSpaces.place("everything of mine")! == ("user", nil))
        XCTAssertNil(StorageSpaces.place("the moon"))
    }
}
