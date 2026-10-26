# Peter: the API

Peter is how a client gets things done on this Mac: **say what you want in plain words, get
plain words back.** His model reads every request and carries it out with his tools: [Tool Mac
Tool Run](https://github.com/ainigh/tool-mac-tool-run)'s (scripts, flows, the web, Chrome,
showing and copying), [Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces)'
(notes, MEMORY, the mind, Super Face's notes), and his own (the schedule, what a client asked for,
who's let into Storage Spaces). A client never needs a route, a tool name, an argument, a
template, a request id, a poll or a line of JSON.

The client is often a model, and often a small one. Its instructions need one line:

> To get anything done on the Mac or the web, ask Peter in plain words, each message complete in itself.

```
Base URL   http://127.0.0.1:8770      (this Mac only)
```

How it fits with the others: [ARCHITECTURE.md](ARCHITECTURE.md). Why it's built this way:
[DECISIONS.md](DECISIONS.md).

## In one minute

```bash
# say what you want; who's talking is ?client= (or X-Client)
curl -s 'localhost:8770/api/say?client=My+App' -H 'Content-Type: text/plain' -d "is the Walmart Supercenter in Austin TX 78745 open now, and until when?"
# Yes: the one at 710 E Ben White Blvd is open until 11pm tonight (walmart.com).

# something missing: nothing is done, and he says how to ask
curl -s 'localhost:8770/api/say?client=My+App' -d "open the page in Chrome"
# Which page? Ask again with the address: open https://… in Chrome.        (X-Peter-Outcome: nothing)

# what he can do, without doing it
curl -s 'localhost:8770/api/say?client=My+App' -d "how would I ask you to show something on the person's screen?"

# told the moment it's over (and when something scheduled is due): an address on this Mac
curl -s 'localhost:8770/api/say?client=My+App' -H 'X-Reply-To: http://127.0.0.1:9000/news' -d "remind me in 20 minutes to stand up"
# Set for today at 15:40 (in 20 minutes): a reminder: stand up. Its number is 1. I'll tell you then.
```

## The exchange

| | |
|---|---|
| **Request** | `POST /api/say`, the words as the body (`Content-Type: text/plain`), or JSON `{"text": "…", "client": "…", "reply_to"?: "…"}` |
| **Who's talking** | `?client=`, the `X-Client` header, `"client"`, else the User-Agent. Each client's requests are its own. |
| **Answer** | `text/plain`, always `200`. A refusal or a failure is said in words. |
| **How it went** | The `X-Peter-Outcome` header, from what his tools did (never from his words): `done` (something was done or found), `asked` (a run waits for the person to click Run on the Mac; the client is told how it went), `nothing` (no tool did anything: he needs something, can't, or said how to ask), `error` (he couldn't work it through: his model out of reach, too many steps). Go by it, not by the wording: an answer that did the job may still say what it couldn't find. |
| **Told when it's over** | `X-Reply-To` (or `"reply_to"`): an `http` address on this Mac. The moment a run of this client's is over, or something it scheduled is due, it's POSTed there as `{"client", "text": "Meanwhile: …", "entries": [as /api/say/log has them]}`. What couldn't be delivered comes first in its next answer. |

Every reply has up to two parts:

1. **The news**: what changed in this client's runs since it last heard (*Meanwhile: The nightly
   backup finished (it worked).*), when it wasn't told already at its address.
2. **The answer**: what was done or found, in a few plain sentences, with the specifics (the
   address opened, the time set, what was found).

## No conversation

**Every message is whole in itself.** Peter's model sees his instructions, the one message (who
it's from, and the time), and the tool calls it makes for it. Nothing from before. So:

- Say the whole request, with every detail it needs: the actual address, the exact time, the full
  text to keep. "Yes", "the second one" or "more" mean nothing to him.
- To refine something, ask again, whole.
- When something's missing or unclear, he does nothing, and says what's missing and how to ask.
  When he can't, he says why, and what would work instead (`X-Peter-Outcome: nothing`). He doesn't
  add that he keeps no conversation: a client's own instructions should say so (Super Face's do).
- **"How would I ask you to …?"** is answered without doing anything: whether he can, and the
  exact words to ask with.

