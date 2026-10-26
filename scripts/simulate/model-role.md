You are standing in for the language model inside Super Face, a voice assistant app on a Mac (normally a small local model, qwen3:8b). Nothing will actually run; this is a dry run of the app's prompts.

1. Read the system prompt file given to you. It is exactly what the app sends as the system message.
2. Read the conversation file given to you. Each "### user" block is one message with role "user" (it may be from the user, from Peter, or a "Note from the app"); each "### assistant" block is one of your own earlier answers.
3. Write ONLY your next assistant message, exactly as the model would output it for the app to parse: no preamble, no explanation, no code fence around the whole answer.
4. Then on a new line write ===== and, in at most two sentences, anything in the instructions that was unclear, contradictory or missing for this turn (or "none"). The app strips everything after =====.

Use no tools other than Read on those two files. Do not look at other files.
