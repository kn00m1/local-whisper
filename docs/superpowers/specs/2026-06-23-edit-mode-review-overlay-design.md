# Edit Mode — Review-and-Edit Overlay (Phase 1)

**Date:** 2026-06-23
**Status:** Approved design, pre-implementation
**Branch:** `feat/edit-mode-review-overlay`

## Summary

Today, a dictation transcribes → refines → **auto-pastes** at the cursor, then the
overlay lingers ~2s and hides. This feature adds an opt-in **edit mode**: instead of
auto-pasting, the overlay becomes a **persistent, fully editable textbox** showing the
refined text, with **Copy** and **Paste** buttons. The user can correct the text before
it leaves the box, and a record of `raw whisper → refined → user edit` is stored for a
future learning pass.

This is **Phase 1 of 2**. Phase 1 = the edit/copy UI + capturing the three text
versions. **Phase 2 (a separate, later spec)** = analyzing the accumulated diffs to feed
the whisper `prompt` (custom dictionary) and the refine prompt. Phase 1's only obligation
to Phase 2 is the **data model**: persist all three strings so either diff is computable
later.

## Goals

1. An **edit mode** toggle (menubar item + config flag) that, when ON, routes every
   dictation into the editable box instead of auto-pasting.
2. When edit mode is OFF (default), preserve today's auto-paste — but add a **1s grace
   window** during which a single click on the box cancels the paste and switches that one
   dictation into the editable flow ("click to edit").
3. The editable box is a **proper, full-size textbox** that grows (window included) to fit
   the entire transcript, not a fixed scrolling card.
4. **Copy** (→ clipboard, box stays open) and **Paste** (→ insert into the app recorded
   from, then close) buttons, plus an explicit **close** (✕ / Esc) that pastes nothing.
5. Persist `raw whisper / refined / user-edited` per edit-mode dictation, plus how the
   text left the box (`pasted` / `copied` / `dismissed`).

## Non-goals (YAGNI — explicitly out of scope for Phase 1)

- Any analysis of the captured diffs (word frequency, mistranscription detection,
  dictionary/prompt generation). That is Phase 2.
- Changing the whisper `prompt` or refine prompt files.
- Editing during recording/streaming. The box is **read-only** until the final transcript
  (post-refine, or post-transcription if refine is off) is ready.
- Rich text, formatting, or markdown in the editor. Plain text only.
- Touching meeting mode (`meetingNotepad`) or the dashboard flows.

## Terminology

- **Edit mode** — the persistent boolean toggle (`~/.thinking-out-loud/edit_mode`).
- **Ready state** — the moment the final transcript exists (refine done, or transcription
  done if refine off). This is the fork point: auto-paste vs editable box.
- **Editable state** — the box is `contenteditable`/textarea, owned by the user, buttons
  shown, window grown to fit, no auto-hide.
- **Grace window** — in OFF mode, the short interval (default 1s) before auto-paste fires,
  during which a click converts to editable state.

## Configuration

Two new small config files in `~/.thinking-out-loud/`, mirroring the existing
`refine`/`enter` accessor pattern (`getRefineMode`/`setRefineMode`/`cycleRefine`,
init.lua:195–211):

| File | Accessor | Default if unset | Meaning |
|---|---|---|---|
| `edit_mode` | `getEditMode` / `cycleEditMode` | `off` | route dictations to the editable box |
| `grace` | `getGraceWindow` | `1.0` (seconds) | OFF-mode delay before auto-paste; click-to-edit window |

Path constants go in the existing `P` table (`P.editModeFile`, `P.graceFile`).

**Menubar:** add an "Edit mode: ON/OFF" item next to the Refine item (init.lua ~1495),
`fn = function() cycleEditMode(); updateMenuBar() end`.

## State machine

```
recording ──► transcribing ──► refining ──► READY
   (read-only card, live partials / status text throughout)
                                              │
                  ┌───────────────────────────┴───────────────────────────┐
            edit_mode ON                                            edit_mode OFF
                  │                                                         │
            EDITABLE state                                   start grace timer (1s),
        (box editable, buttons,                              box read-only, shows text
         window grown, no autohide)                                        │
                  │                                          ┌─────────────┴─────────────┐
                  │                                    untouched                   click on box
        Copy / Paste / Close                               │                            │
                                                     auto-paste at                cancel timer →
                                                     timer expiry →               EDITABLE state
                                                     record history               (same as ON)
                                                     (output=pasted), hide
```