What *is* kept is operational, not conversation: the runs still going (to tell the client when
they're over), "what have I asked for" (each request numbered, the number never changing), and
the schedule. Requests are kept a week, at most 200 a client; the runs he's following and the
schedule outlast a restart (they're in his space in Storage Spaces too).

## What he can do

Whatever his tools reach. His model is given:

| Tools | From | What |
|---|---|---|
| `find`, `web_search`, `web_fetch`, `browser`, `run_script`, `run_flow`, `run_flow_code`, `check_flow`, `straw`, `runs`, `show`, `copy`, `docs`, `call_api` | Tool Mac Tool Run's `GET /api/tools`, as it is now (a tool it adds is there the day it ships; one switched off isn't) | the web, Chrome, the person's scripts and flows, showing and copying, any route no tool covers |
| `library`, `remember`, `recall`, `memory`, `mind` | the same, but done straight on Storage Spaces (and through Tool Mac Tool Run only while it's closed) | the person's notes, MEMORY and the mind |
| `space_notes` | Peter | the notes of the other spaces: Super Face's standing instructions (`super/prompt`, the note `instructions`) and playbook (`super/memory`, `playbook`), an app's own (`other/<app>`) |
| `schedule` | Peter | a reminder or a request for later, once or again and again; what's set; one taken off |
| `requests` | Peter | what this client asked for, how each went, what a run printed, stopping one |
| `access` | Peter | who's asking to get into Storage Spaces; a yes or a no (only from the person, in his window); letting an app in; taking it back |

**For later**: "remind me in 20 minutes to call Sam", "every weekday at 8am, search the web for the
traffic on I-35". A reminder is said back to the client when it's due; a request for later is done
then by his model, as if the client had just asked, and how it went said back. When is how a
person says it: `in 20 minutes`, `at 17:30`, `tomorrow 8am`, `Friday 9:00`, `3 November at noon`,
`2026-11-03 14:00`. Something due while Peter was closed is done as he opens, saying it's late
(over a day late, it's dropped; a repeating one goes on from its next time).

**While his model works**, Peter plays a sound of his own (macOS's *Morse*, softly) and his menu
bar icon changes; the sound can be turned off in his menu or window.

## His model

Kept in `model.json` in `~/Library/Application Support/Peter/` (or where `PETER_MODEL` says),
readable by its owner only (and in his space in Storage Spaces without the key); changed in his
window or with `POST /api/model`.

| Setting | Default | |
|---|---|---|
| `on` | `true` | without it, Peter can do nothing |
| `api` | `openai` | `openai`: any chat completions address (Ollama, LM Studio, llama.cpp, vLLM, OpenAI, OpenRouter…), with `tools`. `anthropic`: the Messages API. |
| `url` | `http://127.0.0.1:11434/v1/chat/completions` | Ollama on this Mac (asked on its own `/api/chat`, so its context can be set). With `api: anthropic`: `https://api.anthropic.com/v1/messages`. |
| `model` | `auto` | `auto`: the best model Ollama has that calls tools (qwen3, then qwen2.5, llama3.3, llama3.1, mistral-small, llama3.2…, else the first). With `api: anthropic`: `claude-opus-5-5`. |
| `key` | empty | a bearer token (`openai`) or `x-api-key` (`anthropic`); empty: none, or `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` for the provider's own address. Never shown back. |
| `timeout` | 120 | seconds, for each of the model's answers |
| `context` | 16384 | Ollama: how many tokens it reads (`num_ctx`) |
| `steps` | 8 | the most rounds of tool calls for one request |
| `effort` | `low` | `anthropic` only |

With a model elsewhere, what the client said, the instructions, the tools' descriptions and what
each tool gave back are sent there. With a model on this Mac (the default), nothing leaves it.

## Consent stays the person's

A run (a script, a flow, Flow code, Straw) is asked for on the Mac with a card that says which
app, why in its own words, and exactly what would run. Peter's answer only says it was asked for;
how it went comes as news. Nothing a client says, and nothing his model does, stands in for that
click, and that holds for what runs on the schedule too.

## Every route

| Route | |
|---|---|
| `POST /api/say` | say what you want (above) |
| `GET /api/say` | how to talk to Peter, as text |
| `GET /api/say/log` | what this client asked for, newest first: `{"entries": [{"number", "asked", "said", "template", "what", "state", "shown", "muted", "waits_for_the_mac", "request"?, "result"?, "ended"?}]}` (`template` is what kind it was: `said`, a run's tool, `reminder`, `later`) |
| `POST /api/say/stop` | one of this client's requests called off by its number (`{"number": 3}`), for an app's Cancel button |
| `POST /api/say/reset` | what this client asked for, forgotten |
| `GET /api/model` | his model: its settings (the key only as `"set"`), whether it's ready, its instructions, its tools, and its latest 20 requests, each with its tool calls and what they gave back |
| `POST /api/model` | its settings changed (any of the above) |
| `GET /api/schedules` | what's scheduled (`?client=`: one client's): `{"schedules": [{"number", "client", "kind", "text", "due", "repeat"?, "reply_to"?, "said"}]}` |
| `POST /api/schedules` | something scheduled without words: `{"kind": "remind" \| "later", "text", "when", "repeat"?, "client"?, "reply_to"?}` |
| `DELETE /api/schedules/{number}` | taken off |
| `GET /api/health` | `{"service": "peter", "version", "tool_mac_tool_run": {"url", "reachable", "tools", "scripts", "flows"}, "model": {"api", "model", "picked", "ready", "working"}, "scheduled", "storage_spaces": {"url", "ready", "key", "problem"?}}` |
| `GET /api` | these routes |

Gone, since his model does it all: `GET /api/say/forms` and `POST /api/say/translate` (`410`),
and `?exact=true` (ignored). `/api/say/translator` is `/api/model`.

States (as `/api/say/log` has them): `answered`, `done`, `failed`, `waiting` (for the OK on the
Mac), `running`, `worked`, `denied`, `not_answered`, `withdrawn`, `could_not_start`, `stopped`.

## For a client

1. Give the model the one line above, and pass what it says to Peter through to `POST /api/say`
   with `?client=<your app>`.
2. If your app can listen, send `X-Reply-To` once: news (a run over, something scheduled due)
   arrives the moment it happens, as a message from Peter.
3. That's all. No ids to keep, nothing to poll, no JSON to read, no conversation to carry.
