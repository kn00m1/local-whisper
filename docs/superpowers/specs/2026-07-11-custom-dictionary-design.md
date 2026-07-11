# Custom Dictionary + Auto-Seeded Whisper Prompt (Accuracy Loop v1)

**Date:** 2026-07-11
**Status:** Approved design
**Branch:** `feat/custom-dictionary` (stacks on `feat/edit-mode-review-overlay`, PR #3)
**Lineage:** First slice of the "Phase 2" direction named in
`2026-06-23-edit-mode-review-overlay-design.md` — feeding the whisper prompt /
custom dictionary from accumulated usage.

## Summary

Usage data (193 dictations in `history.json`) shows 84% of dictations target
Terminal — mostly technical prompts whisper mishears ("qn 3" for qwen3,
"visper" for whisper, "cloud.md" for CLAUDE.md). The whisper `--prompt`
vocabulary feature existed but was unused, and there was no deterministic
fix-up layer at all.

This adds a user dictionary (`~/.thinking-out-loud/dictionary.json`) with:

1. **`replacements`** — deterministic post-STT corrections, applied in
   `postProcess` on the final transcription.
2. **`vocabulary`** — terms merged into whisper's `--prompt` (with replacement
   values included automatically), biasing recognition for both live partials
   and finals.
3. A menubar **Edit Dictionary** item that creates the file from a template on
   first use and opens it in the default text editor.
4. One-time seeding mined from history (personal file, not committed).

Out of scope for v1 (deliberate): audio retention / re-transcribe, a reusable
mining script, dashboard UI — those belong to the Phase 2 learning engine.

## Design decisions

- **Insertion point**: `Dictionary.apply` runs inside `postProcess`, after
  filler removal + space collapse and after first-letter capitalization, so a
  replacement's canonical casing always wins — even at sentence start
  (matching is case-insensitive, so pre-capitalization never prevents a hit).
  Corrections propagate to refine input, voice-command matching, insertion,
  and history's `text` field. Partials never run `postProcess`, so
  replacements are finals-only; the merged prompt still biases partials.
- **Matching semantics**: case-insensitive, whole-word/phrase, literal keys
  (never Lua patterns — `c++` is safe), longest key wins, values inserted
  verbatim and never rescanned (`{a→b, b→a}` cannot loop). Word boundaries are
  byte-wise ASCII, mirroring the `%f[%w]` filler-pattern semantics; a boundary
  is only required on sides where the key edge is itself a word byte.
- **Prompt merge**: `Dictionary.mergePrompt` builds
  `vocabulary, values. user-prompt-text` capped at 600 chars. whisper.cpp keeps
  only the LAST `n_text_ctx/2` (~224) tokens of an over-long prompt (verified
  in `whisper.cpp` source), so user free text goes last and is never trimmed;
  overflow drops replacement values before explicit vocabulary.
- **Config style**: read-on-demand per dictation (same policy as the `prompt`
  file) — no cache, no reload item. Invalid JSON logs
  `dictionary: invalid JSON` and passes text through unchanged.
- **Local-count budget**: init.lua sits near Lua's 200-local ceiling; the
  feature adds exactly 2 top-level locals (`isWordByte`, the `Dictionary`
  namespace table).
- **Testability**: pure logic lives between `-- @dictionary-start` /
  `-- @dictionary-end` markers, extracted and run by
  `tests/test_dictionary.lua` under plain `lua` (5.5-clean), mirroring the
  `@collapse` marker convention.

## Files

- `hammerspoon/init.lua` — P table entry, marker-delimited Dictionary block,
  `Dictionary.load`/`TEMPLATE` glue, `postProcess` hook, `getPromptArgs`
  merge, menubar item
- `hammerspoon/dictionary.example.json` — template (installed by `install.sh`
  when missing)
- `tests/test_dictionary.lua` — 23 unit cases (replacement semantics, parse
  validation, prompt-merge budget/dedupe/ordering)
- `README.md` — "Custom dictionary & vocabulary" section

## Verification

- `lua tests/test_dictionary.lua` → 23/23; `lua tests/test_collapse.lua`
  regression → 10/10.
- Hammerspoon reload clean; menubar shows Edit Dictionary.
- Live E2E: dictation containing a seeded mis-hear (e.g. "qn 3") shows the raw
  form in the log's `final:` line but the corrected form in inserted text and
  the newest `history.json` entry.
