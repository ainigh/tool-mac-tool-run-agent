import AppKit
import PeterCore
import ServiceManagement
import SwiftUI

/// Peter in the menu bar: his icon (it changes while his model works), a menu with how things
/// stand, his window (talk to him, typed or spoken; the schedule; his settings), updates, and
/// Quit. His HTTP API runs while the app does, on 127.0.0.1:8770.
@main
struct PeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The icon and its menu are AppKit's (`AppDelegate`). This scene is never shown; it's
        // here because an app needs one.
        MenuBarExtra("Peter", systemImage: "person.wave.2", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

/// One message in Peter's window: what was said to him, or what he said. Kept only while the
/// window is open.
struct Exchange: Identifiable, Equatable {
    enum Who { case you, peter }
    let id = UUID()
    let who: Who
    let text: String
    let at = Date()
}

/// What the app holds: Peter himself, his server, how things stand, and what his window shows.
@MainActor
final class PeterModel: ObservableObject {
    static let shared = PeterModel()

    /// Who the window is, to Peter: a client like any other, forgotten when the window closes.
    static let windowClient = Peter.personClients.first!

    let peter: Peter
    let server: APIServer
    let updater = Updater()

    @Published private(set) var serverState: APIServer.State = .stopped
    /// His model is working (reading words, or a failure): the sound plays.
    @Published private(set) var busy = false
    @Published private(set) var health: [String: Any] = [:]
    @Published private(set) var schedule: [Schedule.Item] = []
    @Published private(set) var exchanges: [Exchange] = []
    /// Requests from the window still being answered.
    @Published private(set) var waiting = 0
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var busySound = UserDefaults.standard.object(forKey: "busySound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(busySound, forKey: "busySound") }
    }
    @Published var toolMacURL = UserDefaults.standard.string(forKey: "toolMacURL") ?? ToolMac.defaultURL
    @Published private(set) var modelSettings = SayTranslator.Settings()
    /// The models Ollama has (nil: it isn't answering): the only ones the window offers.
    @Published private(set) var ollamaModels: [String]?
    /// What "auto" was taken as last.
    @Published private(set) var pickedModel: String?
    /// The latest time his model was asked: what it was given.
    @Published private(set) var lastCall: SayTranslator.Call?
    /// The window's tab (the menu opens it on one).
    @Published var tab = 0
    /// The window is showing.
    @Published var windowShown = false

    private var soundTimer: Timer?
    private var refreshTimer: Timer?
    /// Called when the busy state changes (the menu bar icon).
    var onBusy: ((Bool) -> Void)?

    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private init() {
        let url = UserDefaults.standard.string(forKey: "toolMacURL") ?? ToolMac.defaultURL
        peter = Peter(toolMac: ToolMac(url: url), version: Self.version)
        server = APIServer(api: peter)
        server.onState = { [weak self] state in MainActor.assumeIsolated { self?.serverState = state } }
        // Start at login from the first launch; the menu has the switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    func start() {
        server.start(port: Peter.port, network: false)
        let peter = self.peter
        Task {
            await peter.translator.observe { busy in
                DispatchQueue.main.async { MainActor.assumeIsolated { PeterModel.shared.setBusy(busy) } }
            }
            await peter.start(onChange: {
                DispatchQueue.main.async { MainActor.assumeIsolated { PeterModel.shared.refreshSchedule() } }
            })
            await refresh()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in await PeterModel.shared.refresh() }
        }
        updater.start()
    }

    /// How things stand: Tool Mac Tool Run, the model, the schedule.
    func refresh() async {
        health = await peter.health()
        modelSettings = await peter.translator.settings
        pickedModel = await peter.translator.pickedModel
        lastCall = await peter.translator.calls.last
        schedule = await peter.schedule.list()
    }

    /// Asks Ollama what models it has.
    func refreshModels() async {
        ollamaModels = await peter.translator.ollamaModels()
    }

    /// Uses one of Ollama's models ("auto": the best it has): nil, or what's wrong.
    func useOllama(_ name: String) async -> String? {
        let s = modelSettings
        // Ollama's own address, unless it's set to another Ollama already.
        let url = !s.isOllama ? SayTranslator.Settings.ollama : s.url
        return await changeModel(["api": "openai", "url": url, "model": name])
    }

    func refreshSchedule() {
        Task { schedule = await peter.schedule.list() }
    }

    // MARK: the busy sound

    func setBusy(_ b: Bool) {
        guard b != busy else { return }
        busy = b
        onBusy?(b)
        soundTimer?.invalidate()
        soundTimer = nil
        guard b, busySound else { return }
        Self.playBusy()
        soundTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in Self.playBusy() }
    }

    /// Peter's own sound while his model works: distinct from anything else on the Mac.
    nonisolated static func playBusy() {
        let sound = NSSound(named: "Morse") ?? NSSound(named: "Tink")
        sound?.volume = 0.35
        sound?.play()
    }

    // MARK: the window

    /// Says something to Peter from the window: nothing said before goes with it.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        exchanges.append(Exchange(who: .you, text: t))
        waiting += 1
        let peter = self.peter
        Task {
            let answer = await peter.say(t, client: Self.windowClient)
            exchanges.append(Exchange(who: .peter, text: answer))
            waiting -= 1
            schedule = await peter.schedule.list()
        }
    }

    /// The window closed: nothing of it is kept.
    func forget() {
        exchanges = []
        let peter = self.peter
        Task { await peter.sayLog.reset(Self.windowClient) }
    }

    // MARK: settings

    func setToolMacURL(_ url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        toolMacURL = u.isEmpty ? ToolMac.defaultURL : u
        UserDefaults.standard.set(toolMacURL, forKey: "toolMacURL")
        let peter = self.peter, value = toolMacURL
        Task {
            await peter.toolMac.setURL(value)
            await refresh()
        }
    }

    /// Changes the model's settings: nil, or what's wrong.
    func changeModel(_ fields: [String: Any]) async -> String? {
        do {
            try await peter.translator.change(fields)
            await refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    func cancelSchedule(_ id: Int) {
        let peter = self.peter
        Task {
            await peter.schedule.remove(id)
            schedule = await peter.schedule.list()
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            setIcon(busy: false)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            let model = PeterModel.shared
            model.onBusy = { [weak self] busy in self?.setIcon(busy: busy) }
            model.start()
        }
    }

    @MainActor
    private func setIcon(busy: Bool) {
        let name = busy ? "ellipsis.bubble.fill" : "person.wave.2"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: busy ? "Peter (working)" : "Peter")
        item.button?.toolTip = busy ? "Peter is working something out" : "Peter"
    }

    // MARK: the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { build(menu) }
    }

    @MainActor
    private func build(_ menu: NSMenu) {
        let model = PeterModel.shared
        Task { await model.refresh() }
        menu.removeAllItems()
        func info(_ title: String) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        func action(_ title: String, _ selector: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        let tm = model.health["tool_mac_tool_run"] as? [String: Any] ?? [:]
        let m = model.health["model"] as? [String: Any] ?? [:]
        info(model.busy ? "Peter — working something out…" : "Peter — ready")
        switch model.serverState {
        case let .running(port): info("Listening on 127.0.0.1:\(port)")
        case let .failed(why): info("Not listening: \(why)")
        default: info("Not listening yet")
        }
        if tm["reachable"] as? Bool == true {
            info("Tool Mac Tool Run: \(tm["tools"] as? Int ?? 0) tools, \(tm["scripts"] as? Int ?? 0) scripts, \(tm["flows"] as? Int ?? 0) flows")
        } else {
            info("Tool Mac Tool Run isn't answering")
        }
        let st = model.health["storage_spaces"] as? [String: Any] ?? [:]
        info(st["ready"] as? Bool == true ? "Storage Spaces: his things, your notes and MEMORY" : "Storage Spaces isn't answering")
        let shown = m["model"] as? String ?? "?"
        let auto = shown == SayTranslator.Settings.auto ? (m["picked"] as? String).map { " (\($0))" } ?? "" : ""
        info("Model: \((m["on"] as? Bool) == false ? "off" : shown + auto)\((m["ready"] as? Bool) == false ? " (out of reach)" : "")")
        menu.addItem(.separator())
        action(window == nil ? "Talk to Peter…" : "Hide Peter's Window", #selector(toggleWindow), key: "t")
        let count = model.schedule.count
        action(count == 0 ? "Nothing scheduled" : "Scheduled (\(count))…", #selector(openSchedule))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = model.openAtLogin ? .on : .off
        menu.addItem(login)
        let sound = NSMenuItem(title: "A Sound While Peter Thinks", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = model.busySound ? .on : .off
        menu.addItem(sound)
        menu.addItem(.separator())
        info(model.updater.versionLine)
        switch model.updater.state {
        case let .available(plan): action("Update: \(plan.title)", #selector(installUpdate))
        case let .installing(step): info(step)
        case .checking: info("Checking for updates…")
        case let .failed(why):
            info(why)
            action("Check for Updates", #selector(checkUpdates))
        default: action("Check for Updates", #selector(checkUpdates))
        }
        menu.addItem(.separator())
        action("Quit Peter", #selector(quit), key: "q")
    }

    /// The menu's one switch for the window: shown, it goes (and what was said in it is
    /// forgotten); not shown, it comes, in front of every other window, and stays there (it has
    /// no close button, and doesn't go when another app is used) until the menu says otherwise.
    @objc func toggleWindow() {
        MainActor.assumeIsolated {
            if window != nil { hideWindow() } else { showWindow(tab: 0) }
        }
    }

    /// The schedule: the window on its tab (shown already: it stays, on that tab).
    @objc func openSchedule() {
        MainActor.assumeIsolated { showWindow(tab: 1) }
    }

    @MainActor
    private func showWindow(tab: Int) {
        PeterModel.shared.tab = tab
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            w.title = "Peter"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.hidesOnDeactivate = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentViewController = NSHostingController(rootView: PeterView().environmentObject(PeterModel.shared).environmentObject(PeterModel.shared.updater))
            w.delegate = self
            w.center()
            window = w
        }
        PeterModel.shared.windowShown = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func hideWindow() {
        window?.close()
    }

    /// The window closed: what was said in it is forgotten.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            PeterModel.shared.forget()
            PeterModel.shared.windowShown = false
            window = nil
        }
    }

    @objc func toggleLogin() { MainActor.assumeIsolated { PeterModel.shared.setOpenAtLogin(!PeterModel.shared.openAtLogin) } }
    @objc func toggleSound() { MainActor.assumeIsolated { PeterModel.shared.busySound.toggle() } }
    @objc func checkUpdates() { MainActor.assumeIsolated { PeterModel.shared.updater.check(userInitiated: true) } }
    @objc func installUpdate() { MainActor.assumeIsolated { PeterModel.shared.updater.install() } }
    @objc func quit() { NSApp.terminate(nil) }
}
