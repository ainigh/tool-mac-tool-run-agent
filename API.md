# Peter: the API

Peter is how a client gets things done on this Mac: **say what you want in words, get plain
words back.** He carries it out on [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run)
(scripts, flows, the web, Chrome, notes, MEMORY, the mind, showing and copying), and keeps a
schedule. A client that talks to Peter never needs a route, a tool name, an argument, a request
id, a poll or a line of JSON.

The client is often a model, and often a small one. Its instructions need one line:

> To get anything done on the Mac or the web, ask Peter in plain words. If he answers with templates, fill one in and say it back.

```
Base URL   http://127.0.0.1:8770      (this Mac only)
```

How it fits with the others: [ARCHITECTURE.md](ARCHITECTURE.md). Why it's built this way:
[the problem and the approach](docs/Talking%20to%20Tool%20Mac%20Tool%20Run%20-%20the%20problem%20and%20the%20approach.md).
Which model reads requests best: [BENCH.md](BENCH.md).

## In one minute

```bash
# say what you want; who's talking is ?client= (or X-Client)
curl -s 'localhost:8770/api/say?client=My+App' -H 'Content-Type: text/plain' -d "search the web for Walmart hours Austin TX"
# The web has these for "Walmart hours Austin TX":
# 1. …

# not one of his templates: his model reads it, and the answer says how it took it
curl -s 'localhost:8770/api/say?client=My+App' -H 'Content-Type: text/plain' -d "gonna need an umbrella in Lagos tomorrow?"
# Taken as: what's the weather in Lagos
#
# Asked for the weather. I'll tell you how it goes.

# told the moment it's over (and when something scheduled is due): an address on this Mac
curl -s 'localhost:8770/api/say?client=My+App' -H 'X-Reply-To: http://127.0.0.1:9000/news' -d "remind me in 20 minutes to stand up"
# Set for today at 15:40 (in 20 minutes): a reminder: stand up. Its number is 1. I'll tell you then.
```

## The exchange

| | |
|---|---|
| **Request** | `POST /api/say`, the words as the body (`Content-Type: text/plain`), or JSON `{"text": "…", "client": "…", "reply_to"?: "…"}` |
| **Who's talking** | `?client=`, the `X-Client` header, `"client"`, else the User-Agent. Each client's requests are its own. |
| **Exact** | `?exact=true` (or `X-Exact: true`, or `"exact": true`): only what fits a template is done, and his model is never asked (no reading of loose words, no second try after a failure). Quick, for a client reading its own notes. |
| **Answer** | `text/plain`, always `200`. A refusal or a failure is said in words. Never JSON, routes, file names or ids. |
| **Told when it's over** | `X-Reply-To` (or `"reply_to"`): an `http` address on this Mac. The moment a run of this client's is over, or something it scheduled is due, it's POSTed there as `{"client", "text": "Meanwhile: …", "entries": [as /api/say/log has them]}`. What couldn't be delivered comes first in its next answer. |

Every reply has up to three parts:

1. **The news**: what changed in this client's requests since it last heard (*Meanwhile: The
   nightly backup finished (it worked).*), when it wasn't told already at its address.
2. **The answer**: what was done or found, whole (an answer too long for anyone to read is cut
   at 12,000 characters, and says so). Lists are numbered.
3. **What you can say next**: one or two templates that usually follow.

## No conversation

**Every request is whole in itself.** Peter keeps nothing that changes how the next request is
read, and his model never sees anything but the request at hand. So:

- No "yes" or "no" waiting: when a match is unsure and would change something, nothing is done,
  and the answer says exactly what to say to do it (*Did you mean: Delete a note (shopping)?
  Nothing was done. To do it, say it like this: delete the note shopping*). Said back, it's sure.
