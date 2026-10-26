#!/usr/bin/env node
// What a simulated exchange between Super Face's model and Peter is built from, taken from the
// code of both apps (nothing here is written by hand, so it doesn't drift):
//
//   node scripts/simulate/prompts.mjs superface [notes.json]   Super Face's system prompt, exactly as
//                                                              src/main/prompt.mjs builds it
//   node scripts/simulate/prompts.mjs peter                    the brief for whoever plays Peter: his
//                                                              reader's prompt, his templates, his answers
//   node scripts/simulate/prompts.mjs user "text" [at]         a message from the user, as the model gets it
//   node scripts/simulate/prompts.mjs from-peter "text" [at]   one from Peter, as the model gets it
//
// Super Face's checkout is looked for beside this one (../JUST-super-mac-tts-ONLY-service), or
// where SUPER_FACE says. notes.json is what Peter would give it for its notes:
// {"playbook": ["- …"], "instructions": "- …", "aboutUser": ["the user @pref lives in Austin, TX 78745"]}.
// See "docs/Simulated exchange - Super Face and Peter.md" for how they're used.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const peterRepo = path.resolve(here, '../..');
const faceRepo = path.resolve(process.env.SUPER_FACE || path.join(peterRepo, '../JUST-super-mac-tts-ONLY-service'));
const MODEL = process.env.MODEL || 'qwen3:8b';

async function face(file) {
  return import(pathToFileURL(path.join(faceRepo, 'src/main', file)).href);
}

async function superface(notesFile) {
  const { systemPrompt } = await face('prompt.mjs');
  const { Notes } = await face('notes.mjs');
  const notes = new Notes({ peter: null });
  if (notesFile) Object.assign(notes, JSON.parse(fs.readFileSync(notesFile, 'utf8')));
  const now = process.env.NOW ? Date.parse(process.env.NOW) : Date.now();
  return systemPrompt({ character: { name: process.env.CHARACTER || 'Ava' }, model: MODEL, peter: { reachable: true }, notes, now });
}

/** Peter's reader's instructions, as SayTranslator.swift has them. */
function readerPrompt() {
  const src = fs.readFileSync(path.join(peterRepo, 'Sources/PeterCore/Say/SayTranslator.swift'), 'utf8');
  const m = src.match(/public static let system = """\n([\s\S]*?)\n\s*"""/);
  return m ? m[1].replace(/^ {4}/gm, '') : '(not found)';
}

