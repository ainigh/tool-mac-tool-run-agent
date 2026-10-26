# Decisions: Peter does the translating, Super Face does the thinking

What was decided (October 2026) about how Super Face and Peter talk, and why. The code follows
it: [API.md](API.md) is how to talk to Peter now, [ARCHITECTURE.md](ARCHITECTURE.md) how the apps
fit.

## The problem

Super Face's model and Peter's model were both doing translation work. Super Face's prompt taught
its model Peter's templates (blanks to fill, choices, titles and lines, "Taken as", the reminder
syntax), and Peter's model filled templates from a list of every one there is (about 7,000 tokens,
growing with the person's scripts). Super Face's prompt was ~1,800 tokens, most of it about how to
talk to Peter; Peter answered with templates a client had to copy and fill.

## The split

| | Knows | Lacks | Its job |
|---|---|---|---|
| **Super Face** | the user, the conversation, what "done" means for them | hands | understands, decides, directs, tells the user |
| **Peter** | how to get anything done on the Mac and the web | context | does what he's asked, says how it went |

The whole translation job is Peter's. Super Face just asks someone to do something, in plain
words; if Peter says he can't, it tells the user, or asks another way.

## The decisions

1. **Every call goes through Peter's model.** No templates, no matcher, no `?exact=true` fast
   path. A client that had to come up with a format would struggle and need docs; it always just
   asks. Peter's model reads the request and calls his tools: Tool Mac Tool Run's (as
   `GET /api/tools` lists them, so a new one is there the day it ships), and his own (the
   schedule, what a client asked for, access, and the notes in Storage Spaces' other spaces). It
   can use any of Tool Mac Tool Run's API (`call_api`), not only `say`.

2. **Peter remembers nothing between messages.** Each message is complete and atomic. A client
   that wants to refine something asks again, whole. Peter's model sees the instructions, the one
   message and its own tool calls for it; nothing else. The client's own instructions say so
   (Super Face's system prompt does). His answers used to end with *I don't keep our conversation:
   send the whole request again* when he needed something, but his model added it after jobs done
   too, and Super Face took it for failure (the dry runs, runs A and B): it's gone. How a request
   went is the `X-Peter-Outcome` header, from what his tools did: done, asked, nothing or error.

3. **Peter's jobs aren't conversation.** What he started and is still following (a run waiting for
   Run on the Mac, or running) and the schedule are kept, so he can say how they went and do
   what's due. They live in his space in Storage Spaces (PETER/FOLLOWING, PETER/SCHEDULE), and
   outlast a restart.

4. **"How would I ask you to …?" is the question that does nothing.** "Can you open Chrome?"
   usually means *do it*, so Peter doesn't guess: that phrase, and only it, gets whether he can and
   the exact words to ask with. Anything else he does. A client rarely needs to ask first: when
   something's missing, Peter's answer already says how to ask ("Ask again with the address: open
   https://… in Chrome"). That's how Super Face's model learns how to ask him.

5. **Peter owns storage; Super Face asks clearly.** Everything learned (the user's standing
   instructions, the playbook, what's known about the user) is written by Peter, when Super Face
   asks him to keep it, word for word. Super Face reads its own two notes (SUPER/PROMPT
   `instructions`, SUPER/MEMORY `playbook`) straight from Storage Spaces, without a model, as
   Storage Spaces' ARCHITECTURE.md planned; what it knows of the user it asks Peter for when it
   needs it.

6. **Super Face's model is a helpful assistant.** No persona (a concierge or JARVIS was
   considered, and dropped: it would pin the model down when it's helping solve a technical
   problem and only needs Peter for the doing). Its prompt is a small illustrative example, then
   a brief explanation: about 1,650 characters instead of 7,150. It answers from what it knows when
   that's enough; anything to do or find out, it asks Peter, and tells the user only what he
   reports.

7. **Correctness first, speed later.** Every request costs Peter's model a few turns, and that's
   slow. The point now is to prove it's right; speed (a fast path for exact requests, a smaller
   model for simple ones, caching) comes after, measured.

8. **The bench goes.** It scored filling templates, which nothing does any more.

## How Peter's model is asked

- Ollama is asked on its own `/api/chat` (not its OpenAI-style address), so its context can be set:
  16,384 tokens by default (`context`), since its own default is smaller than the instructions and
  the tools, and it cuts without saying so.
- Any OpenAI-style chat completions address, with `tools`; or Anthropic's Messages API, with
  `tools` (its content blocks go back exactly as they came, and on Anthropic's own API a request
  its safeguards decline goes to another model: `fallbacks: "default"`).
- At most 8 rounds of tool calls for one request (`steps`); a tool's answer is cut at 8,000
  characters; a small model that writes its call as words (`<tool_call>{…}</tool_call>`) still
  gets it made.
- His model's instructions: [`Peter.instructions`](Sources/PeterCore/Agent.swift), shown in his
  window's Prompt tab and in `GET /api/model`.

## Later

- Peter learns: what worked for which request (his own playbook), so his model reads less and
  guesses less.
- Speed, measured: the fast path back for requests that need no reading, if it earns its place.
- A new bench: whether a request got done, not whether a template was filled.
