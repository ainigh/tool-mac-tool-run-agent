# Peter (Tool Mac Agent)

Peter gets things done on your Mac when asked in plain words. Any app (or you) tells him what
it wants; he works out what that means, carries it out on
[Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run), and answers in plain words. He
also keeps a schedule: reminders, and requests to do later or every day, said back to whoever
asked when they're due.

He's a small app in the menu bar (a person waving), with an HTTP API on `127.0.0.1:8770`:
[API.md](API.md). [Super Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service) talks
to him: its model writes `@peter …` and Peter answers. How the three apps fit:
[ARCHITECTURE.md](ARCHITECTURE.md).

- **Specialised in reading requests.** What's said is matched against his templates (one or more
  for each of Tool Mac Tool Run's tools, scripts and flows, made from what it says it has). When
  the words alone don't settle it, his model reads them into a template; the answer says how he
  took it ("Taken as: what's the weather in Lagos"), so the asker learns the wording.
- **No conversation.** Every request is whole in itself: his model sees what was just said and
  the templates, never a history. What he keeps is only what's still going (a run waiting for
  your click, or running) so he can tell the asker the moment it's over, and the schedule.
- **Answers by script, failures by model.** What Tool Mac Tool Run answers is put into words by a
  script. When something fails, his model looks at why and, if another way would do it, he tries
  that once ("Tried instead: …").
- **A sound while he thinks.** Whenever his model is working, a soft *Morse* sound plays (and his
  menu bar icon changes). Turn it off in his menu.
- **The schedule.** "Remind me in 20 minutes to stand up", "every weekday at 8, search the web for
  the traffic on I-35". When it's due he calls the asker back (or tells it first thing in its next
  answer). Kept on disk and in his space in Storage Spaces, so it survives a restart.
- **Storage Spaces.** What he needs to work is kept in his own space of
  [Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces) (PETER: his
  schedule, his model's settings without any key, the runs he's following, how things stand), and
  the person's notes, MEMORY and the mind come straight from there ("read the note groceries",
  "remember…", "what do you know about Ada"), even with Tool Mac Tool Run closed. He's the one who
  lets other apps in: "who's asking for access", and, in his window only, "allow request 3", "let
  Super Face read my memory"; "stop letting Super Voice in" takes it back.
- **His window.** Click the icon › **Talk to Peter…**: type, or click the microphone and speak
  (macOS's own speech recognition). It stays in front of every other window (and on every
  desktop) until you click **Hide Peter's Window** in the same menu. Each message goes to him on
  its own, as an API call would, and nothing in the window is kept once it's hidden. Its tabs:
  **Talk**, **Scheduled** (with a way to take each off), **Prompt** (the system prompt his model is
  given, the latest message it was sent and what it answered, each with a copy button), and
  **Settings**: where Tool Mac Tool Run is, his model (picked from the models Ollama has, or
  Automatic: the best of them), how sure it must be, the sound.
- **Consent stays yours.** A script or flow still waits for you to click Run on the Mac, every
  time, whoever asked and whenever.

## Install

Needs [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run) (with its API on) and a
model: [Ollama](https://ollama.com) with one pulled (`brew install ollama`, then `ollama pull
qwen3:8b`; he picks the best one you have, or the one you pick in his window). Without a model he
still does whatever fits one of his templates. With
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
scripts/bench.py -m qwen3:8b -m llama3.2   # which model reads requests best (BENCH.md)
node scripts/simulate/prompts.mjs peter    # a dry run of the chat with Super Face, no app running
                                           # (docs/Simulated exchange - Super Face and Peter.md)
```

| | |
|---|---|
| `Sources/PeterCore/Peter.swift` | reading a request, doing it, the news, the schedule's templates, the HTTP API |
| `Sources/PeterCore/Say/` | the templates' grammar, the matcher, the templates, the words, the log, the model (moved from Tool Mac Tool Run) |
| `Sources/PeterCore/ToolMac.swift` | Tool Mac Tool Run over HTTP: what it has, a tool called, a request followed |
| `Sources/PeterCore/Schedule.swift`, `When.swift` | the schedule, and how a time is said |
| `Sources/Peter/` | the menu bar app: its menu, his window (talk, dictation, the schedule, settings), the sound, the server, the updater |

Every push is tested on Linux and built on macOS by GitHub Actions; a push to `main` is
published as a release, which is what the install line and the updater take.
