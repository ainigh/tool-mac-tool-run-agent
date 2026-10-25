import AppKit
import PeterCore
import SwiftUI

/// Peter's window: talk to him (typed, or spoken with the microphone), what's scheduled, the
/// prompt his model is given, and his settings. It stays in front until the menu hides it.
/// Every message goes to him on its own, with nothing said before it, and nothing of the talk is
/// kept once the window goes: it's his API, with a face.
struct PeterView: View {
    @EnvironmentObject var model: PeterModel

    var body: some View {
        VStack(spacing: 0) {
            StatusLine()
            Picker("", selection: $model.tab) {
                Text("Talk").tag(0)
                Text("Scheduled (\(model.schedule.count))").tag(1)
                Text("Prompt").tag(2)
                Text("Settings").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            switch model.tab {
            case 0: TalkView()
            case 1: ScheduleView()
            case 2: PromptView()
            default: SettingsView()
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

/// How things stand, in a line: Tool Mac Tool Run, the model, and whether he's working.
struct StatusLine: View {
    @EnvironmentObject var model: PeterModel

    var body: some View {
        let tm = model.health["tool_mac_tool_run"] as? [String: Any] ?? [:]
        let m = model.health["model"] as? [String: Any] ?? [:]
        let reachable = tm["reachable"] as? Bool == true
        HStack(spacing: 8) {
            Circle().fill(reachable ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(reachable ? "Tool Mac Tool Run: \(tm["tools"] as? Int ?? 0) tools, \(tm["scripts"] as? Int ?? 0) scripts, \(tm["flows"] as? Int ?? 0) flows" : "Tool Mac Tool Run isn't answering")
                .font(.caption)
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Model: \((m["on"] as? Bool) == false ? "off" : (m["model"] as? String ?? "?"))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

/// Talking to Peter: what was said each way, and a line to type in (or the microphone).
struct TalkView: View {
    @EnvironmentObject var model: PeterModel
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.exchanges.isEmpty {
                            Text("Say what you want, in your own words: \"what's the weather in Lagos\", \"remind me in 20 minutes to stand up\", \"search the web for Walmart hours Austin\". Each message is on its own: Peter keeps no conversation, and nothing here is kept once this window closes.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(model.exchanges) { e in
                            Bubble(exchange: e).id(e.id)
                        }
                        if model.waiting > 0 {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Peter is on it…").font(.caption).foregroundStyle(.secondary)
                            }
                            .id("waiting")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.exchanges.count) {
                    withAnimation { scroll.scrollTo(model.exchanges.last?.id, anchor: .bottom) }
                }
            }
            Divider()
            if let problem = dictation.problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(dictation.listening ? "Listening…" : "Tell Peter what you want", text: dictation.listening ? .constant(dictation.heard) : $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(dictation.listening)
                Button {
                    if dictation.listening { dictation.stop() } else { dictation.start { model.send($0) } }
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.listening ? Color.red : Color.primary)
                }
                .help(dictation.listening ? "Stop listening (what was heard is sent)" : "Speak to Peter")
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .onAppear { focused = true }
        .onDisappear { dictation.cancel() }
    }

    private func send() {
        let t = draft
        draft = ""
        model.send(t)
    }
}

struct Bubble: View {
    let exchange: Exchange

    var body: some View {
        let you = exchange.who == .you
        VStack(alignment: you ? .trailing : .leading, spacing: 2) {
            Text(you ? "You" : "Peter").font(.caption2).foregroundStyle(.secondary)
            Text(exchange.text)
                .textSelection(.enabled)
                .font(you ? .body : .system(.body, design: .default))
                .padding(8)
                .background(you ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: you ? .trailing : .leading)
    }
}

/// What's scheduled, for every client, each with a way to take it off.
struct ScheduleView: View {
    @EnvironmentObject var model: PeterModel

    var body: some View {
        if model.schedule.isEmpty {
            VStack {
                Spacer()
                Text("Nothing is scheduled. Ask Peter: \"remind me at 5 to call Sam\", \"every morning at 7, what's the weather\".")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
        } else {
            List(model.schedule, id: \.id) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.what).lineLimit(3)
                        Text("\(When.long(item.due)) (\(When.fromNow(item.due)))\(item.repeats.map { ", \($0.said)" } ?? "") · for \(item.client)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.cancelSchedule(item.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Take it off the schedule")
                }
            }
        }
    }
}

/// Where Tool Mac Tool Run is, Peter's model, the sound, and updates.
struct SettingsView: View {
    @EnvironmentObject var model: PeterModel
    @EnvironmentObject var updater: Updater
    @State private var toolMac = ""
    @State private var problem: String?

    /// The model the settings have, as the picker shows it ("auto" when it's that, or empty).
    private var current: String {
        let m = model.modelSettings.model
        return m.isEmpty || !model.modelSettings.isOllama ? Brain.Settings.auto : m
    }

    var body: some View {
        Form {
            Section("Tool Mac Tool Run") {
                HStack {
                    TextField("Its address", text: $toolMac)
                    Button("Use") { model.setToolMacURL(toolMac) }
                }
            }
            Section("Peter's model") {
                Toggle("Use a model (without one, Peter can't do anything: it reads every request)", isOn: Binding(get: { model.modelSettings.on }, set: { on in
                    Task { problem = await model.changeModel(["on": on]) }
                }))
                if let models = model.ollamaModels {
                    if models.isEmpty {
                        Text("Ollama has no models yet: in Terminal, ollama pull qwen3:8b, then Refresh.").foregroundStyle(.secondary)
                    }
                    Picker("Model", selection: Binding(get: { current }, set: { pick in
                        Task { problem = await model.useOllama(pick) }
                    })) {
                        Text("Automatic: the best Ollama has" + (model.pickedModel.map { " (now \($0))" } ?? "")).tag(Brain.Settings.auto)
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        if current != Brain.Settings.auto, !models.contains(current) {
                            Text("\(current) (not in Ollama)").tag(current)
                        }
                    }
                } else {
                    Text("Ollama isn't answering at 127.0.0.1:11434. Open Ollama (or brew services start ollama), then Refresh.").foregroundStyle(.secondary)
                }
                if !model.modelSettings.isOllama {
                    Text("Now: \(model.modelSettings.model) at \(model.modelSettings.url). Picking a model here switches to Ollama.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh") { Task { await model.refreshModels() } }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            Section("While Peter thinks") {
                Toggle("Play a sound (and the menu bar icon changes)", isOn: $model.busySound)
                Button("Hear it") { PeterModel.playBusy() }
            }
            Section("Peter") {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Text(updater.versionLine).foregroundStyle(.secondary)
                switch updater.state {
                case let .available(plan): Button("Update: \(plan.title)") { updater.install() }
                case let .installing(step): Text(step)
                case .checking: Text("Checking for updates…")
                case let .failed(why):
                    Text(why).foregroundStyle(.red)
                    Button("Check for updates") { updater.check(userInitiated: true) }
                case .upToDate:
                    Text("Up to date").foregroundStyle(.secondary)
                    Button("Check for updates") { updater.check(userInitiated: true) }
                case .idle: Button("Check for updates") { updater.check(userInitiated: true) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .task { await model.refreshModels() }
    }

    private func load() {
        toolMac = model.toolMacURL
    }
}

/// What Peter's model is given: the instructions (the same every time), and the latest request
/// it worked through: the message, each tool it called with what that gave back, and its answer.
struct PromptView: View {
    @EnvironmentObject var model: PeterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let m = model.modelSettings
                Text(m.on ? "Model: \(m.model == Brain.Settings.auto ? "automatic" + (model.pickedModel.map { " (\($0))" } ?? "") : m.model)" : "The model is off: Peter can't do anything without it.")
                    .font(.callout).foregroundStyle(.secondary)
                Block(title: "The system prompt (the same every request)", text: model.instructions)
                if let call = model.lastCall {
                    Block(title: "The latest message (\(call.at.formatted(date: .omitted, time: .shortened)), from \(call.client))", text: call.run.user)
                    if !call.run.steps.isEmpty {
                        Block(title: "The tools it called",
                              text: call.run.steps.map { "\($0.name) \(JSON.string($0.arguments))\n→ \($0.result.count > 600 ? String($0.result.prefix(600)) + "…" : $0.result)" }.joined(separator: "\n\n"))
                    }
                    Block(title: "What it answered" + (call.run.error.map { " (\($0))" } ?? ""),
                          text: call.run.answer.isEmpty ? "(nothing)" : call.run.answer)
                } else {
                    Text("It hasn't been asked yet. Every request goes to it, alone: the instructions, the client's message, and the tools it calls for it; nothing from the one before.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .task { await model.refresh() }
    }
}

/// A titled block of text, selectable, with a copy button.
struct Block: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
