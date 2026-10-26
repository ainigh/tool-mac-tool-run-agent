#!/usr/bin/env node
// What a simulated exchange between Super Face's model and Peter's model is built from, taken
// from the code of the three apps (nothing here is written by hand, so it doesn't drift):
//
//   node scripts/simulate/prompts.mjs superface [notes.json]   Super Face's system prompt, exactly as
//                                                              src/main/prompt.mjs builds it
//   node scripts/simulate/prompts.mjs peter                    Peter's model's instructions (Agent.swift,
//                                                              with Tool Mac Tool Run's guide) and its tools
//   node scripts/simulate/prompts.mjs user "text" [at]         a message from the user, as Super Face's model gets it
//   node scripts/simulate/prompts.mjs from-peter "text" [at]   one from Peter, as Super Face's model gets it
//   node scripts/simulate/prompts.mjs to-peter "text" [at]     a message to Peter, as his model gets it
//
// The other checkouts are looked for beside this one (../JUST-super-mac-tts-ONLY-service,
// ../tool-mac-tool-run), or where SUPER_FACE and TOOL_MAC say. notes.json is what Super Face reads
// from its space in Storage Spaces: {"instructions": "- …", "playbook": ["- …"]}.
// See "docs/Simulated exchange - Super Face and Peter.md" for how they're used.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const peterRepo = path.resolve(here, '../..');
const faceRepo = path.resolve(process.env.SUPER_FACE || path.join(peterRepo, '../JUST-super-mac-tts-ONLY-service'));
const toolMacRepo = path.resolve(process.env.TOOL_MAC || path.join(peterRepo, '../tool-mac-tool-run'));
const MODEL = process.env.MODEL || 'qwen3:8b';
const at = (s) => (s ? Date.parse(s) : process.env.NOW ? Date.parse(process.env.NOW) : Date.now());

async function face(file) {
  return import(pathToFileURL(path.join(faceRepo, 'src/main', file)).href);
}

async function superface(notesFile) {
  const { systemPrompt } = await face('prompt.mjs');
  const { Notes } = await face('notes.mjs');
  const notes = new Notes({});
  if (notesFile) Object.assign(notes, JSON.parse(fs.readFileSync(notesFile, 'utf8')));
  return systemPrompt({ character: { name: process.env.CHARACTER || 'Ava' }, model: MODEL, peter: { reachable: true }, notes, now: at() });
}

/** A Swift string literal's text. */
const unquote = (s) => s.replace(/\\"/g, '"').replace(/\\\((\w+)\)/g, '{$1}');

/** Peter's model's instructions, as Agent.swift writes them, with Tool Mac Tool Run's guide after. */
function instructions() {
  const agent = fs.readFileSync(path.join(peterRepo, 'Sources/PeterCore/Agent.swift'), 'utf8');
  const forgetful = agent.match(/static let forgetful = "((?:[^"\\]|\\.)*)"/)[1];
  let out = agent.match(/var out = """\n([\s\S]*?)\n\s*"""/)[1].replace(/^ {8}/gm, '').replace(/\\\(forgetful\)/g, unquote(forgetful));
  const guide = [...toolsSource().match(/public static let guide: \[String\] = \[([\s\S]*?)\n {4}\]/)[1].matchAll(/^\s*"((?:[^"\\]|\\.)*)",?$/gm)].map((m) => unquote(m[1]));
  if (guide.length) out += `\n\nAbout Tool Mac Tool Run's tools:\n${guide.map((g) => `- ${g}`).join('\n')}`;
  return out;
}

function toolsSource() {
  return fs.readFileSync(path.join(toolMacRepo, 'Sources/RunCore/API/ToolsAPI.swift'), 'utf8');
}

