# Simulated exchange: Super Face and Peter

Dry runs of the chat of three (the user, Super Face's model, and Peter), with no app running and
nothing called. One stand-in plays Super Face's model, given its real system prompt; another plays
Peter's model, given his real instructions and tools; the harness between them is Super Face's own
code. The point is to see whether the orchestration flows, and where it has blind spots.

There have been three runs of the same six scenarios:

- **Run 1** (25 October), on the template design: Peter matched requests to templates, and Super
  Face's prompt taught its model how to talk to him. [Run 1, below](#run-1-before-the-rewrite-templates).
- **Runs A and B** (26 October), twice, on the rewrite ([DECISIONS.md](../DECISIONS.md)): Peter's model
  does every request with his tools, and Super Face has a short prompt. Two runs, to tell what the
  design does from what one model happened to do. **Their results are first.** Transcripts:
  [Simulated exchange - runs A and B.md](Simulated%20exchange%20-%20runs%20A%20and%20B.md).

## Runs A and B: after the rewrite

### In short

The rewrite fixed what run 1 found worst. Nothing asked for was dropped: Peter's model takes a
whole request, with its "and tell me…", and does all of it. The model no longer needs to know what
Peter has: "back up my documents" found the nightly backup script in both runs, through Peter's
`find`. Every scenario ended with the user getting what they asked for, or knowing exactly what
was waiting on them.

What's left is mostly at the seam between the two: Super Face still decides whether Peter did
something from his wording, and Peter's new closing line makes that guess wrong most of the time.
That one thing caused most of what went wrong: false "Peter didn't do that" notes, a resent
WhatsApp message that could have gone out twice, and runs Super Face doesn't follow.

### Scenario by scenario

| | Run 1 (templates) | Run A | Run B |
|---|---|---|---|
| S1 Walmart: open? till when tomorrow? show me | 2 failed messages, saved by Peter's mend; "tell me" dropped | ✅ 1 message: Peter found "near me" in MEMORY, searched, read, opened the page | ✅ same |
| S1 "from now on, walmart → yes/no" | Saved, but worded so every use fails once | ✅ saved word for word; one extra check ("was anything lost?") | ✅ saved word for word |
| S1 "walmart", two days later | "No.", after a failed call and a mend | ✅ "No." (after "Let me check.") | ✅ "No." (after "Let me check whether it's open.") |
| S2 umbrella in Lagos | ✅ | ✅, but a false "didn't do that" note | ✅, but two false notes and an extra round for hourly rain |
| S2 back up my documents | ❌ never found the script (4 messages, nothing done) | ✅ found and asked for `nightly-backup.sh`; news came, told the user | ✅ found it; Peter warned it keeps only 7 days (may delete older backups); the model asked the user first |
| S3 reminder in 20 min, then 30 | New reminder silently dropped; caught by the model | ✅ Peter cancelled 3 and set 4 at 21:52 | ✅ same |
| S4 "grocery list" (note is "groceries") | Failed, mended; a false "didn't work" note; said twice | ✅ 1 message, 1 answer | ✅ same |
| S5 text my wife | Asked who; sent with Do steps in Chrome | ✅ "how would I ask you…?", asked the user, straw asked for, sent | ⚠️ asked the user; then a false "didn't do that" note made the model resend; Peter's model caught the duplicate |
| S6 flights next Friday | 5 messages, looping; date never asked | ⚠️ date assumed; Peter started a Chrome search (straw) unasked; news came with one-way fares | ✅ asked "this Friday or next?" first; Peter's `show` window, then a straw on the second ask; news came |

Messages to Peter: run 1, 24 for the six; run A, 13; run B, 15. Requests where something asked for
was silently dropped: run 1, 3; runs A and B, none.

### Findings

#### 1. Peter's "send the whole request again" makes Super Face think he failed (high)

Peter's instructions say: when he asks for something or can't do it, end with *"I don't keep our
conversation: send the whole request again."* His model also added it when it had done the job
(the umbrella, with "I couldn't find the hours"), and when it had started a run ("Asked for a
Straw run… I don't keep our conversation: send the whole request again"). Super Face's `troubled()`
counts that line as a failure. In the two runs, 9 "Peter didn't do that" notes were added; 2 were
right (both times Peter needed the wife's name).

What it caused:

- **A resend that could have sent the text twice** (B, S5). Peter's model had asked for the
  WhatsApp message (a Run card on the Mac). The note told the model he hadn't done it, so it asked
  again. Peter's model checked `requests`, saw run 14 waiting, and didn't put up a second card. A
  less careful model would have, and two clicks on Run would have sent it twice.
- **Runs Super Face doesn't follow.** `ask()` follows a run only when `!failed && /\bAsked for\b/`.
  Flagged as failed, the WhatsApp runs (A, B) and the flight searches (A, B) weren't followed: no
  "It's waiting for you to click Run" after 20 seconds, no Cancel on the message, no state in the
  chat. (The backup runs were followed: their answers didn't have the line.) The regex is also
  case-sensitive: "I've asked for a Google Flights one-way search" (A, S6) wouldn't match even
  without the line.
- **The model was confused** each time ("his reply did answer the umbrella question, so it's unclear
  whether that counts as a failure"), and in B (S2) made an extra round for hourly rain that
  nobody needed.

To close it: Peter says how a request went in a header (`X-Peter-Outcome: done | asked | needs |
cannot | failed`) and Super Face reads that, not the words; or, at the least, Peter's code (not his
model) adds the closing line only when no tool did anything, and `troubled()` and "Asked for" read
the outcome. Run 1's finding 4, still open in a new form.

#### 2. Super Face's fold cuts its own notes (medium)

At the start of each request, `fold()` cuts Peter's earlier answers to 600 characters. Super Face's
notes (the review note, "only your first message…") are added to the end of Peter's answer, so
they're folded with it: "…if only the use… (cut short)", or gone entirely after a long answer (A
and B, S6). Five stand-ins said they couldn't tell what the note had asked. Fold Peter's words
only, and keep (or drop) the note whole: better, push the note as its own message.

#### 3. Peter's model does more than it's asked (medium)

- A, S6: asked for flights, it found only round trips and **started a straw run on its own** (a
  Google Flights one-way search in Chrome), as the brief allows ("tell them what to do, or use
  straw"). The Run click still guards it, but the user didn't ask for Chrome to be driven.
- B, S6: it opened a `show` window in front of the user, unasked.
- B, S5: asked to text "that the user is running about 15 minutes late", it typed *"Hi Ngozi, I'm
  running about 15 minutes late."* Its own words in someone else's message.
- Instructions for his model: do what's asked; anything that drives Chrome, shows a window or
  writes in someone's name, only when asked for; a message to send is sent word for word.

#### 4. What's stored word for word can lack what it needs (medium)

The standing instruction went in exactly as said: "from now on whenever I say walmart just tell me
yes if they're open and no if they're closed". Both runs then answered "No." correctly, but only
because Sunday's exchange was still in the chat: the model knew which store from it. After a new
chat, or once it's out of the 40 messages kept, "which Walmart" is gone (Peter's model would find
one again from where the user lives, but not necessarily that one). The prompt says "word for
word" with good reason (no reinterpretation); it could add: "with what it refers to, when the
words alone don't say (which store, which person)". Run 1 had the opposite problem: the model
wrote its own instruction, and wrote it badly.

#### 5. Still telling the user before Peter answers (low now)

"Okay, I'll start backing up your documents now." (A, S2; corrected later: "Correction: the backup
hasn't started yet"); "From now on, when you say Walmart, I'll tell you…" (A and B, before the save);
"so it goes off at 9:52" (B, S3). Fewer than run 1, and none wrong in the end, but the words before
`@peter` are still spoken at once. The prompt's own example still has the model say "Sure, I'll
remind you at 15:40" only after Peter answers, which is the right shape; it could say so in words.

#### 6. Tool names leak into Peter's answers (low)

"I can, with straw", "ask again with: use straw to fill in the Google Flights search…". His
instructions say no tool names. In B (S6) the model called that suggestion "garbled" and didn't
pass it on; the one way to the one-way fares was lost until Peter's model started the run itself
the second time.

#### 7. Small things

- **"Let me check." before a one-word answer** (S1, both): the standing instruction said just yes
  or no. The busy tone would cover the wait.
- **"Tomorrow" across time zones** (B, S2): at 21:40 in Austin it's already Monday in Lagos; the model
  asked Peter for both days. Harmless.
- **An unneeded check** (A, S1): "it is now the only line in that note" made the model ask Peter
  whether anything was lost.
- **Peter's answers are long** (often over 600 characters), so they're folded in later requests;
  his instructions say one to three sentences.
- **The prompt's example uses "You:" labels**, and three stand-ins asked whether to write them; none
  did.

### Run 1's findings, now

| Run 1 finding | Now |
|---|---|
| 1. Several requests in one message, Peter does only the first | **Fixed** by the rewrite: Peter's model does all of it |
| 2. The model doesn't know what Peter has | **Fixed**: Peter's model uses `find`; "how would I ask you…?" works (A, S5) |
| 3. Says it's done before Peter does it | **Better**, still there (finding 5) |
| 4. `troubled()` misjudges | **Still open, worse** (finding 1) |
| 5. Learning narrow, plain sentences, stale notes | **Changed**: the reflect step is gone; instructions go word for word (finding 4) |
| 6. Doesn't know when to stop, or ask first | **Better**: B asked which Friday; A still assumed |
| 7. Run card may show only the title | **Better**: the card's reason is the first line of Super Face's request, in words ("Super Face asked in words: “Text Ngozi, the user's wife, …”"). What straw will actually type ("Hi Ngozi, …") is in its steps: check that Tool Mac Tool Run's card shows them |

### What to do next

1. Peter's outcome in a header, read by Super Face for the review note and for following runs
   (finding 1). It's the one change that would have removed most of what went wrong here.
2. Super Face's notes as messages of their own, not folded into Peter's answer (finding 2).
3. Two lines in Peter's instructions: only what's asked (no runs, windows or wording of his own),
   and a message to send goes word for word (finding 3).
4. Then run A and B again, and then with qwen3:8b itself (both models, through Ollama), which is
   the test that matters.

Items 1 to 3, and the smaller ones, are now done: see below.

### Fixes applied (after runs A and B)

Made in both apps; not yet run through the scenarios again.

| Finding | What changed |
|---|---|
| 1. "Send the whole request again" read as failure | **Peter**: the closing line is gone, from his model's instructions and from his own answers (an empty request, an error). How a request went is now the `X-Peter-Outcome` header on `POST /api/say`, worked out by his code from his tool calls, never from his words: `asked` (a run was put on the Mac), `done` (a tool did something), `nothing` (no tool did anything: he needs something, can't, or said how to ask), `error` (he couldn't finish). **Super Face**: `peter.say()` reads it; "Peter didn't do that" is added only for `nothing` or `error`, and not when the model had asked "how would I ask you to …?"; a run is followed when the outcome is `asked`, whatever the words. `troubled()` stays only for a Peter too old to send the header. |
| Peter keeps no conversation | **Super Face's system prompt** now says it: "He remembers nothing: each message is all he has, so make it whole, with every detail (never "yes", "the second one" or "as before"), and when he needs something, send the whole request again with it." |
| 2. The fold cuts Super Face's notes | **Super Face**: its notes (Peter didn't do that, only your first message was sent, out of rounds) are messages of their own after Peter's answer, so folding his answer never cuts one. |
| 3. Peter's model does more than it's asked | **Peter's instructions**: "Do only what's asked. Don't start a run, drive Chrome, show a window or write anything the request didn't ask for: if that's what it would take, say so, and how to ask for it." and "A message for someone else (a text, an email, a note to them) goes word for word as given: add nothing, change nothing." **Super Face's prompt**: "A message for someone else goes to him in the exact words to send." |
| 4. Word for word can lack what it refers to | **Super Face's prompt**: standing instructions go to Peter word for word, "saying in brackets what it refers to when the words alone don't (which store, which person)". |
| 5. Telling the user before Peter answers | **Super Face's prompt**: "Before Peter answers, tell the user only what you're doing ("Let me check."), never how it turned out." and "What waits for the user to click Run on the Mac is asked for, not done." |
| 6. Tool names in Peter's answers | **Peter's instructions**: "never a tool's name (say "fill in the search in Chrome", not "straw")". |

Tests: Peter's 22 pass (Swift 6.1 on Linux), with a new one for the outcome (a job done that says what it couldn't find is `done`; a run put in any words is `asked`; no tool, or every tool failing, is `nothing`; his model out of reach is `error`). Super Face's pass (73; `keep-clear.test.mjs` needs the `three` package, which isn't installed in this checkout, before and after), with new ones: no critic after a job done; a run followed though Peter said "I've asked for"; no critic after "how would I ask you…?"; the note whole after the fold. The kit follows: `harness.mjs` reads Peter's outcome (the stand-in writes it at the end of its log, as his code works it out) and adds the notes as their own messages.

## How it's run (and how to run it again)

Everything either side reads comes from the code of the three apps, by
[`scripts/simulate/prompts.mjs`](../scripts/simulate/prompts.mjs), with the other two checkouts beside
this one:

```bash
export TZ=America/Chicago
NOW=2026-10-25T21:40:00 node scripts/simulate/prompts.mjs superface [notes.json] > sf-system.txt  # Super Face's system prompt
node scripts/simulate/prompts.mjs peter > peter-brief.txt          # Peter's model's instructions and tools
node scripts/simulate/prompts.mjs to-peter "…" 2026-10-25T21:40:06  # a message as his model gets it
```

- `superface` is `systemPrompt()` from Super Face's `src/main/prompt.mjs`, with the notes it reads
  from Storage Spaces (`notes.json`: its standing instructions and playbook).
- `peter` is `Peter.instructions` from `Agent.swift` with Tool Mac Tool Run's guide after it, then
  every tool his model is given: Tool Mac Tool Run's (from its `ToolsAPI.swift`, with their
  arguments, marked when they wait for Run) and his own (schedule, requests, access, space_notes).
