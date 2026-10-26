#!/usr/bin/env node
// Super Face's harness, for a simulated conversation: what src/main/assistant.mjs does between
// its model and Peter, done with Super Face's own code (calls.mjs, prompt.mjs, peter.mjs) on a
// conversation file ("### user" / "### assistant" blocks, as the model's history has them).
//
//   node scripts/simulate/harness.mjs user  conv.md "what the user said" [at]
//   node scripts/simulate/harness.mjs model conv.md answer.txt     the model's answer (anything after a line "=====" is dropped)
//   node scripts/simulate/harness.mjs peter conv.md answer.txt [at] Peter's answer to the message the model sent
//   node scripts/simulate/harness.mjs news  conv.md "Meanwhile: …" [at]   Peter calling back by himself
//
// `model` prints what happened as JSON: the message for Peter (the first one only, as the app
// sends it), what was said aloud, and the note the app adds when it nudges. What a request has
// been through so far (messages to Peter, failures, nudges) is kept beside the conversation, in
// conv.md.json. Set MODEL (qwen3:8b) and TZ as for prompts.mjs.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const faceRepo = path.resolve(process.env.SUPER_FACE || path.join(here, '../../../JUST-super-mac-tts-ONLY-service'));
const load = (f) => import(pathToFileURL(path.join(faceRepo, 'src/main', f)).href);
const { addressed, isSilent, looksLikeCall, messages, words } = await load('calls.mjs');
const { NOTE, claimsInability, peterMessage, promisesWork, userMessage } = await load('prompt.mjs');
const { troubled } = await load('peter.mjs');

const MODEL = process.env.MODEL || 'qwen3:8b';
const MAX_ROUNDS = 10;
const KEEP_REPLY = 600;

const [cmd, conv, arg, when] = process.argv.slice(2);
const at = when ? Date.parse(when) : Date.now();
const stateFile = `${conv}.json`;
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : {};
const blocks = fs.existsSync(conv)
  ? fs.readFileSync(conv, 'utf8').split(/^### /m).filter(Boolean).map((b) => ({ role: b.slice(0, b.indexOf('\n')).trim(), content: b.slice(b.indexOf('\n') + 1).trim() }))
  : [];

function save() {
  fs.writeFileSync(conv, blocks.map((b) => `### ${b.role}\n${b.content}\n`).join('\n'));
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
}

/** A new request: what it has been through starts again, and Peter's earlier answers are folded (assistant.mjs fold()). */
function newTurn() {
  Object.assign(state, { calls: 0, failures: 0, rounds: 0, nudged: [], pending: null });
  for (const b of blocks) {
    const head = b.content.match(/^\[Peter, [^\]]*\] @\S+ /);
    if (b.role !== 'user' || !head) continue;
    const body = b.content.slice(head[0].length);
    if (body.length > KEEP_REPLY) b.content = `${head[0]}${body.slice(0, KEEP_REPLY)}… (cut short)`;
  }
}

const text = (a) => (fs.existsSync(a) ? fs.readFileSync(a, 'utf8') : String(a ?? ''));
const out = {};

if (cmd === 'user' || cmd === 'news') {
  newTurn();
  blocks.push({ role: 'user', content: cmd === 'user' ? userMessage(text(arg).trim(), { at, how: 'said', model: MODEL }) : peterMessage(text(arg).trim(), { at, model: MODEL }) });
} else if (cmd === 'model') {
  const answer = text(arg).split(/^=====\s*$/m)[0].trim();
  const found = messages(answer);
  const said = words(answer);
  blocks.push({ role: 'assistant', content: answer });
  out.said = said;
  if (!found.length) {
    // nudgeFor(): once each, while nothing's been asked of Peter for this request.
    const once = (key, note) => (state.nudged.includes(key) ? null : (state.nudged.push(key), note));
    let nudge = null;
    if (looksLikeCall(answer)) nudge = once('json', NOTE.json);
    else if (!state.calls && !isSilent(said) && promisesWork(said) && !/\?\s*$/.test(said)) nudge = once('promised', NOTE.promised);
    else if (!state.calls && claimsInability(said)) nudge = once('cannot', NOTE.cannot);
    if (nudge) {
      blocks.push({ role: 'user', content: nudge });
      out.nudge = nudge;
    } else {
      // Addressed to no one: kept as it should have been written.
      if (said && !addressed(answer)) blocks[blocks.length - 1].content = `@user ${answer}`;
      out.done = true;
    }
  } else {
    state.calls++;
    state.pending = { more: found.length > 1 };
    out.toPeter = found[0].text;
    if (!found[0].text) out.empty = NOTE.empty();
  }
} else if (cmd === 'peter') {
  let reply = text(arg).split(/^=====\s*$/m)[0].trim();
  const failed = troubled(reply);
  if (failed) state.failures++;
  if (state.pending?.more) reply += `\n\n${NOTE.onlyFirst()}`;
  state.rounds++;
  if (failed && state.failures <= 2) reply += `\n\n${NOTE.review}`;
  if (state.rounds >= MAX_ROUNDS) reply += `\n\n${NOTE.outOfRounds(MAX_ROUNDS)}`;
  state.pending = null;
  blocks.push({ role: 'user', content: peterMessage(reply, { at, model: MODEL }) });
  out.failed = failed;
} else {
  console.error('user|model|peter|news conv.md text|file [at]');
  process.exit(2);
}
save();
console.log(JSON.stringify(out));
