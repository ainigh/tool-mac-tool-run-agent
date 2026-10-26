# Peter (Tool Mac Agent)

Peter gets things done on your Mac when asked in plain words. Any app (or you) tells him what
it wants; his model works it out and carries it out with his tools (on
[Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run), on
[Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces), and his own), and
answers in plain words. He also keeps a schedule: reminders, and requests to do later or every
day, said back to whoever asked when they're due.

He's a small app in the menu bar (a person waving), with an HTTP API on `127.0.0.1:8770`:
[API.md](API.md). [Super Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service) talks
to him: its model writes `@peter …` and Peter answers. How the apps fit:
[ARCHITECTURE.md](ARCHITECTURE.md); what was decided, and why: [DECISIONS.md](DECISIONS.md).

- **He does the translating.** No templates, nothing to fill in, no format to learn: his model
  reads every request, calls whatever tools it needs (Tool Mac Tool Run's, as it lists them now,
  and his own), and says how it went. When something's missing he does nothing and says how to
  ask ("Ask again with the address: open https://… in Chrome"); "how would I ask you to …?" is
  answered without doing anything.
- **No conversation.** Every message is whole in itself: his model sees the one message and its
  own tool calls for it, never a history. What he keeps is only what's still going (a run waiting
  for your click, or running) so he can tell the asker the moment it's over, and the schedule.
- **A sound while he thinks.** Whenever his model is working, a soft *Morse* sound plays (and his
  menu bar icon changes). Turn it off in his menu.
- **The schedule.** "Remind me in 20 minutes to stand up", "every weekday at 8, search the web for
  the traffic on I-35". When it's due he calls the asker back (or tells it first thing in its next
  answer). Kept on disk and in his space in Storage Spaces, so it survives a restart.
- **Storage Spaces.** What he needs to work is kept in his own space of
  [Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces) (PETER: his
  schedule, his model's settings without any key, the runs he's following, how things stand), and
  the person's notes, MEMORY and the mind come straight from there ("read the note groceries",
  "remember…", "what do you know about Ada"), even with Tool Mac Tool Run closed; so do Super
  Face's own notes, which he writes when it asks ("add to Super Face's instructions: …"). He's
  the one who lets other apps in: "who's asking for access", and, in his window only, "allow
  request 3", "let Super Face read my memory"; "stop letting Super Voice in" takes it back.
- **His window.** Click the icon › **Talk to Peter…**: type, or click the microphone and speak
  (macOS's own speech recognition). It stays in front of every other window (and on every
  desktop) until you click **Hide Peter's Window** in the same menu. Each message goes to him on
  its own, as an API call would, and nothing in the window is kept once it's hidden. Its tabs:
  **Talk**, **Scheduled** (with a way to take each off), **Prompt** (the system prompt his model is
  given, the latest message it worked through, each tool it called and what it answered, each with
  a copy button), and **Settings**: where Tool Mac Tool Run is, his model (picked from the models
  Ollama has, or Automatic: the best of them), the sound.
- **Consent stays yours.** A script or flow still waits for you to click Run on the Mac, every
  time, whoever asked and whenever.

## Install

Needs [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run) (with its API on) and a
model: [Ollama](https://ollama.com) with one pulled (`brew install ollama`, then `ollama pull
qwen3:8b`; he picks the best one you have, or the one you pick in his window). Without a model he
can't do anything: it reads every request. With
[Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces) open, he keeps his
things there too, and reads and writes your notes and MEMORY straight from it.

Paste this in Terminal (it installs Homebrew's `gh` if needed and signs you in to GitHub, since
the repository may be private):

```bash
/bin/bash -c 'for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done; command -v gh >/dev/null || brew install gh; gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https -h github.com; gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run-agent/contents/install.sh | bash'
```

It takes the latest release GitHub built (or builds it on your Mac if there's none yet: that
needs Apple's command line tools), installs `~/Applications/Peter.app`, and opens it. He adds
himself to your login items the first time (**Open at Login** in his menu turns that off).
Needs macOS 14 or newer.

**Updates**: he checks at launch and every six hours; when there's a new version, his menu (and a
notification) says so, and **Update** installs it and restarts him (if the new one won't open, the
one you had comes back). Running the install line again works too. What an update did is in
`~/Library/Logs/Peter/update.log`.

His settings and schedule are in `~/Library/Application Support/Peter/` (and in Storage Spaces'
PETER space: whichever is newer is taken as he opens), with the key he claims his name in
Storage Spaces with (`storage-key`).

## Try it

```bash
curl -s 'localhost:8770/api/say?client=Me' -d 'search the web for the louvre opening hours'
curl -s 'localhost:8770/api/say?client=Me' -d 'remind me in 2 minutes to look away from the screen'
curl -s 'localhost:8770/api/say?client=Me' -d "what's scheduled"
curl -s localhost:8770/api/health
```

## Working on it

```bash
swift test                 # PeterCore, on any machine (Linux too)
swift run Peter            # the app, on a Mac
scripts/build-app.sh       # build/Peter.app and build/Peter.zip
```

| | |
|---|---|
| `Sources/PeterCore/Peter.swift` | the HTTP API, the news, his own tools (the schedule, what was asked for, access) |
| `Sources/PeterCore/Agent.swift` | one request: his model's instructions, its tools, each call done |
| `Sources/PeterCore/Brain.swift` | his model: Ollama, any chat completions address, or Anthropic, with tools |
| `Sources/PeterCore/Say/` | what each client asked for (the log), the words he says without his model |
| `Sources/PeterCore/Storage.swift` | Storage Spaces over HTTP: his space, the person's notes, Super Face's, access |
| `Sources/PeterCore/ToolMac.swift` | Tool Mac Tool Run over HTTP: what it has, a tool called, a request followed |
| `Sources/PeterCore/Schedule.swift`, `When.swift` | the schedule, and how a time is said |
| `Sources/Peter/` | the menu bar app: its menu, his window (talk, dictation, the schedule, settings), the sound, the server, the updater |

Every push is tested on Linux and built on macOS by GitHub Actions; a push to `main` is
published as a release, which is what the install line and the updater take.
