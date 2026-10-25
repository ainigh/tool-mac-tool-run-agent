import Foundation
@testable import PeterCore
import XCTest

/// Peter with Storage Spaces: the person's notes, MEMORY and mind straight from it (Tool Mac Tool
/// Run only when it isn't answering); his own things kept in his space, and taken back from it
/// when it has newer; and apps let in, in words, only by the person.
final class StorageTests: XCTestCase {
    var home: URL!
    var mac: FakeToolMac!
    var store: FakeStorage!
    var peter: Peter!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("peter-storage-\(UUID().uuidString)", isDirectory: true)
        mac = FakeToolMac()
        store = FakeStorage()
        peter = make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func make() -> Peter {
        var s = SayTranslator.Settings()
        s.on = false
        return Peter(toolMac: ToolMac(fresh: 0, send: mac.send),
                     storage: StorageSpaces(keyFile: home.appendingPathComponent("storage-key"), send: store.send),
                     translator: SayTranslator(file: home.appendingPathComponent("model.json"), settings: s, send: FakeModel().send),
                     schedule: Schedule(file: home.appendingPathComponent("schedule.json")), sayEvery: 5_000_000, deliver: Inbox().deliver)
    }

    func testTheLibraryMemoryAndMindComeStraightFromStorageSpaces() async throws {
        let read = await peter.say("read the note groceries", client: "Tester")
        XCTAssertTrue(read.hasPrefix("The note groceries:\n- bread (from Storage Spaces)"), read)
        XCTAssertTrue(mac.calls(to: "/api/tools/library").isEmpty, "not through Tool Mac Tool Run")
        let call = try XCTUnwrap(store.calls.first { $0.path == "/api/library" })
        XCTAssertEqual((call.body as? [String: Any])?["op"] as? String, "read")
        XCTAssertTrue(store.calls.contains { $0.path == "/api/clients/register" }, "he claims his name the first time")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("storage-key"), encoding: .utf8), "k3y")
        let recalled = await peter.say("what do you know about Ada", client: "Tester")
        XCTAssertTrue(recalled.contains("What's known about Ada"), recalled)
        // Storage Spaces closed: Tool Mac Tool Run, as before.
        store.down = true
        let peter2 = make()
        let again = await peter2.say("read the note groceries", client: "Tester")
        XCTAssertTrue(again.hasPrefix("The note groceries:\n- eggs\n- milk"), again)
        XCTAssertFalse(mac.calls(to: "/api/tools/library").isEmpty)
    }

    func testHisThingsAreKeptInHisSpaceAndTakenBackWhenNewer() async throws {
        _ = await peter.say("remind me in 20 minutes to stand up", client: "Tester")
        _ = try await peter.translator.change(["model": "qwen3:8b", "key": "secret"])
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
        let asking = await peter.say("who's asking for access", client: "Super Voice")
        XCTAssertTrue(asking.contains("request 3: Super Voice asks to read USER/MEMORY (\"to greet people\")"), asking)
        let itself = await peter.say("allow request 3", client: "Super Voice")
        XCTAssertTrue(itself.contains("Only the person says yes"), itself)
        XCTAssertEqual(store.requests.first?["state"] as? String, "open")
        // Over HTTP, no app can be Peter's window.
        let r = await peter.route(HTTPRequest(method: "POST", target: "/api/say", headers: ["Content-Type": "text/plain", "X-Client": "Peter's window"], body: Data("allow request 3".utf8)))
        XCTAssertTrue(String(decoding: r.bodyData ?? Data(), as: UTF8.self).contains("Only the person says yes"))
        // The person, in Peter's window.
        let yes = await peter.say("allow request 3", client: "Peter's window")
        XCTAssertEqual(yes, "Said yes to request 3: Super Voice may read USER/MEMORY.")
        XCTAssertEqual(store.requests.first?["state"] as? String, "approved")
        let let_ = await peter.say("let Super Face read my memory", client: "Peter's window")
        XCTAssertEqual(let_, "Super Face may read USER/MEMORY.")
        let back = await peter.say("stop letting Super Face in", client: "Tester")
        XCTAssertTrue(back.hasPrefix("Took back what Super Face was let into (1)"), back)
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