/** The tools his model is given: Tool Mac Tool Run's (GET /api/tools; not say, which is Peter's), then his own. */
function tools() {
  const src = toolsSource();
  const list = src.slice(src.indexOf('public static let all: [Tool] = ['), src.indexOf('public static let guide'));
  const out = [];
  const starts = [...list.matchAll(/^ {8}Tool\("(\w+)", "((?:[^"\\]|\\.)*)"/gm)];
  starts.forEach((m, i) => {
    const [, name, description] = m;
    if (name === 'say') return;
    const body = list.slice(m.index, starts[i + 1]?.index ?? list.length);
    const args = [...body.matchAll(/Arg\("(\w+)", "(\w+)", "((?:[^"\\]|\\.)*)"(, required: true)?/g)].map(([, n, t, about, req]) => `    ${n} (${t}${req ? ', required' : ''}): ${unquote(about)}`);
    const asks = /asks: true/.test(body.slice(0, body.indexOf(') {') > 0 ? body.indexOf(') {') : body.length)) ? ' [waits for the person to click Run on the Mac]' : '';
    out.push(`- ${name}${asks}: ${unquote(description)}${args.length ? `\n${args.join('\n')}` : ''}`);
  });
  // His own (Agent.swift's `own`).
  const agent = fs.readFileSync(path.join(peterRepo, 'Sources/PeterCore/Agent.swift'), 'utf8');
  const choices = fs.readFileSync(path.join(peterRepo, 'Sources/PeterCore/When.swift'), 'utf8').match(/static let choices = \[([^\]]*)\]/)[1].replace(/"/g, '');
  const own = agent.slice(agent.indexOf('static let own')).replace(/\\\(When\.Repeat\.choices\.joined\(separator: ", "\)\)/g, choices);
  for (const m of own.matchAll(/Brain\.Tool\(name: "(\w+)",\s*description: "((?:[^"\\]|\\.)*)",[\s\S]*?"properties": \[([\s\S]*?)\] as \[String: Any\]\]\)/g)) {
    const args = [...m[3].matchAll(/"(\w+)": (?:choice|string)\("((?:[^"\\]|\\.)*)"|"(\w+)": \["type": "(\w+)", "description": "((?:[^"\\]|\\.)*)"\]/g)].map((a) =>
      a[1] ? `    ${a[1]}: ${unquote(a[2])}` : `    ${a[3]} (${a[4]}): ${unquote(a[5])}`,
    );
    out.push(`- ${m[1]} (Peter's own): ${unquote(m[2])}\n${args.join('\n')}`);
  }
  return out.join('\n');
}

/** "Sunday 25 October 2026, 21:40 (UTC-05:00)", as Agent.swift's stamp() writes it. */
function stamp(ms) {
  const d = new Date(ms);
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const off = -d.getTimezoneOffset();
  const p = (n) => String(n).padStart(2, '0');
  return `${days[d.getDay()]} ${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear()}, ${p(d.getHours())}:${p(d.getMinutes())} (UTC${off >= 0 ? '+' : '-'}${p(Math.floor(Math.abs(off) / 60))}:${p(Math.abs(off) % 60)})`;
}

async function main() {
  const [what, a, b] = process.argv.slice(2);
  if (what === 'superface') return console.log(await superface(a));
  if (what === 'peter') {
    return console.log(`=== Peter's model's instructions (Agent.swift, Peter.instructions) ===\n\n${instructions()}\n\n=== His tools (at most 8 rounds of calls for one request; a tool's answer is JSON, cut at 8,000 characters) ===\n\n${tools()}`);
  }
  if (what === 'to-peter') return console.log(`From: ${process.env.CLIENT || 'Super Face'}\nNow: ${stamp(at(b))}\n\n${a}`);
  if (what === 'user' || what === 'from-peter') {
    const { userMessage, peterMessage } = await face('prompt.mjs');
    return console.log(what === 'user' ? userMessage(a, { at: at(b), model: MODEL, how: 'said' }) : peterMessage(a, { at: at(b), model: MODEL }));
  }
  console.error('superface [notes.json] | peter | user "text" [at] | from-peter "text" [at] | to-peter "text" [at]');
  process.exit(2);
}

main();
