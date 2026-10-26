#!/usr/bin/env node
// A simulated conversation (the file a stand-in for Super Face's model reads: "### user" and
// "### assistant" blocks, as the app's history has them) as a chat to read: who said what, what
// was said aloud, what went to Peter, and the app's own notes.
//   node scripts/simulate/transcript.mjs conversation.md > transcript.md
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8');
const blocks = src.split(/^### /m).filter(Boolean).map((b) => { const nl = b.indexOf('\n'); return { role: b.slice(0, nl).trim(), text: b.slice(nl + 1).trim() }; });
const out = [];
let day = '';
const q = (s) => s.split('\n').map((l) => '> ' + l).join('\n');
for (const b of blocks) {
  if (b.role === 'assistant') {
    if (!b.text) { out.push('**qwen3** _(an empty answer: nothing said, nothing sent)_'); continue; }
    const i = b.text.search(/^@peter/m);
    const toUser = i < 0 ? b.text : b.text.slice(0, i).trim();
    const toPeter = i < 0 ? '' : b.text.slice(i).trim();
    const spoken = toUser.replace(/^@user\s*/, '');
    if (/^nothing\W*$/i.test(spoken)) out.push('**qwen3** _(says nothing: `@user nothing`)_');
    else if (spoken) out.push(`**qwen3** (said aloud):\n${q(spoken)}`);
    if (toPeter) out.push(`**qwen3 → Peter** (a rising tone, not said):\n\`\`\`\n${toPeter}\n\`\`\``);
    continue;
  }
  const parts = b.text.split(/\n\n(?=Note from the app)/);
  const m = parts[0].match(/^\[(the user|Peter), (?:[^,\]]*?, )?(\w+day \d+ \w+ \d{4}), ([\d:]+) \(UTC[^\]]*\)\] @\S+ ([\s\S]*)$/);
  // The day, when it isn't the one before.
  const when = m ? (m[2] !== day ? `${m[2]}, ${m[3]}` : m[3]) : '';
  if (m) day = m[2];
  if (m && m[1] === 'the user') out.push(`**You** (${when}):\n${q(m[4])}`);
  else if (m) out.push(`**Peter** (${when}, a falling tone, not said):\n\`\`\`\n${m[4]}\n\`\`\``);
  else out.push(`**App note**: _${parts[0]}_`);
  if (parts[1]) out.push(`**App note** (added by Super Face): _${parts[1].trim()}_`);
}
console.log(out.join('\n\n'));