- [`scripts/simulate/harness.mjs`](../scripts/simulate/harness.mjs) is Super Face's harness, using its
  own `calls.mjs`, `prompt.mjs` and `peter.mjs`: who an answer is to, only the first message to Peter
  sent, the nudges, `troubled()` and the review note, the round limit, and the fold at each new
  request. `user`, `model`, `peter` and `news` each add one turn to a conversation file.
- Each turn is a fresh Claude Haiku subagent, with [`model-role.md`](../scripts/simulate/model-role.md)
  (Super Face's model: the system prompt and the conversation) or
  [`peter-role.md`](../scripts/simulate/peter-role.md) (Peter's model: his instructions, his tools and
  the one message; it also plays the tools, from a world sheet in
  [`scripts/simulate/scenarios/`](../scripts/simulate/scenarios/)). That's faithful to both apps:
  Super Face sends its whole history every time, and Peter's model sees one message. After its
  answer, each stand-in says what in its instructions was unclear; several findings came from that.
- `transcript.mjs` turns a conversation file into a transcript.

How faithful it is: Haiku is stronger than qwen3:8b, on both sides; whatever went wrong here will
go wrong more on the real models, and some of what went right (Peter's model checking for the
duplicate run) may not. What the tools gave back was made up by the Peter stand-in from the world
sheet, so it's realistic, not real. The user's lines and the news of runs (as Peter's `newsLine`
words them) were written by hand; one world sheet had a mistake (flight times that didn't add up
across time zones, run A, S6), which the model caught and asked Peter about. Timing (the user
talking over the model, news arriving mid-answer) isn't simulated.

## Run 1: before the rewrite (templates)

Run 1 was made on the template design, with an earlier version of the kit (it read Peter's
templates from `SayForms.swift`, which is gone; it's in this repository's history, with the
transcripts below). What it found led to the rewrite; [Run 1's findings, now](#run-1s-findings-now)
says which are fixed. It's kept as it was written.

### How run 1 was run

Everything either side reads is taken from the code of both apps by
[`scripts/simulate/prompts.mjs`](../scripts/simulate/prompts.mjs), so it doesn't drift from them:

```bash
# Super Face's checkout beside this one (or SUPER_FACE=/path/to/it)
NOW=2026-10-25T21:40:00 TZ=America/Chicago node scripts/simulate/prompts.mjs superface notes.json > sf-system.txt
node scripts/simulate/prompts.mjs peter > peter-brief.txt
TZ=America/Chicago node scripts/simulate/prompts.mjs user "is the walmart near me still open?" 2026-10-25T21:40:03
```

- `superface` is `systemPrompt()` from Super Face's `src/main/prompt.mjs`, called the way
  `assistant.mjs` calls it, with the notes Peter would give (`notes.json`: the playbook, the
  standing instructions, what MEMORY has on the user). `user` and `from-peter` make each message
  the way `userMessage()` and `peterMessage()` do (who, when, `@qwen3 …`).
- `peter` is the brief for whoever plays Peter: the order his `sayAnswer()` tries things in, how a
  one-sentence template matches (`SayMatch.match`: a blank at the end takes all the rest), the
  shapes his script answers in (`Peter.swift`, `SayWords.swift`), his reader's instructions
  (`SayTranslator.system`, word for word) and every template (`SayForms.swift`, with the other
  wordings the matcher also takes, and the shipped example scripts).
- The two stand-ins were Claude Haiku subagents, each started fresh for every turn with
  [`model-role.md`](../scripts/simulate/model-role.md) or
  [`peter-role.md`](../scripts/simulate/peter-role.md). That's faithful to both apps: Super Face
  sends its whole history every time, and Peter keeps no conversation. Each stand-in also wrote,
  after its answer, what in its instructions was unclear for that turn; that's where several
  findings came from.
- **The harness was played by hand, from `assistant.mjs`:** only the first `@peter` message of an
  answer is sent; `troubled()` decides whether Peter's answer failed, and if so `NOTE.review` is
  added to it; the nudges (`promisesWork`, `claimsInability`, JSON); after a request with two
  messages to Peter or a failure, `NOTE.reflect` (the learning step) is asked, outside the
  history; the notes are read once at the start of each request.
- What Tool Mac Tool Run would answer (web results, pages, notes, scripts) is a world sheet per
  scenario: [`scripts/simulate/scenarios/`](../scripts/simulate/scenarios/).
- `transcript.mjs` turns a conversation file into the transcripts below.

#### How faithful it is

- **Where the Peter stand-in was kinder than his code, its answer was corrected to the code**, and
  the transcripts show the corrected one. Haiku kept reading a compound message as a model would
  ("search the web for X, open the page, and tell me Y" → offer the search), where Peter's matcher
  takes the first template whose fixed words start the message and puts all the rest in its last
  blank. It also missed the other ways a template is said (`open {a web address}` is "Open a page
  in Chrome" too), and once ran a "Do steps in Chrome" at once, though it waits for Run on the Mac.
  The brief now says all three, and later turns needed fewer corrections. Every correction was
  checked against `SayMatch.swift`, `Schedule.cancel`, `LaterWords.read`, `sayMend` and `troubled()`
  (run in node).
- Where a result depends on Peter's model (how sure his reader is), one plausible reading was
  taken and is noted. His real reader is a small local model, so its confidence will vary.
- Haiku is a stronger model than qwen3:8b. Whatever went wrong here will go wrong more often on
  the real model; some things that went right (the model noticing what Peter dropped) may not.
- Not simulated: timing (the user talking while Peter's news comes in, the inbox batching), the
  tones, speech, the Run card's wait and the 20-second "It's waiting for you to click Run" line.
- Two harness slips in the first round: Peter's answers to S4 and S5 had "Nothing was done" in
  them, which `troubled()` counts as a failure, so the real app would have added `NOTE.review`;
  it wasn't added. Neither model answer would likely have changed.

The setting for all of them: Sunday 25 October 2026, about 21:40 in Austin. MEMORY has "the user
@pref lives in Austin, TX 78745"; the playbook and the standing instructions start empty. The
model is `qwen3:8b` (so it's `@qwen3`), and the character is called Ava.

### The scenarios

| | What's said | What it tests |
|---|---|---|
| [S1](#s1-the-walmart-near-me-baseline) | "is the walmart near me still open? and when do they close tomorrow? let me see it", then "from now on whenever I say walmart…", then, two days later, "walmart" | The PETER.md example, end to end: search, read, open in Chrome, a standing instruction, using it |
| [S2](#s2-an-umbrella-in-lagos-then-a-backup) | "gonna need an umbrella in lagos tomorrow?", then "also back up my documents" | Words Peter needs his reader for; a script the model has never heard of |
| [S3](#s3-a-reminder-then-changed) | "remind me to call my mom in 20 minutes", then "actually make that 30 minutes instead" | The schedule; changing something already set (one message per answer) |
| [S4](#s4-a-note-by-the-wrong-name) | "what's on my grocery list" (the note is called "groceries") | A failure and Peter's mend; the review note; learning |
| [S5](#s5-something-nobody-can-do-text-my-wife) | "text my wife that I'm running about 15 minutes late" | No tool for it; a question for the user; a run that waits for the click; news |
| [S6](#s6-flights-from-austin-to-lagos) | "find me flights from austin to lagos next friday" | Several steps; a result that doesn't have what was asked; when to stop |

#### S1: the Walmart near me (baseline)

**You** (Sunday 25 October 2026, 21:40:03):
> is the walmart near me still open? and when do they close tomorrow? let me see it

**qwen3** (said aloud):
> Let me check, and I'll pull it up on your screen.

**qwen3 → Peter** (a rising tone, not said):
```
@peter search the web for Walmart Supercenter hours Austin TX 78745, open the closest store's page in the browser so it shows on screen, and tell me whether it's open now and what time it closes today (Sunday 25 October 2026) and tomorrow (Monday 26 October 2026).
```

**Peter** (21:40:07, a falling tone, not said):
```
The web has these for "Walmart Supercenter hours Austin TX 78745, open the closest store's page in the browser so it shows on screen, and tell me whether it's open now and what time it closes today (Sunday 25 October 2026) and tomorrow (Monday 26 October 2026).":
1. Walmart Supercenter in Austin, TX | 710 E Ben White Blvd
   https://www.walmart.com/store/1234-austin-tx
   Open today until 11pm. Store hours 6am–11pm. Pharmacy, pickup and delivery…
2. Walmart Supercenter in Austin, TX | 5017 W Hwy 290
   https://www.walmart.com/store/5678-austin-tx
   Open today until 11pm…
3. Walmart Neighborhood Market | 1931 E Oltorf St
   https://www.walmart.com/store/3456-austin-tx
   Open today until 10pm…

You can also say:
- read the page at {a web address}
- open {a web address} in Chrome
```

**qwen3** (said aloud):
> Search says it's open until 11 tonight. Let me pull up the store page and check tomorrow too.

**qwen3 → Peter** (a rising tone, not said):
```
@peter open https://www.walmart.com/store/1234-austin-tx in Chrome so it shows on screen, then read its hours and tell me whether the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 is open now (Sunday 25 October 2026, about 21:40), what time it closes today (Sunday 25 October), and what time it closes tomorrow (Monday 26 October).
```

**Peter** (21:40:31, a falling tone, not said):
```
That isn't a web address: https://www.walmart.com/store/1234-austin-tx in Chrome so it shows on screen, then read its hours and tell me whether the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 is open now (Sunday 25 October 2026, about 21:40), what time it closes today (Sunday 25 October), and what time it closes tomorrow (Monday 26 October).
Tried instead: open https://www.walmart.com/store/1234-austin-tx in Chrome

Opened in your own Chrome window, side by side with the person's. Walmart Supercenter in Austin, TX | 710 E Ben White Blvd
Walmart Supercenter, 710 E Ben White Blvd, Austin, TX 78745. (512) 443-6601. Store hours: Open today until 11pm. Mon–Sun: 6am – 11pm. Pharmacy hours: Mon–Fri 9am – 8pm, Sat 9am – 6pm, Sun closed. Services: pickup, delivery, auto care…

You can also say:
- where is {words on the page} on the page
- read the page in Chrome
```

**qwen3** (said aloud):
> It's open now, and I've got the store page up on your screen. Tonight it closes at 11, and tomorrow, Monday, it closes at 11 too. The pharmacy closes earlier, at 8 tomorrow.

**qwen3 → Peter** (a rising tone, not said):
```
@peter add this to the note "Super Face playbook": - To show a web page on screen, ask for only "open <web address> in Chrome" in one request, and ask for the reading in a separate request.
```

**Peter** (21:40:52, a falling tone, not said):
```
Taken as:
Add to a note
- name: Super Face playbook
- text: - To show a web page on screen, ask for only "open <web address> in Chrome" in one request, and ask for the reading in a separate request.

Added that to the end of the note Super Face playbook.

You can also say: read the note {its name}
```

**qwen3** _(says nothing: `@user nothing`)_

**You** (21:43:20):
> from now on whenever I say walmart just tell me yes if they're open and no if they're closed

**qwen3** (said aloud):
> Okay, from now on, when you say Walmart, I'll check and just tell you yes or no.

**qwen3 → Peter** (a rising tone, not said):
```
@peter add this to the note "Super Face instructions": - When the user says "walmart", ask Peter to read the hours of the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 (https://www.walmart.com/store/1234-austin-tx, the one closest to the user) and check whether it is open right now, by comparing those hours with the current time in Austin, Texas (Central time). Then answer the user with only "yes" if it is open or "no" if it is closed. Use another Walmart only if the user names one.
```

**Peter** (21:43:31, a falling tone, not said):
```
Taken as:
Add to a note
- name: Super Face instructions
- text: - When the user says "walmart", ask Peter to read the hours of the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 (https://www.walmart.com/store/1234-austin-tx, the one closest to the user) and check whether it is open right now, by comparing those hours with the current time in Austin, Texas (Central time). Then answer the user with only "yes" if it is open or "no" if it is closed. Use another Walmart only if the user names one.

Added that to the end of the note Super Face instructions.

You can also say: read the note {its name}
```

**qwen3** _(says nothing: `@user nothing`)_

**You** (Tuesday 27 October 2026, 23:20:04):
> walmart

**qwen3** (said aloud):
> Let me check.

**qwen3 → Peter** (a rising tone, not said):
```
@peter read the page at https://www.walmart.com/store/1234-austin-tx and tell me whether the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 is open right now, Tuesday 27 October 2026 at 23:20 Central time (UTC-05:00), and what its hours are today and tomorrow.
```

**Peter** (23:20:16, a falling tone, not said):
```
That isn't a web address: https://www.walmart.com/store/1234-austin-tx and tell me whether the Walmart Supercenter at 710 E Ben White Blvd, Austin TX 78745 is open right now, Tuesday 27 October 2026 at 23:20 Central time (UTC-05:00), and what its hours are today and tomorrow.
Tried instead: read the page at https://www.walmart.com/store/1234-austin-tx

Walmart Supercenter in Austin, TX | 710 E Ben White Blvd
Walmart Supercenter, 710 E Ben White Blvd, Austin, TX 78745. (512) 443-6601. Store hours: Closed now. Opens tomorrow at 6am. Mon–Sun: 6am – 11pm. Pharmacy hours: Mon–Fri 9am – 8pm, Sat 9am – 6pm, Sun closed. Services: pickup, delivery, auto care…

You can also say:
- Find words on a web page
  - address: {a web address}
  - words: {what to look for on it}
- open {a web address} in Chrome
```

**qwen3** (said aloud):
> no

What happened, against PETER.md's version of it:

- **First message to Peter: three requests in one** (search, open the closest page, tell me if
  it's open and the hours). Peter matched `search the web for {…}` and searched for the whole
  sentence, "Walmart Supercenter hours … open the closest store's page in the browser … tomorrow
  (Monday 26 October 2026)". The web would likely still find the stores, but "open it" and "tell
  me" were dropped, and his answer doesn't say so.
- **Second: again two in one** ("open … in Chrome so it shows on screen, then read its hours and
  tell me…"). `open {a web address}` took everything after "open" as the address; Tool Mac Tool
  Run refused it, his reader was asked, and the page was opened on the second try ("Tried
  instead"). The model got its answer only because the opened page's first words had the hours.
- It answered the user well (open till 11, 6 to 11 tomorrow, pharmacy closes at 8) and wrote a
  playbook line on its own: ask for the page on its own, the reading separately. That's the right
  lesson, but it's learned one case at a time, per user, and a small model may not learn it.
- **The standing instruction it wrote bakes in the same mistake:** "ask Peter to read the hours …
  and check whether it is open right now, by comparing those hours with the current time". Two
  days later "walmart" sent "read the page at <url> and tell me whether … is open right now …",
  which failed (the address had words after it) and was saved by Peter's mend, at the cost of a
  call to his model, every time. PETER.md's version writes a line that names the template ("ask
  Peter for the lines with "hours" on <url>").
- "Let me check." was said before the one-word "No.", though the instruction asked for only yes or
  no. (PETER.md's version says nothing until the answer: the busy tone plays instead.)
- It said "Okay, from now on…" to the user before Peter had added the instruction.

#### S2: an umbrella in Lagos, then a backup

**You** (Sunday 25 October 2026, 21:40:03):
> gonna need an umbrella in lagos tomorrow?

**qwen3** (said aloud):
> Let me check the forecast for Lagos tomorrow.

**qwen3 → Peter** (a rising tone, not said):
```
@peter search the web for the Lagos, Nigeria weather forecast for Monday 26 October 2026, including chance of rain and temperature
```

**Peter** (21:40:07, a falling tone, not said):
```
The web has these for "the Lagos, Nigeria weather forecast for Monday 26 October 2026, including chance of rain and temperature":
1. Lagos, Lagos, Nigeria 10-Day Weather Forecast
   https://weather.com/weather/tenday/l/Lagos
   Mon 26: Thunderstorms, 80% rain, 31°/25°
2. Lagos weather - AccuWeather
   https://www.accuweather.com/en/ng/lagos/4607/daily-weather-forecast
   Monday: a couple of t-storms, 31°

You can also say:
- read the page at {a web address}
- open {a web address} in Chrome
```

**qwen3** (said aloud):
> Yes, take an umbrella. Both forecasts for Lagos tomorrow show thunderstorms and about an 80 percent chance of rain, with highs near 31 degrees Celsius.

**You** (21:41:02):
> nice. also back up my documents

**qwen3** (said aloud):
> Sure, let me find your documents first and see what backup spot you have.

**qwen3 → Peter** (a rising tone, not said):
```
@peter Find the user's Documents folder on this Mac and check for a connected external drive or network drive I could back them up to. Tell me the folder's size, how many files it has, and which drives are available. If you find more than one drive and can't tell which one the user wants, give me the choices.
```

**Peter** (21:41:12, a falling tone, not said):
```
These can do that:
1. Run Flow code
     - code: {Flow code, like run "utilities/weather.py" ["Paris"]}
2. Check Flow code
     - code: {Flow code}
3. Search the web
     search the web for {what to look for}
4. The latest runs
     what has run lately
Fill one in and say it back.
```

**qwen3** (said aloud):
> Let me see what I can set up for backing up your documents.

**qwen3 → Peter** (a rising tone, not said):
```
@peter
Check Flow code
- code: a backup flow that copies the user's Documents folder to an external or network drive
```

**Peter** (21:41:30, a falling tone, not said):
```
Check Flow code found a mistake: line 1: "a backup flow that copies the user's Documents folder to an external or network drive" isn't a Flow statement (a line starts with run, let, if, each…).
The person wants their Documents folder copied to a drive; nothing here checks folders or drives, but the Nightly backup script may be what's meant.
Is it the nightly backup they want run?

You can also say:
- Check Flow code
  - code: {Flow code}
```

**qwen3** (said aloud):
> Peter found a nightly backup script that may be the one you mean, but I don't know yet what it copies or where it goes. Should I run it now to back up your Documents?

**qwen3 → Peter** (a rising tone, not said):
```
@peter Find out about the Nightly backup script on this Mac: its exact name, which folders it copies, which drive or network location it writes to, and when it is scheduled to run. Do not run it yet; just tell me what it would do.
```

What happened:

- The umbrella went well: a web search (no click needed) rather than the Weather script (which
  waits for Run), and a straight answer. Its search filled the blank with an instruction ("…,
  including chance of rain and temperature"), which went to the search engine as it was.
- **"Back up my documents" went nowhere.** The model doesn't know there's a "Nightly backup"
  script: Super Face never sees Peter's templates or the folder's scripts, and the playbook was
  empty. So it asked Peter to explore the Mac (find the Documents folder, its size, the drives),
  which nothing does. Peter offered Flow code, which the model then filled with a description
  ("a backup flow that copies…"), which isn't Flow code. Peter's offer didn't list Nightly backup
  either: what was said was "back them up", and "back up" isn't the word "backup".
- Only his reader's look at the failure named the script ("the Nightly backup script may be what's
  meant"). The model then asked the user whether to run it **and** asked Peter to describe it
  without running it, which no template does (and "Nightly backup" being the closest by its words,
  a sure enough reader would have *asked for the run*, the opposite of what was said; the click on
  the Mac would still stop it). Stopped here: four messages to Peter, nothing done.
- PETER.md's version has the model say "@peter run the nightly backup" straight away. Nothing in
  the system prompt makes that possible.

#### S3: a reminder, then changed

**You** (Sunday 25 October 2026, 21:20:05):
> remind me to call my mom in 20 minutes

**qwen3** (said aloud):
> Sure, I'll remind you in 20 minutes, at 9:40.

**qwen3 → Peter** (a rising tone, not said):
```
@peter remind me in 20 minutes: tell the user it's time to call their mom.
```

**Peter** (21:20:08, a falling tone, not said):
```
Set for today at 21:40 (in 20 minutes): tell the user it's time to call their mom. Its number is 3. I'll tell you then.

You can also say: what's scheduled
```

**qwen3** (said aloud):
> Done, I'll remind you at 9:40 tonight to call your mom.

**You** (21:22:10):
> actually make that 30 minutes instead

**qwen3** (said aloud):
> Okay, I'll move it to 30 minutes from now, so 9:52 tonight.

**qwen3 → Peter** (a rising tone, not said):
```
@peter cancel the reminder set for today at 21:40 to tell the user it's time to call their mom (number 3). Then remind me at 21:52 today: tell the user it's time to call their mom.
```

**Peter** (21:22:20, a falling tone, not said):
```
Taken off the schedule: 3. tell the user it's time to call their mom.

You can also say: what's scheduled
```

**qwen3** (said aloud):
> The 9:40 reminder is off now. I'm setting the new one for 9:52.

**qwen3 → Peter** (a rising tone, not said):
```
@peter remind me at 21:52 today: tell the user it's time to call their mom.
```

**Peter** (21:22:31, a falling tone, not said):
```
Set for today at 21:52 (in 30 minutes): tell the user it's time to call their mom. Its number is 4. I'll tell you then.

You can also say: what's scheduled
```

**qwen3** (said aloud):
> Done. The 9:40 reminder is off, and the new one is set for 9:52 tonight to call your mom.

What happened:

- **The user was told it was set before it was:** "Sure, I'll remind you in 20 minutes, at 9:40" is
  said aloud the moment the model writes it, before Peter has answered. Then "Okay, I'll move it
  to … 9:52" the same way.
- **The change was two requests in one** ("cancel the reminder … (number 3). Then remind me at
  21:52 …"). `cancel the reminder {…}` took the rest of the message as the phrase; `Schedule.cancel`
  compared its words with what's scheduled and took off number 3. The new reminder was dropped
  without a word: Peter answered only "Taken off the schedule: 3…".
- The model noticed, and asked for the new one on its own. Had it not (a small model may well not),
  the user would have heard "9:52" with nothing set and no reminder at all.
- "Make that 30 minutes instead" was taken as 30 minutes from now (21:52), not from when it was
  asked (21:50). Either reading is fair; it said which.

#### S4: a note by the wrong name

**You** (Sunday 25 October 2026, 21:40:03):
> what's on my grocery list

**qwen3** (said aloud):
> Let me check your grocery list.

**qwen3 → Peter** (a rising tone, not said):
```
@peter look in my notes for the grocery list and read me everything on it, with the note's title.
```

**Peter** (21:40:09, a falling tone, not said):
```
It sounds like: reading everything in your grocery list note, with its title.
You might mean:
1. Read a note
     read the note groceries
2. Search my notes
     search my notes for grocery list
Nothing was done. Say one of them back (filled in, changed if need be).
```

**qwen3** (said aloud):
> Let me try that again.

**qwen3 → Peter** (a rising tone, not said):
```
@peter read the note groceries, and tell me its title and everything on it. If there is no note with that name, search my notes for grocery list and read me the note that is my grocery list, with its title.
```

**Peter** (21:40:40, a falling tone, not said):
```
There's no note called groceries, and tell me its title and everything on it. If there is no note with that name, search my notes for grocery list and read me the note that is my grocery list, with its title.
Tried instead: read the note groceries

The note groceries:
- eggs
- oat milk
- coffee
- rice

You can also say:
- Add to a note
  - name: {its name}
  - text: {what to add at its end}
- Write a note
  - name: {its name}
  - text: {what it says (it replaces what was there)}
```

**App note** (added by Super Face): _Note from the app (not the user, not Peter): that didn't work. Before anything else, look at why: the wrong words, a template filled wrong, something his answer tells you? Try once more a different way if one could work; otherwise tell the user plainly what went wrong and what would fix it. Don't send the same thing again unchanged._

**qwen3** (said aloud):
> Your groceries note has eggs, oat milk, coffee, and rice.

**qwen3 → Peter** (a rising tone, not said):
```
@peter please add this one line to the note "Super Face playbook": "- The grocery list is the note called groceries; read it by that name, in a single request."
```

**Peter** (21:40:58, a falling tone, not said):
```
Taken as:
Add to a note
- name: Super Face playbook
- text: - The grocery list is the note called groceries; read it by that name, in a single request.

Added that to the end of the note Super Face playbook.

You can also say: read the note {its name}
```

**qwen3** (said aloud):
> Your grocery note is called groceries, and it has eggs, oat milk, coffee and rice.

What happened:

- First message: "look in my notes for the grocery list and read me everything on it, with the
  note's title". Nothing started with a template's words, so his reader was asked, wasn't sure
  enough (0.6), and offered "read the note groceries" and "search my notes for grocery list".
- **The model didn't send one back as it was.** It wrote "read the note groceries, and tell me its
  title and everything on it. If there is no note with that name, search my notes…": a fallback
  plan in one message. `read the note {its name}` took all of it as the name, the read failed, and
  his reader mended it to "read the note groceries", which worked.
- **Then the app told the model it hadn't worked.** `troubled()` matches "There's no note" in the
  first line of the mended answer, so `NOTE.review` ("that didn't work…") was added to an answer
  that worked. The stand-in said so: "the app's note saying 'that didn't work' is wrong about this
  result".
- **It told the user twice.** After its playbook line came back "Added", it said the list again
  ("Your grocery note is called groceries, and it has…").
- At the learning step it saw "(nothing yet)" as its playbook: the notes are read at the start of a
  request, so the line it had just added wasn't there, and it said it couldn't tell whether it was
  about to add it again.

#### S5: something nobody can do ("text my wife")

**You** (Sunday 25 October 2026, 21:40:03):
> text my wife that I'm running about 15 minutes late

**qwen3** (said aloud):
> Let me text her now.

**qwen3 → Peter** (a rising tone, not said):
```
@peter Text my wife that I'm running about 15 minutes late. Find her in my contacts or MEMORY; if there is more than one possible wife or no contact, tell me which you need instead of sending. Once sent, tell me who it went to and when.
```

**Peter** (21:40:10, a falling tone, not said):
```
It sounds like: text your wife that you're running about 15 minutes late.
You might mean:
1. Do steps in Chrome
     Do steps in Chrome
     - steps: open web.whatsapp.com / click "{her name}" / type "I'm running about 15 minutes late" / press Enter
Nothing was done. Say one of them back (filled in, changed if need be).
Who is your wife? MEMORY has nothing about her, so give her name as it shows in WhatsApp, or her number.
```

**qwen3** (said aloud):
> I don't have your wife's name yet. What name does she show as in WhatsApp, or what's her number?

**You** (21:41:15):
> Ngozi. it's whatsapp

**qwen3** (said aloud):
> Okay, I'll text Ngozi on WhatsApp now.

**qwen3 → Peter** (a rising tone, not said):
```
@peter
Do steps in Chrome
- steps: open web.whatsapp.com / click "Ngozi" / type "I'm running about 15 minutes late" / press Enter
```

**Peter** (21:41:24, a falling tone, not said):
```
Asked for do steps in Chrome: open web.whatsapp.com / click "Ngozi" /…. I'll tell you how it goes.

You can also say: what happened to {something you asked for}
```

**qwen3** _(an empty answer: nothing said, nothing sent)_

**Peter** (21:42:10, a falling tone, not said):
```
Meanwhile: Do steps in Chrome: open web.whatsapp.com / click "Ngozi" /… finished (it worked). It printed:
opened https://web.whatsapp.com
clicked "Ngozi"
typed "I'm running about 15 minutes late"
pressed Enter
```

**qwen3** (said aloud):
> It's sent. I told Ngozi on WhatsApp that you're running about 15 minutes late, at about 9:42. I can't see the chat from here, so tell me if it doesn't look right on your screen.

**qwen3 → Peter** (a rising tone, not said):
```
@peter Remember in MEMORY, category PEOPLE, about "the user": the user's wife is Ngozi, and they text her on WhatsApp. Also add this line to the note "Super Face playbook": "- Texts on WhatsApp: open web.whatsapp.com in Chrome, click the contact's name, type the message, press Enter. Worked for Ngozi, 25 Oct."
```

**Peter** (21:42:30, a falling tone, not said):
```
Taken as:
Remember something
- category: PEOPLE
- about: the user
- fact: the user's wife is Ngozi, and they text her on WhatsApp

Remembered under PEOPLE: the user.

You can also say:
- what's coming up [this week | this month | today | in the next {a number of} days]
- what do you know about {a name}
```

What happened:

- **"Let me text her now." was said before anyone knew it could be done.** Its message to Peter
  assumed contacts and texting he doesn't have ("Find her in my contacts or MEMORY…").
- Peter's reader suggested Do steps in Chrome on WhatsApp Web with her name blank, and asked who
  she is. (Knowing the user uses WhatsApp Web came from the world sheet given to the stand-in, not
  from anything Peter's reader would know. A real reader would more likely offer nothing, and Peter
  would answer "These can do that:" with unrelated templates.) The model asked the user, rather than
  guessing: good.
- With the name, it sent the labeled template back exactly. It waited for the click ("Asked for…"),
  and the news came by itself ("Meanwhile: … finished (it worked)").
- **It said "It's sent"** from a list of keystrokes (`click "Ngozi"`, `press Enter`) that doesn't
  show the message reached the right chat. It did hedge ("tell me if it doesn't look right").
- **The Run card's reason is only the first line of what was said**: `sayWhy` gives "Super Face
  asked in words: “Do steps in Chrome”", so whoever clicks Run sees the title, not what will be
  typed or to whom, unless Tool Mac Tool Run's card shows the steps themselves (worth checking).
- After "Asked for…" its answer was empty: nothing said, nothing sent. The harness takes that as
  the end, and the empty answer stays in the history.
- Then again two in one (remember Ngozi in MEMORY, and add a playbook line): Peter's reader took
  the first, the second was dropped without a word, and the model noticed and asked again.

#### S6: flights from Austin to Lagos

**You** (Sunday 25 October 2026, 21:40:03):
> find me flights from austin to lagos next friday

**qwen3** (said aloud):
> Let me look for flights from Austin to Lagos on Friday, October 30.

**qwen3 → Peter** (a rising tone, not said):
```
@peter search the web for one-way flights from Austin, TX (AUS) to Lagos, Nigeria (LOS) departing Friday October 30 2026, one adult, and list the best options with airline, departure time, number of stops, duration and price.
```

**Peter** (21:40:08, a falling tone, not said):
```
The web has these for "one-way flights from Austin, TX (AUS) to Lagos, Nigeria (LOS) departing Friday October 30 2026, one adult, and list the best options with airline, departure time, number of stops, duration and price":
1. Cheap flights from Austin to Lagos from $1,184 | KAYAK
   https://www.kayak.com/flight-routes/Austin-AUS/Lagos-LOS
   Find the cheapest round-trip…
2. Austin (AUS) to Lagos (LOS) flights | Google Flights
   https://www.google.com/travel/flights/flights-from-austin-to-lagos.html
   Find cheap flights… One-way from $742
3. Flights from Austin to Lagos | Expedia
   https://www.expedia.com/Cheap-Flights-Austin-To-Lagos.d0.Travel-Guide-Flights
   Round-trip from $1,210

You can also say:
- read the page at {a web address}
- open {a web address} in Chrome
```

**qwen3** (said aloud):
> Those sites only show starting prices, not the Friday flights. I'm opening Google Flights for the details. I'm taking next Friday to mean October 30.

**qwen3 → Peter** (a rising tone, not said):
```
@peter read the page at https://www.google.com/travel/flights/flights-from-austin-to-lagos.html and list the one-way flights from Austin (AUS) to Lagos (LOS) on Friday October 30 2026 for one adult. For each flight give the airline, departure time, number of stops, duration and price. If the page does not show that date, say so.
```

**Peter** (21:40:45, a falling tone, not said):
```
That isn't a web address: https://www.google.com/travel/flights/flights-from-austin-to-lagos.html and list the one-way flights from Austin (AUS) to Lagos (LOS) on Friday October 30 2026 for one adult. For each flight give the airline, departure time, number of stops, duration and price. If the page does not show that date, say so.
It sounds like: reading the Google Flights page for one-way flights from Austin to Lagos on Friday 30 October 2026.
```

**qwen3** (said aloud):
> Peter wants a clean web address, so I'll send it that way. Then I'll check the Friday flights on the page.

**qwen3 → Peter** (a rising tone, not said):
```
@peter
Read a web page
- address: https://www.google.com/travel/flights/flights-from-austin-to-lagos.html
```

**Peter** (21:41:05, a falling tone, not said):
```
Austin (AUS) to Lagos (LOS) flights | Google Flights
Flights from Austin to Lagos. Fri, Oct 30. Round trip · 1 adult · Economy.
Best departing flights:
Delta + Air France, 1 stop CDG, 21h 40m, $1,184 round trip
United + Lufthansa, 1 stop FRA, 19h 55m, $1,265 round trip
Qatar Airways, 1 stop DOH, 24h 10m, $1,098 round trip (cheapest)
Turkish Airlines, 1 stop IST, 22h 05m, $1,121 round trip
Prices include taxes and fees for 1 adult. One-way prices from $742 on other dates.

You can also say:
- Find words on a web page
  - address: {a web address}
  - words: {what to look for on it}
- open {a web address} in Chrome
```

**qwen3** (said aloud):
> The Google Flights page has four Friday options, but those prices are round trip, not one-way. The cheapest is Qatar Airways with one stop in Doha, about 24 hours, for $1,098 round trip. I'll try to get the one-way prices and departure times next.

**qwen3 → Peter** (a rising tone, not said):
```
@peter Find the one-way flights from Austin (AUS) to Lagos (LOS) on Friday October 30 2026, one adult, on Google Flights at https://www.google.com/travel/flights/flights-from-austin-to-lagos.html. For each flight give the airline, departure time, number of stops, duration and one-way price. If the page can't show one-way prices or departure times, say so.
```

**Peter** (21:41:40, a falling tone, not said):
```
It sounds like: the one-way flights from Austin to Lagos on Friday 30 October, with their times and prices, from the Google Flights page.
You might mean:
1. Find words on a web page
     Find words on a web page
     - address: https://www.google.com/travel/flights/flights-from-austin-to-lagos.html
     - words: one-way
2. Open a page in Chrome
     open https://www.google.com/travel/flights/flights-from-austin-to-lagos.html in Chrome
Nothing was done. Say one of them back (filled in, changed if need be).
```

**App note** (added by Super Face): _Note from the app (not the user, not Peter): that didn't work. Before anything else, look at why: the wrong words, a template filled wrong, something his answer tells you? Try once more a different way if one could work; otherwise tell the user plainly what went wrong and what would fix it. Don't send the same thing again unchanged._

**qwen3** (said aloud):
> My last request didn't go through, so I'll try a web search for the one-way fares instead.

**qwen3 → Peter** (a rising tone, not said):
```
@peter search the web for one-way flights from Austin (AUS) to Lagos (LOS) on Friday October 30 2026, one adult. For each flight give the airline, departure time, number of stops, duration and one-way price.
```

What happened:

- **Every message to Peter carried instructions he can't follow**: "…and list the best options with
  airline, departure time, number of stops, duration and price". In a search, all of that went to
  the search engine. After `read the page at`, it made the address unreadable ("That isn't a web
  address"), and his reader wasn't sure enough (0.7) to try again.
- **Nobody told the model that failed.** "That isn't a web address" and "It sounds like…" aren't
  in `troubled()`, so no review note was added. (In S4, where the mend *worked*, one was.)
- When Peter offered "Read a web page", the model wrote it as a labeled template ("Read a web
  page / - address: …"), a shape that template doesn't have (it's one sentence). It worked here,
  assuming `SayMatch.field` takes "address" for "a web address"; if not, it fails again.
- **It didn't know when to stop.** The page had round-trip prices and no departure times. It went
  on asking for one-way fares and times (four messages to Peter by then; the app allows ten for one request) instead of
  telling the user what it had. The user heard "I'll try…" lines between long silences.
- "Next Friday" (30 October or 6 November?) was never put to the user, though it changes every
  result; the stand-in flagged it on every turn.
- Stopped here, with a fifth message on its way: another web search with the same instructions in
  it.

### Findings

Ranked by how much they'd hurt. Each says where it was seen, why it happens (in the code), and a
way to close it. None of the fixes is made here: this is the log.

#### What worked

- **Addressing never broke.** Every answer was `@user …`, `@peter …` or both, in the right order,
  one message to Peter per answer; the one-message rule never had to cut anything. `@user nothing`
  was used when there was nothing to say.
- **"Peter keeps no conversation" held on the model's side.** It never sent "yes", "the second one"
  or "more"; each message to him was whole.
- **The critic habit caught Peter's silences** twice (S3's dropped reminder, S5's dropped playbook
  line), and it asked the user rather than guess when a name was missing (S5).
- **Peter's mend saved three requests** that would have failed (S1 twice, S4), and his reader's
  look at a failure was what found the backup script (S2).
- **Runs and news flowed as designed** (S5): "Asked for…", the turn ends, "Meanwhile: …" comes by
  itself and is answered.
- The schedule's sentences ("remind me in 20 minutes: …", "remind me at 21:52 today: …") were read
  by their words, no model needed.

#### 1. The model asks for several things in one message, and Peter does only the first (high)

**Seen in every scenario: 15 of the 24 messages to Peter.** "Search the web for X, open the
closest page, and tell me whether it's open"; "cancel number 3, then remind me at 21:52"; "read the
note groceries; if there's none, search my notes"; "remember Ngozi, and add this to the playbook";
"read the page at <url> and list the flights with airline, time, stops…".

Why: the system prompt says "go step by step (search, then read what you found)" but never says
*one thing per message*, and its own examples are written in a colleague's voice ("ask him the way
you'd ask a colleague"), so the model writes like it would to a colleague: compound, with
conditions and "tell me…". Peter's matcher (`SayMatch.match`) takes the first template whose fixed
words start the message and puts everything after in its last blank. So:

- a search goes out with the instructions in it (S1, S2, S6);
- a note name or a web address gets words after it, and fails (S4, S6, S1 twice);
- the second request is dropped (S1, S3, S5), **and Peter's answer doesn't say so**, so only a
  careful model notices. In S3 the user had already been told "9:52".

To close it, on both sides:

- **Super Face's prompt:** one request per message to Peter, and nothing after it: "say only what
  to do; never ask him to tell, compare, list, check or decide: he does, you think". Put a wrong
  and a right example in the prompt ("search the web for X, then open it" ✗; "search the web for
  X" … "open <address> in Chrome" ✓). Tell the model to copy his template lines exactly when he
  offers them.
- **Peter:** a blank that takes the rest of the message shouldn't take a second sentence or a
  "then …"/"and tell me …". At the least, say what was left out ("I did only: search the web for
  X. Not done: "open the closest store's page…": say it on its own."). For a web address blank,
  take the address and say what was left. Either change makes it impossible for a dropped request
  to pass unseen.

#### 2. The model doesn't know what Peter can do (high)

Seen in S2 (and behind S5 and S6). Asked to back up the documents, the model had no way to know
there's a "Nightly backup" script: since Super Face stopped loading Tool Mac Tool Run's tools, its
model sees no template and no script name. The system prompt lists what Peter "reaches" (the web,
Chrome, scripts and flows, notes…), not what there is. So the model invented a task nothing does
(explore the Documents folder, list the drives), then wrote Flow code as a description. PETER.md's
"@peter run the nightly backup" assumes the model knows the name.

Peter's own fallbacks didn't help either: his offer (`SayForms.search`) didn't list Nightly backup,
because "back them up" isn't the word "backup". His reader's question ("Is there a Flow script you'd
like to run?") was dropped: when the reader gives no suggestions, `sayTranslate` returns nil and
`sayOffer` answers without it.

To close it:

- Give the model a short list of what Peter has, read with the notes at the start of a request,
  exact (`what can you do`, as a client of its own, already answered without a model), or at least
  the folder's script and flow titles. A few lines are enough for "run the nightly backup".
- Or teach the model to ask "@peter what can you do" when it doesn't know a way.
- Peter: match "back up" to "backup" (and the like) when searching, and keep his reader's
  question in the offer when it has one.

#### 3. It tells the user it's done before Peter has done it (high)

Seen in S1, S3 (twice), S5. "Sure, I'll remind you in 20 minutes, at 9:40", "Okay, I'll move it to
9:52", "Let me text her now", "Okay, from now on…": the words before `@peter` are said aloud the
moment they're written (`answer()` speaks sentence by sentence), before Peter answers. The system
prompt's rule "never say something was done … unless Peter says so" is there, but its own reminder
example ends `@user Sure, I'll remind you at 15:40.` *after* Peter, and the model compresses that
into one answer. With finding 1, that's how S3 came within one careless model of a reminder said
to be set and never set.

To close it: in the prompt, the words before a message to Peter say only what you're doing ("Let
me set that.", "One moment."), never how it turned out. In the harness, `nudgeFor` only looks at
answers without a message to Peter; a check for an outcome said before Peter answered ("done",
"set for", "I'll remind you at", "it's sent") could hold those words back until he does.

#### 4. "Did it work?" is read from Peter's wording, and gets it wrong both ways (medium)

`troubled()` (Super Face, `src/main/peter.mjs`) decides from a regex over Peter's answer. Run on
the answers from this dry run:

| Peter's answer | `troubled()` | Really |
|---|---|---|
| "There's no note called groceries, and…\nTried instead: read the note groceries\n\nThe note groceries: …" | failed | worked (mended) |
| "That isn't a web address: …\nIt sounds like: …" | fine | failed |
| "It sounds like: …\nYou might mean: …\nNothing was done. …" | failed | nothing done; a choice |
| "These can do that: …" | fine | nothing done; a choice |

So the model was told "that didn't work" about an answer that worked (S4: it saw the contradiction
and ignored the note, a small model may not), and wasn't told about one that failed (S6). The same
regex decides whether to reflect afterwards, and what's shown as failed in the chat.

To close it: let Peter say the outcome, not just the words: a header on `/api/say`'s answer
(`X-Peter-Outcome: done | asked | offered | failed`, with `mended` when "Tried instead" worked),
and Super Face reads that instead of the regex.

#### 5. What it learns is narrow, written in plain sentences, and checked against stale notes (medium)

- The lines it wrote were about the case, not the lesson: "the grocery list is the note called
  groceries; read it in a single request", "to show a page, ask for only open <url>…". The real
  lesson (one request per message) belongs in the system prompt, for every user, from the first day
  (finding 1).
- **The standing instruction it wrote carried the mistake into every later use** (S1: "ask Peter to
  read the hours … and check whether it is open"). PETER.md's version writes the exact template to
  send. The prompt's learning section asks for "every detail it will need" but not for the words to
  send Peter.
- In the middle of a request, the model writes to notes in a sentence ("add this to the note "Super
  Face playbook": - …"). No one-sentence template matches that ("Add to a note" is labeled only),
  so each one is a call to Peter's model, needing 0.75 sure. `NOTE.reflect` gives the labeled shape,
  but the prompt's learning section doesn't. Give it there too, or give Peter a sentence for it
  ("add to the note {its name}: {what to add}").
- `reflect()` builds its prompt from the notes as they were read at the start of the request
  (`turn.read`), so it can't see a line added during it, and it said so (S4). Read the notes again
  before reflecting.

#### 6. It doesn't know when to stop, or when to ask first (medium)

S6: four messages to Peter, and a fifth on its way, for data the page didn't have (one-way fares, departure times), with "I'll
try…" said between them, rather than telling the user what it had. `MAX_ROUNDS` is ten for one
request, a long wait for a voice. And "next Friday" (30 October or 6 November) was never asked,
though it changes every result. The stand-in raised it on every turn. The prompt says to ask "only
when something you need is missing and Peter couldn't find it"; a date that could be either isn't
"missing".

To close it: in the prompt, after two tries that don't get closer, tell the user what you have and
what's left. Ask at the start when a word could mean two things that give different answers (a
date, which store). Fewer rounds for one request, or a spoken line after three.

#### 7. The Run card may not show what will be done (medium; check)

S5: a "Do steps in Chrome" (type a message to someone on WhatsApp) waits for Run on the Mac, as it
should. But the reason the card shows is `sayWhy(client, said)`: the first line of what was said,
which for a labeled template is its title: "Super Face asked in words: “Do steps in Chrome”". Unless
Tool Mac Tool Run's card shows the steps themselves, the person OKs typing to someone without seeing
what or to whom. Worth checking on the Mac; if it's so, put the template's values in the reason.

Also from S5: the model said "It's sent" from a list of keystrokes (`click "Ngozi"`, `press Enter`)
that doesn't show the message reached her chat. A steps run could end with reading the page back
("find "I'm running about 15 minutes late" on the page"), or the model could say "I typed it to
Ngozi" rather than "it's sent".

#### 8. Smaller things

- **Said twice** (S4): after a note-writing message came back "Added", the model told the user the
  answer again. The prompt could say: when Peter only confirms something done for you and the user
  already has their answer, answer `@user nothing`.
- **An empty answer** (S5, after "Asked for…"): nothing said, nothing sent. The harness treats it as
  the end, which is right, and pushes an empty assistant message into the history. Harmless with
  Ollama; `@user nothing` would be cleaner, and the prompt could say that's the answer to "Asked
  for" when the user's already been told.
- **Templates offered in a shape they don't have** (S6): the model wrote "Read a web page" with a
  "- address:" line, though that template is one sentence. Peter's `labeledForm` makes it lines
  with the blank's words as the label ("a web address"), so this works only if `SayMatch.field`
  takes "address" for it (a near match, not a prefix). Worth a test in `PeterTests`.
- **Times**: the prompt's examples say 15:40, the model said 9:40 and 9:52. Fine for speech, but the
  examples could match what's said aloud.
- **"Make that 30 minutes instead"**: 30 from now or from when it was first asked? It picked "now"
  and said the time, which is the right habit.
- **Blanks filled with explanations** ("…, including chance of rain and temperature",
  "…, one adult, and list the best options…"): the web search gets the extra words. Part of
  finding 1, and the cheapest to fix in the prompt: "fill a blank with only what goes there".

#### What to try next

- Re-run the six with the prompt changes from findings 1 to 3 (the scenario sheets and the role
  briefs are in `scripts/simulate/`), and compare the count of compound messages and early claims.
- Run them with qwen3:8b itself: Super Face's model is a local Ollama model, so the same files can
  go to `ollama run` with the system prompt (`prompts.mjs superface`) and the conversation, one
  turn at a time. That's the test that matters, since it's the model the user has.
- A scenario for timing: the user talking while "Meanwhile" comes in, and cancelling a run that's
  waiting for its click.