Key point: **OFF-untouched** is behaviorally today's insert path, merely **deferred by the
grace timer** instead of firing instantly at `finishInsertion`.

## The editable textbox (sizing mechanism)

Two caps must move together to let the box grow to the full transcript:

1. **CSS:** in editable state the editor sheds `max-height: 160px` / `overflow-y: auto`
   (overlay.html:29–30) and auto-grows to its content height.
2. **The window:** the overlay is a fixed `400×220` macOS `hs.webview` (init.lua:1029–1030).
   Content cannot overflow its window, so **Lua must resize the overlay window** when the
   box grows.

**Mechanism:**
- Editable element is a real `<textarea>` (chosen over `contenteditable` for native
  selection/undo and a clean plain-text `.value` that Copy/Paste/history consume directly).
- On entering editable state, the streaming `.transcript-card` hands off: its text
  populates the `<textarea>`, the card hides, the textarea shows. Lua stops calling
  `setTranscript()` (it would fight the user's cursor) — **ownership of that text moves from
  Lua to the user.**
- JS measures the textarea's `scrollHeight` and reports a desired total window height back
  to Lua over the message channel (`{action:"resize", h:<px>}`). Lua resizes the overlay
  frame to fit and **re-clamps it on-screen** (grows upward from the current bottom; shift
  if it would clip the top/bottom).
- The textarea auto-grows on `input` (debounced re-report) so adding/removing lines keeps
  the window fit.
- **Screen ceiling:** the window grows freely up to ~70% of the screen height; beyond that
  the textarea scrolls internally so buttons never leave the screen.

## JS ↔ Lua message protocol

Attach an `hs.webview.usercontent` controller to the overlay (mirroring the dashboard,
init.lua:1276–1301) so JS can message Lua. `overlay:allowTextEntry(true)` is set when
entering editable state (it grabs keyboard focus — intended here, since the user is now
typing in the box).

Messages JS → Lua:

| action | payload | Lua behavior |
|---|---|---|
| `resize` | `h` (px) | resize overlay window to fit, re-clamp on screen |
| `copy` | `text` | `hs.pasteboard.setContents(text)`; mark the pending record as copied; box stays open; JS flashes "Copied ✓" |
| `paste` | `text` | set clipboard → reactivate `capturedAppBundleID` → `Cmd+V` (+ optional Enter if enter-mode) → close overlay → **write history** (`output="pasted"`, `edited=text`) |
| `close` | `text` | close overlay → **write history** (`output="copied"` if a `copy` happened this session, else `"dismissed"`; `edited=text`) |
| `editstart` | — | (OFF-mode click-to-edit) Lua cancels the grace timer and flips to editable state |

Lua → JS (extends existing `window.lw` bridge):

| call | purpose |
|---|---|
| `lw.enterEdit(text)` | hand off: populate textarea with `text`, hide card, show buttons, focus, report height |

Keyboard in editable state: **Esc** → `close`, **Cmd+Return** → `paste`. (Plain Enter =
newline.) These are nice-to-haves layered on the buttons, not replacements.

## Insertion flow fork

`finishInsertion(text, detectedLang, preRefineText)` (init.lua:1689) forks on
`getEditMode()`:

At the ready fork, **both** modes first build a **pending record** `{raw, refined, lang,
app, model, time, copied=false}` and do **not** write history yet (the text isn't final
until the terminal action). Then:

- **OFF:** show the read-only card with the final text; start a `getGraceWindow()` timer.
  On expiry → run the existing insert path (`insertTextAtCursor`, optional Enter,
  `lastInsertedText`), write history from the pending record (`output="pasted"`, no
  `edited`), hide. If `editstart` arrives first → cancel timer, enter editable state.
- **ON:** do **not** insert and start no timer. Call `lw.enterEdit(refined)`, set
  `allowTextEntry(true)`, cancel auto-hide. History waits for `paste`/`close`.

History is written **once, at the terminal action** (`paste`/`close`/grace-expiry), never
at `finishInsertion` for edit-mode dictations.

`preRefineText` already carries the raw whisper output when refine ran (init.lua:1692–1694)
— that becomes the `raw` field. When refine is off, raw == refined == the shown text.

## Data model

Extend the history entry (init.lua:1724–1733). Keeps the existing "store only if changed"
convention used for `refined`:

```
text     = raw whisper output            (always; = ctx.originalText)
refined  = LLM output                    (only if refine changed it)        ← existing
edited   = user's final textbox value    (only if it differs from what was shown) ← NEW
output   = "pasted" | "copied" | "dismissed"                                ← NEW
```

- `text → edited` diff = **transcription** misses → Phase 2 feeds the whisper `prompt`.
- `refined → edited` diff = **refine** misses → Phase 2 feeds the refine prompt.
- `output` records how the dictation ended (so Phase 2 can weight, e.g., dismissed entries).

For OFF-untouched dictations: `edited` is absent, `output="pasted"` (identical signal to
today plus the explicit `output`).

## App restore for Paste

Reuse `capturedAppBundleID`, already captured at recording start (init.lua:779). On
`paste`, reactivate that bundle ID then synthesize `Cmd+V` — the same restore trick the
dashboard uses with `dashboardPrevApp` (init.lua:1288–1301). No new state needed.

## Lifecycle / auto-hide

- The 2s `OVERLAY_LINGER` auto-hide (init.lua:1743) must **not** fire in editable state —
  the box persists until `paste`/`close`.
- Auto-hide is **preserved** for: recording/transcribing/refining error overlays, and the
  OFF-untouched grace-expiry path.
- If the overlay is torn down without a terminal action (e.g., a new dictation starts, or
  Hammerspoon reloads) while a pending record exists, write the pending record as a fallback
  (`edited` absent, `output="dismissed"`) so the dictation isn't silently lost.

## Edge cases & risks

- **First-click activation (macOS):** a borderless, non-key floating window may swallow the
  first mouse click to activate itself, so "single click → edit" could land as
  activate-then-edit. **Verify on the real setup during implementation.** Fallbacks if it
  misbehaves: a small always-visible "✎" affordance on the read-only card, or accept a
  double-click. A stray click is harmless (user confirmed) — they can still Paste.
- **`allowTextEntry` toggling live:** confirm `overlay:allowTextEntry(true)` works on a live
  webview; if not, recreate the overlay with the final text in editable state.
- **Empty / hallucination / voice-command text:** unchanged — these short-circuit before
  `finishInsertion` (init.lua:1751, 1761) and never enter edit mode.
- **Refine off + edit mode on:** ready state triggers at transcription completion; box shows
  raw whisper text; `raw == refined`.
- **Enter-after-insert mode:** Paste respects `getEnterMode()` like the current insert path.
- **Window grows off-screen:** re-clamp on every `resize`; cap at ~70% screen height.

## Files to change

- `hammerspoon/init.lua` — config accessors (`getEditMode`/`cycleEditMode`/`getGraceWindow`,
  `P` paths), menubar item, overlay `usercontent` controller + message handler, the
  `finishInsertion` fork, grace timer, editable-state Lua helpers, history schema, auto-hide
  guards.
- `hammerspoon/overlay.html` — `<textarea>` editor + action bar markup, editable/editing CSS
  across all 7 themes, `window.lw.enterEdit`, auto-grow + height reporting, button → message
  wiring, Esc/Cmd+Return handlers.
- `tests/` — no refine-eval change; manual verification per below.
- `.claude/CLAUDE.md` — update "Current state" table once shipped (edit mode, grace).

## Verification

Manual (Hammerspoon auto-reloads; iterate live then `./sync.sh`):
1. Edit mode OFF, untouched → text auto-pastes after ~1s; history entry has `output:"pasted"`,
   no `edited`.
2. Edit mode OFF, click during grace → box becomes a full editable textbox; Copy puts text on
   clipboard; Paste inserts into the original app and closes; history has `edited` + `output`.
3. Edit mode ON → box always opens editable; long transcript grows the window to fit, capped
   at screen; very long → internal scroll, buttons stay visible.
4. Close (✕/Esc) → nothing pastes; history `output:"dismissed"`.
5. Refine on → box shows refined text; history retains raw `text` underneath.
6. Toggle persists across reload (config file written/read).

## Open questions

None blocking. The first-click-activation behavior is the one item to validate empirically
during implementation rather than assume.