/** Peter's templates, as SayForms.swift writes them: the title, then its sentence or its lines. */
function templates() {
  const src = fs.readFileSync(path.join(peterRepo, 'Sources/PeterCore/Say/SayForms.swift'), 'utf8')
    .replace(/\\\(something\)/g, '{something you asked for}')
    .replace(/\\\(anApp\)/g, '{an app}')
    .replace(/\\\(place\)/g, '{what of yours, like my memory}')
    .replace(/whenBlank/g, '"when: in 20 minutes, at 17:30, tomorrow 8am, Friday 9:00"');
  const out = [];
  for (const m of src.matchAll(/SayForm\("([^"]+)",\s*(?:"((?:[^"\\]|\\.)*)"(?:,\s*\n?\s*also: \[([^\]]*)\])?|fields: \[([\s\S]*?)\],\s*\n?\s*(?:words|about))/g)) {
    const [, title, sentence, also, fields] = m;
    if (sentence !== undefined) {
      // Other ways of saying it: the matcher takes them too, though the reader is shown only the first.
      const more = [...(also || '').matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((x) => x[1].replace(/\\"/g, '"'));
      out.push(`${title}\n  ${sentence.replace(/\\"/g, '"')}${more.length ? `\n  (also matched by its words: ${more.map((x) => `"${x}"`).join(', ')})` : ''}`);
      continue;
    }
    const lines = [...fields.matchAll(/\.init\("([^"]+)"(?:,\s*"((?:[^"\\]|\\.)*)")?(?:,\s*choices: ([\w.]+))?([^)]*)\)/g)].map(([, label, hint, choices, rest]) => {
      const opt = /optional: true/.test(rest) ? ' (optional)' : '';
      if (choices) return `- ${label}: [${choicesOf(choices).join(' | ')}]${opt}`;
      return `- ${label}: {${(hint || label).replace(/\\"/g, '"')}}${opt}`;
    });
    out.push([title, ...lines].join('\n'));
  }
  // The folder's scripts and flows: the examples that ship with Tool Mac Tool Run, and one of the person's.
  const ex = src.match(/static let exampleSay[\s\S]*?\[([\s\S]*?)\n {4}\]/)[1];
  for (const m of ex.matchAll(/"([^"]+)": \["([^"]+)"/g)) {
    const name = path.basename(m[1]).replace(/\.\w+$/, '').replace(/[-_]/g, ' ');
    out.push(`${name[0].toUpperCase()}${name.slice(1)}${m[1].endsWith('.flow') ? ' (a flow)' : ''} (runs on the Mac once the person there OKs it)\n  ${m[2]}`);
  }
  out.push('Nightly backup (runs on the Mac once the person there OKs it)\n  run the nightly backup');
  return out.join('\n\n');
}

function choicesOf(name) {
  if (name === 'categories') return ['PEOPLE', 'ORGANIZATIONS', 'EVENT-DATES', 'BIRTHDAYS', 'LOCATIONS', 'IDEAS', 'LEVERAGE', 'STRATEGIES', 'OTHERS'];
  if (name === 'When.Repeat.choices') return ['every day', 'every weekday', 'every week', 'every month', 'every hour', 'every 30 minutes'];
  return [name];
}

/** How Peter answers, from Peter.swift and SayWords.swift: the shapes a script writes. */
const ANSWERS = `How Peter answers (Peter.swift, SayWords.swift). His answers are written by a script, never by a model, in these shapes only:
- In this order, he tries: (1) the labeled shape (a title line, then "- label: value" lines) matched to a template by its title or its labels; (2) something for later said in a sentence ("remind me in 20 minutes to …", "remind me at 17:30: …", "every weekday at 8am, …"), read by its words; (3) the closest one-sentence template; (4) a title alone (0.85 close): "Fill in the blanks and say it back:" and the template; (5) his reader (the model, below) when nothing matched closely, two fit about as well and one changes something, or the closest fits only loosely; (6) else "These can do that:" and up to 5 numbered templates, then "Fill one in and say it back." (a question gets "Search the web" second). Nothing at all: "I don't know how to do that yet."
- How a one-sentence template matches (SayMatch.match): its fixed words are found in order, the first at the very start of what was said; a blank takes everything between them, and a blank at the end takes ALL the rest of the message, whatever it says. Fixed words at the end must end the message. So "search the web for X, then open the first one" is a web search for "X, then open the first one", and "read the note groceries and tell me what's on it" reads a note called "groceries and tell me what's on it". Peter never splits a message into several requests, and never says what part he ignored. A template that changes something matched with few fixed words is still done.
- His reader's top suggestion, complete and at least 0.75 sure: done, and the answer starts "Taken as: <what it filled in>" then a blank line, then the answer. Less sure: "It sounds like: <meaning>.\\nYou might mean:\\n1. <title>\\n     <filled>…\\nNothing was done. Say one of them back (filled in, changed if need be)." and its question, if it has one.
- A close match that would change something, but not certainly: "Did you mean: <Title> (<values>)? Nothing was done. To do it, say it like this:\\n\\n<the template filled in>".
- A labeled template with a line missing: "That needs <labels> too. Here it is to fill in:" and the template; a choice that isn't one: "<Label> is one of a, b, c; "<given>" isn't one of them."; a label it doesn't have: "<Title> has no line called "<label>". Its lines:".
- Search the web: "The web has these for "<q>":\\n1. <title>\\n   <url>\\n   <snippet>\\n2. …"; nothing: "Nothing came up on the web for "<q>"."
- Read a page: its title, then its text; Find words on a page: "The lines of <url> with "<words>":" and those lines (none: says so).
- Open a page in Chrome: "Opened in your own Chrome window, side by side with the person's. <the page's title and its first words>".
- Notes: "The note <name>:\\n<text>", "The note <name> is empty.", "There's no note called <name>." (a failure), "Added that to the end of the note <name>." / "Started a new note, <name>, with that.", "Wrote a new note, <name>.", "Wrote the note <name> (what was in it before was replaced)."
- MEMORY: "Remembered under PEOPLE: <about>.", "What's known about <name>:\\n- …", "Nothing is remembered about <name> yet."
- A script or flow (anything marked "runs on the Mac once the person there OKs it"): nothing runs yet; "Asked for <what>. I'll tell you how it goes." When it's over (later, by itself): "Meanwhile: <What> finished (it worked). It printed: …" / "… didn't run: it was turned down on the Mac." / "… didn't run: no one OK'd it on the Mac in time. Say it again to try again."
- Remind me / Do something later: "Set for <today at 21:40> (in 20 minutes): <what>. Its number is <n>. I'll tell you then." (later: "… I'll do it then, and tell you how it went."). A "when" it can't read: "I couldn't read when ("<when>"). Say it like: in 20 minutes, at 17:30, tomorrow 8am, Friday 9:00, or 2026-10-30 14:00." and the template. When it's due, by itself: "Meanwhile: Reminder (Scheduled <when it was set>, number <n>): <message>" or "Meanwhile: Done as scheduled (…): <what>\\n<the answer to it>".
- What's scheduled: "Scheduled, the soonest first:\\n<n>. <when> (<in …>): <what>"; nothing: "Nothing is scheduled.". Cancel: "Taken off the schedule: <n>. <what>."; one it can't tell: "I can't tell which of these "<phrase>" is: say its number." and the list.
- "yes", "no", "ok", "sure", "go ahead" alone: "I keep no conversation, so a "yes" on its own is nothing to me. Say the whole request, as you'd like it done." "more", "the rest", "continue": "I keep no conversation, and every answer comes whole. To see what something you asked for gave back, say "show me {something you asked for}"."
- Stop / what happened to / show me {something you asked for}: about one of this client's requests, by its number or words; one he can't tell: "I can't tell which request that is."
- A tool that fails: the failure in a plain sentence (no JSON, no routes), then his reader is asked why; if it has another way, he tries it once: "<the failure>\\nTried instead: <what>\\n\\n<that answer>".
- After the answer he may add "You can also say:" and one or two of the templates that follow from it (Search the web → Read a web page, Open a page in Chrome; Read a note → Add to a note, Write a note; Remind me → What's scheduled; a run → What happened).
- News that came in since the client last spoke, and that he couldn't call it back with, comes first: "Meanwhile: …", then a blank line.
- He keeps no conversation: each message is read alone. What he does keep: the client's requests (numbered, for "stop", "what happened to", "show me"), the runs he follows, the schedule.`;

async function main() {
  const [what, a, b] = process.argv.slice(2);
  if (what === 'superface') return console.log(await superface(a));
  if (what === 'peter') {
    return console.log(`${ANSWERS}\n\n=== His reader's instructions (SayTranslator.system), for when the words alone don't settle it ===\n\n${readerPrompt()}\n\n=== His templates (SayForms.swift, and the folder's scripts and flows) ===\n\n${templates()}`);
  }
  if (what === 'user' || what === 'from-peter') {
    const { userMessage, peterMessage } = await face('prompt.mjs');
    const at = b ? Date.parse(b) : Date.now();
    return console.log(what === 'user' ? userMessage(a, { at, model: MODEL, how: 'said' }) : peterMessage(a, { at, model: MODEL }));
  }
  console.error('superface [notes.json] | peter | user "text" [at] | from-peter "text" [at]');
  process.exit(2);
}

main();