- No "the second one" or "more": say the template you mean, filled in; every answer comes whole.
- What *is* kept is operational: the requests still going (to tell the client when they're over),
  "what have I asked for" (each request with a number that never changes: "show me number 3"),
  and the schedule. Requests are kept a week, at most 200 a client, the latest 100 clients, while
  Peter runs; the schedule is kept on disk.

## How what's said is read

```
said ─┬─ nothing at all ──────────────────────────────► "what can you do"
      ├─ the labeled shape (a title, "- label: value") ► that template ─┬─ all there ──► done (or, unsure and a change: what to say)
      │                                                                 ├─ some missing ► "That needs … too"
      │                                                                 └─ a bad choice ► the choices there are
      ├─ the inline shape (a sentence) ─┬─ one clear fit ─────────────► done
      │                                 ├─ two about as close ───────► the model, if it's sure
      │                                 │    (one of them changes)      else "Did you mean one of these? Say the one you mean"
      │                                 └─ only a loose fit, and it ─► the model, if it's sure
      │                                      changes something          else "Did you mean …? To do it, say …"
      ├─ a template's title alone ────────────────────► the template, to fill (or done: it takes nothing)
      └─ none of these ───────────────────────────────► the model: done if it's sure, offered if not
                                                         else the templates whose words fit, numbered
done ─┬─ it worked ─────────────────────────────────────► the answer, in words (a script writes it)
      └─ it failed ─────────────────────────────────────► the model: what would do it instead, tried once
                                                          ("Tried instead: …"), else the failure and why
```

What counts as close (`Sources/PeterCore/Say/SayMatch.swift`): a sentence, title or label must
match at least 0.72 to count; 0.90 is a clean match, done at once; a change that doesn't wait for
the Mac (delete a note) is done at once only at 0.97; a title alone at 0.85. Titles, fixed words,
labels and choices match fuzzily (case, punctuation, a misspelling, a small word missing); **values
are taken exactly as written**.

## Templates

A template is what Peter offers and what he takes back. Two shapes:

```
Search the web                                  Remember something
  search the web for {what to look for}         - category: [PEOPLE | ORGANIZATIONS | … | OTHERS]
                                                - about: {who or what it's about}
                                                - fact: {what to remember}
                                                - date (optional): {a day, like 2026-11-03, or 03-14 for every year}
```

`{…}` is a blank to fill, `[a | b | c]` exactly one of these, `(optional)` a line that may be
left out, `- label: value` one value a line (in any order), and a label followed by a fenced
block a value of several lines. `GET /api/say/forms` lists every template there is now (`?q=words`:
the ones that fit, best first; `?format=json`: each with its fields).

**Where they come from**: Tool Mac Tool Run says what it has (`GET /api/tools`, `GET /api/scripts`,
`GET /api/flows`, asked again every 15 seconds), and Peter makes his templates from that, so what
it adds is there the day it ships.

**About what was asked for** (always there):

| Template | Does |
|---|---|
| `what can you do` (`help`) | a few lines of what there is |
| `what happened to {something you asked for}` | how a request is going |
| `what have I asked for [today \| recently \| since {a time}]` | the requests, each with its number and how it went |
| `show me {something you asked for}` | what a request gave back, in full |
| `stop {something you asked for}` (`cancel …`) | taken back while it waits for the OK on the Mac; stopped while it runs |
| `I'm done with {something you asked for}` | no more news about it |

`{something you asked for}` is "the last one", a word from it ("the backup"), a time ("the one
around 3"), or its number ("number 3").

**The schedule's**:

| Template | Lines | Does |
|---|---|---|
| Remind me | `- when` `- repeat (optional): [every day \| every weekday \| every week \| every month \| every hour \| every 30 minutes]` `- message` | the message said back to the client when it's due |
| Do something later | `- when` `- repeat (optional)` `- what` | the request (in words, as it'd be said to Peter) done when it's due, and how it went said back |
| What's scheduled | `what's scheduled` | the client's, soonest first, each with its number |
| Cancel something scheduled | `cancel the schedule {its number, a word from it, or all}` | taken off |

Said in a sentence, it's read by its words, without the model: `remind me in 20 minutes to call
Sam`, `remind me at 5pm: the oven`, `remind me to stretch in an hour`, `every weekday at 8am, search
the web for the traffic`, `every morning: remind me to drink water`, `in 2 hours, run the nightly
backup`.

`when` is how a person says it: `in 20 minutes`, `in an hour`, `at 17:30`, `5:30 pm`, `tomorrow
8am`, `Friday 9:00`, `3 November at noon`, `2026-11-03 14:00`. A time of day alone is today, or
tomorrow once it has passed. Something due while Peter was closed is done as he opens, saying it's
late (over a day late, it's dropped; a repeating one goes on from its next time). A run Peter does
on schedule waits for Run on the Mac like any other.

**Tool Mac Tool Run's tools** (`SayForms.tools` in `Sources/PeterCore/Say/SayForms.swift`; a template is there only
while Tool Mac Tool Run has the tool, switched on; one it adds later, with none written here, gets a labeled template made from its arguments, titled "… (a tool)"):

| Template | Sentence or lines | Calls (tool → route) | Waits for the Mac |
|---|---|---|---|
| Search the web | `search the web for {what to look for}` · `look up {…} online` · `google {…}` | `web_search {q}` → `GET /api/web/search` | |
| Read a web page | `read the page at {a web address}` · `read {a web address}` | `web_fetch {url}` → `GET /api/web/fetch` | |
| Find words on a web page | `- address` `- words` | `web_fetch {url, find}` | |
| Open a page in Chrome | `open {a web address} in Chrome` · `go to {…}` · `open {…} side by side` | `browser {op: open}` (a window of the client's own, side by side) | |
| Open a page on my screen | `open {a web address} on my screen` | `browser {op: open, where: on_screen}` | |
| Open a page in the background | `open {a web address} in the background` | `browser {op: open, where: background}` | |
| Read the page in Chrome | `read the page in Chrome` · `what's on the page` | `browser {op: page}` | |
| Read my page | `read the page in front of me` · `what am I looking at` | `browser {op: page, where: on_screen}` | |
| Find something on the page | `where is {words on the page} on the page` | `browser {op: find}` | |
| Find something on my page | `where is {words on the page} on my page` | `browser {op: find, where: on_screen}` | |
| Point something out on the page | `point to {words on the page} on the page` · `highlight {…}` | `browser {op: highlight}` | |
| Point something out on my page | `point to {words on the page} on my page` | `browser {op: highlight, where: on_screen}` | |
| Work side by side | `work side by side with me` | `browser {op: place, where: side_by_side}` | |
| Put my browser back | `put my browser back` · `close your browser window` | `browser {op: done}` | |
| The tabs in Chrome | `what tabs are open` | `browser {op: tabs}` | |
| Do steps in Chrome | `- steps` (Straw lines) | `straw {source}` → `POST /api/straw/run` | yes |
| Remember something | `- category` `- about` `- fact` `- date (optional)` | `remember` → `POST /api/memory/remember` | |
| Recall something | `what do you know about {a name}` · `who is {a name}` | `recall {name}` | |
| What's coming up | `what's coming up [this week \| this month \| today \| in the next {a number of} days]` | `memory {op: upcoming, days}` | |
| What's filed under a kind | `what's filed under {a kind, like PEOPLE}` | `memory {op: members}` | |
| Link two things | `- from` `- link` `- to` | `mind {op: add}` | |
| How two things connect | `- from` `- to` | `mind {op: path}` | |
| Add a note to something | `- about` `- note` | `mind {op: note}` | |
| Read a note | `read the note {its name}` | `library {op: read}` | |
| Write a note | `- name` `- text` (several lines) | `library {op: write}` | |
| Add to a note | `- name` `- text` (several lines) | `library {op: append}` | |
| Find a note | `find the note about {a few words}` | `library {op: find}` | |
| Search my notes | `search my notes for {words}` | `library {op: search}` | |
| My notes | `what notes do I have` | `library {op: recent}` | |
| Rename a note | `- name` `- new name` | `library {op: rename}` | |
| Delete a note | `delete the note {its name}` | `library {op: delete}` (to the library's Trash) | |
| Bring a note back | `bring back the note {its name}` | `library {op: restore}` | |
| Show the person something | `- title` `- text` (Markdown) | `show` → `POST /api/present` | |
| Copy something | `- text` | `copy` → `POST /api/clipboard` | |
| Read a guide | `read the guide {its name}` | `docs {op: read}` | |
| Search the guides | `search the guides for {words}` | `docs {op: search}` | |
| The guides | `what guides are there` | `docs {op: list}` | |
| The latest runs | `what has run lately` · `what's running` | `runs {op: list}` | |
| Run Flow code | `- code` (several lines) | `run_flow_code` → `POST /api/compose` | yes |
| Check Flow code | `- code` (several lines) | `check_flow` → `POST /api/check` | |
| Run something by itself | `- what` `- when: [every morning \| …]` | `POST /api/automation` (Allow on the Mac) | yes |

**The folder's own**: every script and flow in the person's folder is a template, made from its
header, so nobody writes one by hand:

| The header says | The template |
|---|---|
| `# Say: what's the weather in {a city}` | that sentence (each `{…}` is one of its `# Input:` lines, in order); more `# Say:` lines are more ways to say it |
| nothing to say, no inputs | `run the {its name}` (`nightly-backup.sh` → `run the nightly backup`) |
| one input | `{its name}: {the input}` (`weather: {a place}`) |
| two inputs or more | labeled: a line for each `# Input:`, its `# Why:` in the blank |

Its title is its file name in words (`nightly-backup` → `Nightly backup`; a flow of the same name
is `Translate (a flow)`). It's asked for on the Mac: the person there sees the card, which says
which app asked and why, in its own words (*Peter asked: Super Face asked in words: “run the
nightly backup”*).

## Peter's model

Peter's own matching is exact about what a template is and forgiving about how it's typed. It
can't know that *"gonna need an umbrella in Lagos?"* means the weather. That's his model's job:
**reading what was said into the templates**, asked only when the words alone don't settle it,
and **looking at a failure**, to say what would do it instead.

It's **stateless**: each call is what was said, why it's asked (nothing matched; two fit about as
well; one fit only loosely; it was done as *this* and failed with *that*), and the templates there
are, the closest first. It sees no conversation, no history, no log, no results, no other client.
It never answers the request and never does anything: it says which templates it thinks were
meant, filled in, and how sure it is. What it fills in is read back through Peter's own matcher,
so nothing reaches Tool Mac Tool Run that isn't one of his templates with values it can take.

| The best reading is | Done |
|---|---|
| filled, and at least `sure` (0.75) | done at once, the reply starting `Taken as: <the template, filled>` (a run is asked for on the Mac, the card saying the client's own words) |
| not sure, or not filled | offered, numbered, filled in as far as it could be, with its question: nothing done |
| for a failure: another template, or other values | done once, the reply saying the failure, then `Tried instead: …`, then how that went |
| nothing usable (off, out of reach, not JSON) | as without it |

*Taken as* is the point: the client sees the template its words became, and says it that way next
time, without the model.

**While it works**, Peter plays a sound of his own (macOS's *Morse*, softly, every second and a
half) and his menu bar icon changes; the sound can be turned off in his menu or window.

### Settings

Kept in `model.json` in `~/Library/Application Support/Peter/` (or where `PETER_MODEL` says),
readable by its owner only; changed in Peter's window or with `POST /api/say/translator`.

| Setting | Default | |
|---|---|---|
| `on` | `true` | asked at all |
| `api` | `openai` | `openai`: any chat completions address (Ollama, LM Studio, llama.cpp, vLLM, OpenAI, OpenRouter…). `anthropic`: the Messages API. |
| `url` | `http://127.0.0.1:11434/v1/chat/completions` | Ollama on this Mac. With `api: anthropic`: `https://api.anthropic.com/v1/messages`. |
| `model` | `auto` | `auto`: the best model Ollama has (qwen3, then qwen2.5, llama3.3, llama3.1, gemma3, llama3.2…, else the first). With `api: anthropic`: `claude-opus-5-5`. |
| `key` | empty | a bearer token (`openai`) or `x-api-key` (`anthropic`); empty: none, or `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` for the provider's own address. Never shown back. |
| `timeout` | 20 | seconds |
| `sure` | 0.75 | how sure it must be to be acted on |
| `format` | `json_object` | `openai` only: `json_object`, `json_schema`, or `none` |
| `effort` | `low` | `anthropic` only |

With a model elsewhere, what the client said and the templates' titles and wording (which include
the names of the scripts and flows in the folder) are sent there; for a failure, its message too.
Nothing else. With a model on this Mac (the default), nothing leaves it. A local model needs a
context of at least 8,192 tokens (for Ollama, `OLLAMA_CONTEXT_LENGTH=16384`).

## Consent stays the person's

A run (a script, a flow, Flow code, Straw) is asked for on the Mac with a card that says which
app, why in its own words, and exactly what would run. Peter's reply only says it was asked for;
how it went comes as news. Nothing a client says, and nothing his model reads, stands in for that
click, and that holds for what runs on the schedule too.

## Every route

| Route | |
|---|---|
| `POST /api/say` | say what you want (above) |
| `GET /api/say` | how to talk to Peter, as text |
| `GET /api/say/forms` | every template there is now (`?q=words`, `?format=json`) |
| `GET /api/say/log` | what this client asked for, newest first: `{"entries": [{"number", "asked", "said", "template", "what", "state", "shown", "muted", "waits_for_the_mac", "request"?, "result"?, "ended"?}]}` |
| `POST /api/say/stop` | one of this client's requests called off by its number (`{"number": 3}`), for an app's Cancel button |
| `POST /api/say/reset` | what this client asked for, forgotten |
| `POST /api/say/translate` | the model alone, stateless: `{"text", "why"?, "between"?, "dry"?, and any setting to try}` → the prompt, what it answered, which templates came of it |
| `GET /api/say/translator` | the model's settings (the key only as `"set"`), whether it's ready, its latest 20 calls |
| `POST /api/say/translator` | its settings changed (any of the above) |
| `GET /api/schedules` | what's scheduled (`?client=`: one client's): `{"schedules": [{"number", "client", "kind", "text", "due", "repeat"?, "reply_to"?, "said"}]}` |
| `POST /api/schedules` | something scheduled without words: `{"kind": "remind" \| "later", "text", "when", "repeat"?, "client"?, "reply_to"?}` |
| `DELETE /api/schedules/{number}` | taken off |
| `GET /api/health` | `{"service": "peter", "version", "tool_mac_tool_run": {"url", "reachable", "tools", "scripts", "flows"}, "model": {"api", "model", "ready", "working"}, "scheduled"}` |
| `GET /api` | these routes |

States (as `/api/say/log` has them): `answered`, `done`, `failed`, `waiting` (for the OK on the
Mac), `running`, `worked`, `denied`, `not_answered`, `withdrawn`, `could_not_start`, `stopped`.

## For a client

1. Give the model the one line above, and pass what it says to Peter through to `POST /api/say`
   with `?client=<your app>`.
2. If your app can listen, send `X-Reply-To` once: news (a run over, something scheduled due)
   arrives the moment it happens, as a message from Peter.
3. That's all. No ids to keep, nothing to poll, no JSON to read, no conversation to carry.
