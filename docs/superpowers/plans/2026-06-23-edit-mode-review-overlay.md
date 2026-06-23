# Edit Mode — Review-and-Edit Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in "edit mode" that, instead of auto-pasting a dictation, shows a persistent full-size editable textbox with Copy/Paste buttons, and records `raw whisper / refined / user-edited` text for a future learning pass.

**Architecture:** Reuse the existing overlay `hs.webview` — flip it to editable on final-ready and attach a JS→Lua `usercontent` message channel (the pattern the dashboard already uses at init.lua:1276–1301). The streaming transcript card hands its text to a real `<textarea>` whose measured height is reported back to Lua so the overlay *window* grows to fit. A menubar toggle + config flag gates the behavior; when off, today's auto-paste is preserved but deferred behind a 1s "click-to-edit" grace window.

**Tech Stack:** Lua (Hammerspoon `hs.webview`, `hs.eventtap`, `hs.pasteboard`, `hs.timer`), HTML/CSS/JS (WKWebView), JSON config files in `~/.thinking-out-loud/`.

**Spec:** `docs/superpowers/specs/2026-06-23-edit-mode-review-overlay-design.md`

## Global Constraints

- **No Python anywhere** — pure C/Lua/JS stack. (AGENTS.md)
- **Single-file runtime:** all Lua logic lives in `hammerspoon/init.lua`; overlay markup in `hammerspoon/overlay.html`. Don't add new runtime Lua files for core logic.
- **Config dir is `~/.thinking-out-loud/`** — all new config files go there. New flags: `edit_mode` (`on`/`off`, default off), `grace` (float seconds, default `1.0`).
- **whisper binary is `whisper-cli`**, never `main`. (Not touched here, but don't regress.)
- **Lua 200-local ceiling in the main chunk:** new module-level state must stay lean; consolidate paths in the existing `P` table rather than adding loose locals. (per .claude/CLAUDE.md "Internal layout")
- **Editor visuals are theme-independent dark glass**, mirroring `.transcript-card`'s deliberate "legible over any wallpaper" approach (overlay.html:22–43) — NOT seven per-theme variants. One editor style, one button-bar style.
- **Log prefix stays `whisper-dictate`** for compatibility. Read logs with: `TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR) && tail -40 "${TMPDIR_REAL}whisper-dictate/whisper-dictate.log"`
- **Transcribed text is data, never executed.** (Security, AGENTS.md)

## Dev loop (used by every task's "Deploy & verify" step)

This work edits the **repo** files directly (clean source of truth) and deploys to the live `~/.hammerspoon/` copy for testing. We do **NOT** run `sync.sh` (it would copy the user's personal `pcall(require, "fortknox_reveal")` tail line into the repo). The deploy step re-appends that one personal line so the live config is unchanged apart from our feature.

Paste this helper once per shell session, then call `deploy` after each edit:

```bash
deploy() {
  cp hammerspoon/init.lua  "$HOME/.hammerspoon/init.lua"
  cp hammerspoon/overlay.html "$HOME/.hammerspoon/overlay.html"
  # Re-append the personal extension line that lives only in ~/.hammerspoon (never in repo)
  grep -qxF 'pcall(require, "fortknox_reveal")' "$HOME/.hammerspoon/init.lua" \
    || echo 'pcall(require, "fortknox_reveal")' >> "$HOME/.hammerspoon/init.lua"
  /usr/local/bin/hs -c "hs.reload()" 2>/dev/null || true   # "message port invalidated" is normal; reload still happens
  echo "deployed + reload requested"
}
```

Lua syntax-check before every deploy (catches errors the reload would swallow):

```bash
luac -p hammerspoon/init.lua 2>&1 || echo "SYNTAX ERROR — fix before deploy"
```

If `luac` is unavailable: `/usr/local/bin/hs -c 'print("ok")'` after deploy and watch for load errors in the Hammerspoon console.

**Testing note:** There is no automated Lua test harness in this project; verification is manual (reload → dictate/observe overlay → inspect log + `~/.thinking-out-loud/history.json`). Each task's final step is a concrete manual check with exact expected observations, then a commit.

---

### Task 1: Config accessors + menubar toggle

Adds the `edit_mode` and `grace` config flags and surfaces edit mode as a menubar item. No dictation behavior changes yet — this task is independently verifiable purely through the menubar and the config files.

**Files:**
- Modify: `hammerspoon/init.lua` — `P` table (path constants), config accessors near `getRefineMode` (~init.lua:195–211), menubar builder near the Refine item (~init.lua:1490–1496)

**Interfaces:**
- Produces:
  - `P.editModeFile` (string path), `P.graceFile` (string path)
  - `getEditMode() -> boolean`
  - `setEditMode(on: boolean)`
  - `cycleEditMode()` — flips and persists
  - `getGraceWindow() -> number` (seconds; default 1.0)

- [ ] **Step 1: Add path constants to the `P` table**

Find the `P` table where `refineFile` / `refineModelFile` are defined (search `refineFile =` in the `P = {` block) and add alongside them:

```lua
    editModeFile = configDir .. "/edit_mode",
    graceFile    = configDir .. "/grace",
```

(Use the same `configDir` / concatenation style already used for the neighboring entries — match whatever local the existing lines use.)

- [ ] **Step 2: Add the accessors next to `getRefineMode`**

Immediately after the `cycleRefine` definition (search `cycleRefine`), add:

```lua
-- Edit mode: when on, dictations open an editable review box instead of auto-pasting.
local function getEditMode()
    local f = io.open(P.editModeFile, "r")
    if not f then return false end
    local v = f:read("*l"); f:close()
    return v == "on"
end

local function setEditMode(on)
    local f = io.open(P.editModeFile, "w")
    if f then f:write(on and "on" or "off"); f:close() end
end

local function cycleEditMode()
    setEditMode(not getEditMode())
end

-- Grace window (seconds) before OFF-mode auto-paste; also the click-to-edit window.
local function getGraceWindow()
    local f = io.open(P.graceFile, "r")
    if not f then return 1.0 end
    local v = f:read("*l"); f:close()
    local n = tonumber(v or "")
    if not n or n < 0 then return 1.0 end
    return n
end
```

- [ ] **Step 3: Add the menubar toggle item**

Find the Refine menubar item (search `cycleRefine(); updateMenuBar()`). Add a sibling item just before or after it, matching the surrounding table-entry style:

```lua
        {
            title = "Edit mode: " .. (getEditMode() and "ON" or "OFF"),
            fn = function() cycleEditMode(); updateMenuBar() end,
        },
```

- [ ] **Step 4: Deploy & verify**

```bash
luac -p hammerspoon/init.lua && deploy
```

Then:
1. Click the menubar icon → confirm an **"Edit mode: OFF"** item appears near "Refine".
2. Click it → menu closes. Reopen → it now reads **"Edit mode: ON"**.
3. Confirm the file: `cat ~/.thinking-out-loud/edit_mode` → prints `on`.
4. Toggle back to OFF; `cat ~/.thinking-out-loud/edit_mode` → `off`.
5. `cat ~/.thinking-out-loud/grace 2>/dev/null || echo "(absent → defaults to 1.0)"` — absent is fine.

Expected: toggle persists to disk and the title reflects state. Dictation still auto-pastes exactly as before (unchanged path).

- [ ] **Step 5: Commit**

```bash
git add hammerspoon/init.lua
git commit -m "feat(edit-mode): add edit_mode + grace config flags and menubar toggle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Overlay markup — editable textarea + action bar (presentational)

Adds the editable `<textarea>`, the Copy/Paste/✕ action bar, their theme-independent styling, and the `window.lw.enterEdit()` DOM-handoff + auto-grow + height-reporting JS. Buttons post messages to a `lw` message handler that Lua wires up in Task 3 — so here they're verifiable visually but inert.

**Files:**
- Modify: `hammerspoon/overlay.html` — `<body>` markup (after the `.transcript-card`/`.overlay` block, ~overlay.html:286–291), CSS (new block before the per-theme sections), and the `window.lw` script object (~overlay.html:294–359)

**Interfaces:**
- Consumes: existing `window.lw` bridge object, `.transcript-card` element
- Produces (JS, called by Lua in later tasks):
  - `window.lw.enterEdit(text)` — populate textarea with `text`, hide card, reveal action bar, focus, report height
  - `window.lw.flashCopied()` — brief "Copied ✓" affordance
  - Outbound messages via `window.webkit.messageHandlers.lw.postMessage({action, text, h})` with actions: `resize`, `copy`, `paste`, `close`, `editstart`

- [ ] **Step 1: Add the editor + action-bar markup**

In `<body>`, replace the block (overlay.html:286–291) so the editor and actions sit in the same column as the card and pill:

```html
  <div class="transcript-card"></div>
  <textarea class="editor" spellcheck="false"></textarea>
  <div class="actions">
    <button class="btn btn-copy" type="button">Copy</button>
    <button class="btn btn-paste" type="button">Paste</button>
    <button class="btn btn-close" type="button" title="Close (Esc)" aria-label="Close">✕</button>
  </div>
  <div class="overlay">
    <div class="dot"></div>
    <div class="wave"><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span></div>
    <div class="timer">0:00</div>
  </div>
```

- [ ] **Step 2: Add the editor + actions CSS**

Insert after the `.transcript-card` rules (after overlay.html:54, before the "Shared primitives" comment). Theme-independent dark glass, mirroring the card:

```css
  /* Editable review box — theme-independent dark glass, same legibility
     rationale as .transcript-card. Shown only in body.editing. */
  .editor {
    display: none;
    width: 360px; max-width: 360px;
    min-height: 44px;
    box-sizing: border-box;
    padding: 10px 14px;
    border: none; border-radius: 14px;
    background: rgba(20, 20, 22, 0.82);
    backdrop-filter: blur(24px) saturate(1.4);
    -webkit-backdrop-filter: blur(24px) saturate(1.4);
    box-shadow: 0 8px 24px rgba(0,0,0,0.35),
                inset 0 0 0 0.5px rgba(255,255,255,0.14),
                0 0 0 2px rgba(120,170,255,0.0);
    color: #f4f4f5;
    font-family: -apple-system, "SF Pro Display", system-ui, sans-serif;
    font-size: 13px; line-height: 1.5; letter-spacing: 0.01em;
    resize: none; overflow: hidden;   /* JS auto-grows; window grows with it */
    outline: none;
    transition: box-shadow 0.15s ease;
  }
  .editor:focus {
    box-shadow: 0 8px 24px rgba(0,0,0,0.35),
                inset 0 0 0 0.5px rgba(255,255,255,0.14),
                0 0 0 2px rgba(120,170,255,0.55);
  }
  .editor::-webkit-scrollbar { width: 0; }
  body.editing .editor { display: block; }
  /* In editing state the streaming card and the recording pill step aside. */
  body.editing .transcript-card,
  body.editing .overlay { display: none; }

  .actions {
    display: none;
    width: 360px; box-sizing: border-box;
    align-items: center; gap: 8px;
    padding: 0 2px;
  }
  body.editing .actions { display: flex; }
  .btn {
    font-family: -apple-system, system-ui, sans-serif;
    font-size: 12px; font-weight: 600; letter-spacing: 0.01em;
    padding: 7px 14px; border-radius: 10px;
    border: 0.5px solid rgba(255,255,255,0.14);
    background: rgba(40, 40, 46, 0.9);
    color: #f4f4f5; cursor: pointer;
    -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);
    transition: background 0.12s ease, transform 0.06s ease;
  }
  .btn:hover { background: rgba(58, 58, 66, 0.95); }
  .btn:active { transform: translateY(0.5px); }
  .btn-paste { background: rgba(48, 110, 230, 0.92); border-color: rgba(120,170,255,0.5); }
  .btn-paste:hover { background: rgba(58, 126, 250, 0.98); }
  .btn-close { margin-left: auto; padding: 7px 10px; }
  .btn-copy.copied { background: rgba(40, 160, 90, 0.95); }
```

- [ ] **Step 3: Add the JS — enterEdit, auto-grow, height report, button wiring**

Inside the `window.lw = { ... }` object (after `setRefineState`, before the closing `};` at overlay.html:358–359), add these methods:

```javascript
    // Hand off from the streaming card to a real editable textbox.
    enterEdit(text) {
      const ta = document.querySelector(".editor");
      ta.value = text || "";
      document.body.classList.add("editing");
      document.body.classList.remove("has-transcript");
      this._autogrow();
      ta.focus();
      // place caret at end
      ta.selectionStart = ta.selectionEnd = ta.value.length;
    },
    flashCopied() {
      const b = document.querySelector(".btn-copy");
      if (!b) return;
      const old = b.textContent;
      b.classList.add("copied"); b.textContent = "Copied ✓";
      setTimeout(() => { b.classList.remove("copied"); b.textContent = old; }, 1200);
    },
    _send(msg) {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lw) {
        window.webkit.messageHandlers.lw.postMessage(msg);
      }
    },
    _autogrow() {
      const ta = document.querySelector(".editor");
      if (!ta || !document.body.classList.contains("editing")) return;
      ta.style.height = "auto";
      ta.style.height = ta.scrollHeight + "px";
      // Report desired total page height so Lua can resize the window.
      this._send({ action: "resize", h: Math.ceil(document.body.scrollHeight) });
    },
```

Then, AFTER the `window.lw = { ... };` object literal (right after overlay.html:359), add the event wiring:

```javascript
  // Action-bar + keyboard wiring for edit mode.
  (function() {
    const ta = document.querySelector(".editor");
    const val = () => document.querySelector(".editor").value;
    document.querySelector(".btn-copy").addEventListener("click", () => {
      window.lw._send({ action: "copy", text: val() });
      window.lw.flashCopied();
    });
    document.querySelector(".btn-paste").addEventListener("click", () => {
      window.lw._send({ action: "paste", text: val() });
    });
    document.querySelector(".btn-close").addEventListener("click", () => {
      window.lw._send({ action: "close", text: val() });
    });
    ta.addEventListener("input", () => window.lw._autogrow());
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { e.preventDefault(); window.lw._send({ action: "close", text: val() }); }
      else if (e.key === "Enter" && e.metaKey) { e.preventDefault(); window.lw._send({ action: "paste", text: val() }); }
    });
    // Click-to-edit: a click on the read-only transcript card (OFF-mode grace) asks Lua to enter edit.
    document.querySelector(".transcript-card").addEventListener("click", () => {
      window.lw._send({ action: "editstart" });
    });
  })();
```

- [ ] **Step 4: Deploy & verify (visual, via web inspector)**

```bash
deploy
```

The overlay only appears during a dictation, so trigger the editor manually:
1. Start a dictation (hold Right Ctrl, say a sentence, release) so the overlay exists, then immediately open the Web Inspector: with `developerExtrasEnabled = true`, right-click the overlay → Inspect Element (or use Safari ▸ Develop ▸ Hammerspoon).
2. In the console run: `lw.enterEdit("The quick brown fox jumps over the lazy dog. Then it kept running for a while to make this several lines long so we can see the box grow.")`
3. Expected: the card/pill disappear; a dark-glass **textarea** with the text appears, focused, sized to fit (no internal scrollbar); below it a row with **Copy**, **Paste**, and a right-aligned **✕**.
4. Type extra lines in the textarea → it grows taller (the *window* won't grow yet — that's Task 3; text may clip at the window edge for now, which is expected).
5. Click **Copy** → button briefly shows "Copied ✓". (No clipboard effect yet — Task 3.)

Expected: editor + buttons render correctly and `enterEdit` swaps cleanly. Window-resize and real button actions come next.

- [ ] **Step 5: Commit**

```bash
git add hammerspoon/overlay.html
git commit -m "feat(edit-mode): add editable textarea + Copy/Paste/close action bar to overlay

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Wire the overlay to Lua — usercontent controller + window resize

Attaches a JS→Lua message channel to the overlay and implements `resize` (grow the window to fit, clamped on-screen) plus the Lua-side helper that enters editable state. Other actions (`copy`/`paste`/`close`/`editstart`) get handlers wired here but their full behavior lands in Tasks 5–6; for this task they log and (for resize) act.

**Files:**
- Modify: `hammerspoon/init.lua` — `createOverlay` (init.lua:1032–1071), overlay state region (near init.lua:1010), a new message handler + `overlayEnterEdit` helper

**Interfaces:**
- Consumes: `getEditMode`, `getGraceWindow` (Task 1); `window.lw.enterEdit` (Task 2); `OVERLAY_W`, `OVERLAY_H`, `overlay`, `jsEval`
- Produces:
  - `overlayEnterEdit(text)` — Lua: set `allowTextEntry(true)`, call `lw.enterEdit(text)`, mark overlay non-auto-hiding
  - overlay `usercontent` controller named `"lw"` with `setCallback` dispatching on `body.action`
  - `resizeOverlayToContent(h)` — resize + on-screen re-clamp, capped at 70% screen height
  - module-level `local overlayEditable = false`

- [ ] **Step 1: Add overlay edit-state locals**

Near the overlay state (search `local overlayPinned = false`, init.lua:1108) add:

```lua
local overlayEditable = false   -- true while the overlay is an editable review box
local overlayFrame0 = nil       -- {x,y,w,h} captured at create, for resize re-clamping
```

- [ ] **Step 2: Build the overlay with a usercontent controller**

In `createOverlay` (init.lua:1055), replace the `overlay = hs.webview.new(...)` line and add the controller above it. Find:

```lua
    overlay = hs.webview.new({ x = x, y = y, w = OVERLAY_W, h = OVERLAY_H },
        { developerExtrasEnabled = true })
```

Replace with:

```lua
    overlayFrame0 = { x = x, y = y, w = OVERLAY_W, h = OVERLAY_H }
    local controller = hs.webview.usercontent.new("lw")
    controller:setCallback(handleOverlayMessage)
    overlay = hs.webview.new({ x = x, y = y, w = OVERLAY_W, h = OVERLAY_H },
        { developerExtrasEnabled = true }, controller)
```

`handleOverlayMessage` is defined in Step 4; forward-declare it (Step 3) so `createOverlay` can reference it.

- [ ] **Step 3: Forward-declare the handler and helpers**

Just above `createOverlay` (init.lua:1032), add forward declarations:

```lua
local handleOverlayMessage   -- JS → Lua dispatch for the overlay
local resizeOverlayToContent
local overlayEnterEdit
```

- [ ] **Step 4: Implement resize, enter-edit, and the dispatcher**

After `setOverlayText` (init.lua:1093) add:

```lua
-- Grow/shrink the overlay window to fit reported content height `h` (px),
-- keeping its bottom edge anchored (box grows upward) and staying on-screen.
-- Capped at 70% of the screen height; beyond that the textarea scrolls.
resizeOverlayToContent = function(h)
    if not overlay or not overlayFrame0 then return end
    local screen = hs.screen.mainScreen():frame()
    local maxH = math.floor(screen.h * 0.70)
    local newH = math.max(OVERLAY_H, math.min(math.ceil(h) + 8, maxH))
    local f = overlay:frame()
    local bottom = f.y + f.h
    local newY = bottom - newH
    -- Clamp fully on-screen.
    newY = math.max(screen.y + 10, math.min(newY, screen.y + screen.h - newH - 10))
    overlay:frame({ x = f.x, y = newY, w = OVERLAY_W, h = newH })
end

-- Flip the overlay to editable review mode showing `text`.
overlayEnterEdit = function(text)
    if not overlay then return end
    overlayEditable = true
    overlayPinned = true            -- block auto-hide while editing
    overlay:allowTextEntry(true)    -- grant keyboard focus to the textarea
    jsEval("lw.enterEdit('" .. jsStr(text) .. "')")
end

handleOverlayMessage = function(msg)
    local body = msg and msg.body
    if type(body) ~= "table" then return end
    local action = body.action
    if action == "resize" then
        if overlayEditable and body.h then resizeOverlayToContent(body.h) end
    elseif action == "copy" then
        if body.text then hs.pasteboard.setContents(body.text) end
        log("edit: copy (" .. #(body.text or "") .. " chars)")
        -- history/copied-flag handled in Task 5
    elseif action == "paste" then
        log("edit: paste requested")
        -- handled in Task 5
    elseif action == "close" then
        log("edit: close requested")
        -- handled in Task 5
    elseif action == "editstart" then
        log("edit: editstart (click-to-edit)")
        -- handled in Task 6
    end
end
```

- [ ] **Step 5: Reset edit-state on overlay teardown**

In `hideOverlay` and `forceHideOverlay` (init.lua:1081–1089), set the flags false so a reused overlay starts clean. In each function body add before/after the delete:

```lua
    overlayEditable = false
    overlayPinned = false
```

(For `hideOverlay`, keep its existing `if overlayPinned then return end` guard ABOVE these resets — i.e. only reset when actually hiding. Reorder so the early-return still protects a pinned overlay.)

Resulting `hideOverlay`:

```lua
local function hideOverlay()
    if overlayPinned then return end
    overlayEditable = false
    if overlay then overlay:delete(); overlay = nil end
end
```

`forceHideOverlay` ignores the pin, so reset both:

```lua
local function forceHideOverlay()
    overlayPinned = false
    overlayEditable = false
    if overlay then overlay:delete(); overlay = nil end
end
```

- [ ] **Step 6: Deploy & verify (temporary manual trigger)**

```bash
luac -p hammerspoon/init.lua && deploy
```

Trigger a dictation to create the overlay, open the Web Inspector console, and run `lw.enterEdit("line one\nline two")` — but note `enterEdit` is JS-only; to exercise the Lua path, instead from a terminal:

```bash
/usr/local/bin/hs -c 'overlayEnterEdit("First line.\nSecond line.\nThird line so the box clearly needs more height than the default pill.")'
```

(If `overlayEnterEdit` isn't reachable as a global, temporarily add a menubar item `{ title="Test edit box", fn=function() showOverlay(); hs.timer.doAfter(0.2, function() overlayEnterEdit("First line.\nSecond line.\nThird line.") end) end }` for this check, then remove it before commit.)

Expected:
1. The overlay appears as the editable textarea + buttons.
2. The **window grows taller** to fit all three lines (no clipping, no internal scroll).
3. Typing several more lines grows the window further, up to ~70% of screen height, then the textarea scrolls.
4. Clicking **Copy** puts the text on the clipboard — verify: `pbpaste` in a terminal shows the box contents.
5. Log shows `edit: copy (...)`.

- [ ] **Step 7: Commit**

```bash
git add hammerspoon/init.lua
git commit -m "feat(edit-mode): wire overlay JS->Lua channel + window auto-resize to content

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Fork `finishInsertion` — open the editable box in edit mode (ON)

Makes a real dictation open the editable box when edit mode is ON: no auto-paste, refined text shown, pending record stashed, auto-hide cancelled.

**Files:**
- Modify: `hammerspoon/init.lua` — `finishInsertion` (init.lua:1689–1744), module state near `lastInsertedText`

**Interfaces:**
- Consumes: `getEditMode` (Task 1), `overlayEnterEdit` (Task 3), existing `buildActionContext`, `normalizeText`, `runPreInsertActions`
- Produces:
  - module-level `local pendingDictation = nil` — `{raw, refined, lang, app, model, time, copied}`

- [ ] **Step 1: Add the pending-record state**

Near `local lastInsertedText` (search `lastInsertedText`), add:

```lua
local pendingDictation = nil   -- edit-mode: stashed until the user copies/pastes/closes
```

- [ ] **Step 2: Fork `finishInsertion` for edit mode**

In `finishInsertion`, after the `runPreInsertActions(ctx)` call and the empty-text guard (init.lua:1695–1702), insert the edit-mode branch BEFORE the `if ctx.insert then` block:

```lua
    -- Edit mode: don't insert. Stash the three texts and open the editable box.
    if getEditMode() and ctx.insert then
        local raw = ctx.originalText or finalText
        pendingDictation = {
            raw = raw,
            refined = (finalText ~= raw) and finalText or nil,
            lang = detectedLang or getLang(),
            app = capturedAppName or "?",
            model = getModelName(),
            time = os.time(),
            copied = false,
        }
        log("edit: opening review box (" .. #finalText .. " chars)")
        setOverlayText(finalText)     -- ensure card has content before handoff
        overlayEnterEdit(finalText)
        return                        -- history written later, at the terminal action
    end
```

(Leaving the existing `if ctx.insert then ... else ... end` and history/linger code below untouched for the non-edit path.)

- [ ] **Step 3: Deploy & verify**

```bash
luac -p hammerspoon/init.lua && deploy
```

1. Toggle **Edit mode: ON** in the menubar.
2. Dictate a sentence (hold Right Ctrl, speak, release).
3. Expected: after transcription/refine, the overlay becomes the **editable textbox** with the refined text — **nothing is pasted** at the cursor. The box persists (does not auto-hide after 2s). The window is sized to the text.
4. Dictate a long multi-sentence passage → the box/window grows to fit.
5. Log shows `edit: opening review box (N chars)`.
6. Toggle **Edit mode: OFF** → dictate again → confirm normal auto-paste still works (unchanged).

Buttons don't persist history yet (Task 5) — Copy still copies (from Task 3); Paste/Close just log.

- [ ] **Step 4: Commit**

```bash
git add hammerspoon/init.lua
git commit -m "feat(edit-mode): route dictation to editable box when edit mode is on

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Terminal actions — Paste/Copy/Close write the three-text history

Completes the edit-mode loop: Paste inserts into the original app and closes; Close dismisses; both persist `raw/refined/edited/output`. Copy marks the pending record. Adds a teardown fallback so an abandoned box isn't lost.

**Files:**
- Modify: `hammerspoon/init.lua` — `handleOverlayMessage` (from Task 3), history recording (extract a helper from init.lua:1724–1737), teardown (`hideOverlay`/`forceHideOverlay`)

**Interfaces:**
- Consumes: `pendingDictation` (Task 4), `capturedAppBundleID` (init.lua:779), `insertTextAtCursor` (init.lua:1673), `getOutputMode`, `getEnterMode`, `recentDictations`, `MAX_RECENT`, `saveRecentDictations`
- Produces:
  - `recordDictation(rec, edited, output)` — append a history entry from a pending record + final edit + output label

- [ ] **Step 1: Extract a history-recording helper**

Above `finishInsertion` (init.lua:1689), add a helper that both the normal path and edit path can use:

```lua
-- Append one history entry. `rec` carries {raw, refined, lang, app, model, time};
-- `edited` is the user's final box text (nil if not edited / not applicable);
-- `output` is "pasted" | "copied" | "dismissed".
local function recordDictation(rec, edited, output)
    table.insert(recentDictations, 1, {
        text    = rec.raw,
        refined = rec.refined,
        edited  = (edited and edited ~= (rec.refined or rec.raw)) and edited or nil,
        output  = output,
        time    = rec.time or os.time(),
        inserted = (output == "pasted"),
        app     = rec.app or "?",
        model   = rec.model or getModelName(),
        chars   = #(rec.raw or ""),
        lang    = rec.lang or getLang(),
    })
    while #recentDictations > MAX_RECENT do table.remove(recentDictations) end
    saveRecentDictations()
end
```

- [ ] **Step 2: Implement paste/copy/close in the dispatcher**

Replace the `copy`/`paste`/`close` branches in `handleOverlayMessage` (Task 3, Step 4) with full behavior:

```lua
    elseif action == "copy" then
        if body.text then hs.pasteboard.setContents(body.text) end
        if pendingDictation then pendingDictation.copied = true end
        log("edit: copy (" .. #(body.text or "") .. " chars)")
    elseif action == "paste" then
        local text = body.text or ""
        local rec = pendingDictation
        pendingDictation = nil
        hs.pasteboard.setContents(text)
        lastInsertedText = text
        overlayPinned = false
        overlayEditable = false
        if overlay then overlay:delete(); overlay = nil end
        -- Restore the app we recorded from, then paste.
        hs.timer.doAfter(0.05, function()
            if capturedAppBundleID then
                local app = hs.application.applicationsForBundleID(capturedAppBundleID)[1]
                if app then app:activate() end
            end
            hs.timer.doAfter(0.12, function()
                hs.eventtap.keyStroke({ "cmd" }, "v")
                if getEnterMode() then
                    hs.timer.doAfter(0.15, function() hs.eventtap.keyStroke({}, "return") end)
                end
            end)
        end)
        if rec then recordDictation(rec, text, "pasted") end
        log("edit: pasted into " .. tostring(capturedAppName))
    elseif action == "close" then
        local text = body.text or ""
        local rec = pendingDictation
        pendingDictation = nil
        overlayPinned = false
        overlayEditable = false
        if overlay then overlay:delete(); overlay = nil end
        if rec then
            recordDictation(rec, text, rec.copied and "copied" or "dismissed")
        end
        log("edit: closed (" .. (rec and rec.copied and "copied" or "dismissed") .. ")")
```

- [ ] **Step 3: Teardown fallback for an abandoned box**

In `forceHideOverlay` (and any other hard teardown), persist a pending record so an interrupted edit isn't silently lost. Update `forceHideOverlay`:

```lua
local function forceHideOverlay()
    if pendingDictation then
        recordDictation(pendingDictation, nil, pendingDictation.copied and "copied" or "dismissed")
        pendingDictation = nil
    end
    overlayPinned = false
    overlayEditable = false
    if overlay then overlay:delete(); overlay = nil end
end
```

(Leave `hideOverlay` as-is — it early-returns while pinned, so an editable box is never torn down through it.)

- [ ] **Step 4: Remove the now-duplicated inline history write (DRY)**

In the non-edit path of `finishInsertion` (init.lua:1724–1737), replace the inline `table.insert(recentDictations, ...)` + trim + `saveRecentDictations()` with a single call, so both paths share `recordDictation`:

```lua
    recordDictation(
        { raw = ctx.originalText, refined = (ctx.text ~= ctx.originalText) and ctx.text or nil,
          lang = detectedLang or getLang(), app = capturedAppName or "?",
          model = getModelName(), time = os.time() },
        nil,
        ctx.inserted and "pasted" or "dismissed"
    )
```

(Verify `ctx.originalText` is set on the non-refine path; if it can be nil there, fall back to `finalText`. Check `buildActionContext`/`finishInsertion` — `ctx.originalText` defaults from `ctx.text` when refine didn't run. If nil, use `ctx.originalText or finalText`.)

- [ ] **Step 5: Deploy & verify (the full loop + data model)**

```bash
luac -p hammerspoon/init.lua && deploy
```

With **Edit mode: ON**:
1. Dictate "testing one two three", let the box open, click **Paste** while a text editor / notes app was frontmost when you recorded → text inserts there; box closes.
2. Inspect history: `python3 -c "import json;print(json.dumps(json.load(open('$HOME/.thinking-out-loud/history.json'))[0],indent=2))"` → newest entry has `"output": "pasted"`, `"inserted": true`, `"text"` = raw whisper, and `"refined"`/`"edited"` only if they differed.
3. Dictate again; in the box, **edit** the text (fix a word), click **Copy**, then click **✕**. History newest entry: `"output": "copied"`, `"edited"` = your corrected text, `"text"` = original raw. `pbpaste` shows the corrected text.
4. Dictate again; click **✕** without editing → `"output": "dismissed"`, no `"edited"`, nothing pasted.
5. Toggle **Edit mode: OFF**, dictate → still auto-pastes; history entry has `"output": "pasted"` (new field present, behavior unchanged).

- [ ] **Step 6: Commit**

```bash
git add hammerspoon/init.lua
git commit -m "feat(edit-mode): persist raw/refined/edited + output; Paste restores app, Copy/Close finalize

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: OFF-mode grace window + click-to-edit

When edit mode is OFF, defer the auto-paste behind a configurable grace window (default 1s); a click on the box during that window cancels the paste and enters the editable flow for that one dictation.

**Files:**
- Modify: `hammerspoon/init.lua` — `finishInsertion` non-edit path (init.lua:1704–1721), `handleOverlayMessage` `editstart` branch, a grace-timer local

**Interfaces:**
- Consumes: `getGraceWindow` (Task 1), `overlayEnterEdit` (Task 3), `pendingDictation` + `recordDictation` (Tasks 4–5)
- Produces: module-level `local graceTimer = nil`

- [ ] **Step 1: Add the grace-timer state**

Near `pendingDictation` (Task 4), add:

```lua
local graceTimer = nil   -- OFF-mode: pending auto-paste; cancelled by click-to-edit
```

- [ ] **Step 2: Defer the OFF-mode paste behind the grace window**

Replace the non-edit insertion block in `finishInsertion`. Currently (init.lua:1704–1743) it inserts immediately, records history, and lingers. Change it so the text is shown read-only, a pending record is stashed, and the paste fires after the grace window:

```lua
    -- Non-edit path: stash pending, show read-only, auto-paste after the grace window.
    local rec = {
        raw = ctx.originalText or finalText,
        refined = (finalText ~= (ctx.originalText or finalText)) and finalText or nil,
        lang = detectedLang or getLang(),
        app = capturedAppName or "?",
        model = getModelName(),
        time = os.time(),
        copied = false,
    }
    pendingDictation = rec

    local display = finalText
    if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
    setOverlayText(display)

    if not ctx.insert then
        -- Action hooks disabled insertion entirely: just record + linger.
        log("final: insertion disabled by action hooks")
        pendingDictation = nil
        recordDictation(rec, nil, "dismissed")
        hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
        return
    end

    graceTimer = hs.timer.doAfter(getGraceWindow(), function()
        graceTimer = nil
        if pendingDictation ~= rec then return end   -- click-to-edit took over
        pendingDictation = nil
        lastInsertedText = finalText
        insertTextAtCursor(finalText, ctx.outputMode)
        if getEnterMode() then
            hs.timer.doAfter(0.15, function() hs.eventtap.keyStroke({}, "return") end)
        end
        recordDictation(rec, nil, "pasted")
        ctx.text = finalText
        runPostInsertActions(ctx)
        hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
        hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
    end)
    return
```

This REPLACES the old `if ctx.insert then ... end`, the inline history write you removed in Task 5 Step 4, the `setOverlayText(display)`, the Glass sound, and the `hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)` tail. (Net: that earlier `recordDictation(...)` from Task 5 Step 4 is now folded into these two branches — remove the standalone one so history isn't written twice.)

`runPostInsertActions` now runs inside the timer (after the real paste), matching the original ordering where post-insert hooks ran after insertion.

- [ ] **Step 3: Implement `editstart` (click-to-edit)**

Replace the `editstart` branch in `handleOverlayMessage`:

```lua
    elseif action == "editstart" then
        if overlayEditable then return end          -- already editing
        if not pendingDictation then return end     -- nothing to edit
        if graceTimer then graceTimer:stop(); graceTimer = nil end
        log("edit: click-to-edit, cancelling auto-paste")
        local text = pendingDictation.refined or pendingDictation.raw
        overlayEnterEdit(text)
```

- [ ] **Step 4: Stop a live grace timer on new recordings/teardown**

In `forceHideOverlay` (Task 5 Step 3) and at the start of `showOverlay` (init.lua:1073), cancel any stale grace timer so a fast second dictation doesn't double-fire. Add to both:

```lua
    if graceTimer then graceTimer:stop(); graceTimer = nil end
```

- [ ] **Step 5: Deploy & verify**

```bash
luac -p hammerspoon/init.lua && deploy
```

With **Edit mode: OFF**:
1. Dictate a sentence and **do nothing** → after ~1s the text auto-pastes at the cursor (as before, just delayed). History entry `"output": "pasted"`.
2. Dictate again and **click the transcript box** during the ~1s window → the auto-paste is cancelled, the box becomes the editable textbox with Copy/Paste/✕. Edit, Paste → inserts into the original app; history has `"edited"` + `"output":"pasted"`. Log shows `edit: click-to-edit, cancelling auto-paste`.
3. Set a longer window to make clicking easy: `echo 3 > ~/.thinking-out-loud/grace`, reload, repeat step 2 (now you have 3s). Reset: `echo 1 > ~/.thinking-out-loud/grace`.
4. Confirm rapid back-to-back dictations don't double-paste (the second `showOverlay` stops the first grace timer).

- [ ] **Step 6: Commit**

```bash
git add hammerspoon/init.lua
git commit -m "feat(edit-mode): OFF-mode grace window + click-to-edit to intercept auto-paste

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Polish + docs

Validates the first-click-activation risk on the real setup, tidies any leftover test hooks, and updates project docs.

**Files:**
- Modify: `hammerspoon/init.lua` (only if a click-activation fallback is needed), `.claude/CLAUDE.md` (Current state table), `hammerspoon/overlay.html` (only if a visible edit affordance is needed)

**Interfaces:** none new.

- [ ] **Step 1: Validate first-click activation (the spec's flagged risk)**

With **Edit mode: OFF** and the overlay NOT the frontmost window (click another app first), dictate and try the single click-to-edit. Determine empirically:
- If a single click reliably enters edit → done, no change.
- If the FIRST click only activates the overlay window (edit needs a second click) → apply the fallback in Step 2.

- [ ] **Step 2: (Conditional) Add a visible edit affordance**

Only if Step 1 showed single-click is unreliable. Add a small always-present hint button on the read-only card so one deliberate click works regardless of window-activation. In overlay.html, add inside the card region a `.edit-hint` ("✎") that posts `editstart`, shown only when `body.has-transcript` and not `body.editing`. Wire its click to `window.lw._send({action:"editstart"})`. Deploy & verify a single click enters edit. If single-click already worked, skip this step entirely.

- [ ] **Step 3: Remove any temporary test hooks**

Grep for and delete any temporary menubar "Test edit box" item or debug prints added during Tasks 3–6:

```bash
grep -n "Test edit box" hammerspoon/init.lua || echo "clean"
```

- [ ] **Step 4: Update the Current-state docs**

In `.claude/CLAUDE.md`, add a row to the state table documenting edit mode (toggle, grace window, three-text history, Copy/Paste/click-to-edit). Keep it one row, consistent with the existing table style. Note in `history.json` description that entries now also carry `edited` and `output`.

- [ ] **Step 5: Full regression pass**

Run the complete verification matrix from the spec's "Verification" section (all 6 scenarios), plus: switch themes (menubar) and confirm the editable box + buttons remain legible in `liquid`, `arc-card` (light), and `neon`. The editor is theme-independent dark glass, so it should read clearly over all; fix the one button style if any theme clashes.

- [ ] **Step 6: Commit**

```bash
git add hammerspoon/init.lua hammerspoon/overlay.html .claude/CLAUDE.md
git commit -m "feat(edit-mode): validate click-to-edit, docs, polish pass

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Edit-mode toggle (menubar + flag) → Task 1 ✓
- 1s grace window + click-to-edit (OFF) → Task 6 ✓
- Full-size editable textbox, window grows to fit, 70% cap → Tasks 2 (CSS/autogrow) + 3 (window resize) ✓
- Copy / Paste / Close buttons, Paste restores app → Tasks 2 (UI) + 5 (behavior) ✓
- Three-text data model (raw/refined/edited) + output field, written at terminal action → Tasks 4 (stash) + 5 (record) + 6 (OFF paths) ✓
- App restore via `capturedAppBundleID` → Task 5 ✓
- Auto-hide suppressed while editable; preserved elsewhere → Tasks 3 (pin) + 6 (linger on OFF) ✓
- Teardown fallback for abandoned box → Task 5 ✓
- Esc/Cmd+Return, "Copied ✓" → Task 2 ✓
- First-click-activation validation → Task 7 ✓
- Refine-off path (raw==refined) → handled by `refined = (… ~= raw) and … or nil` throughout ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every code step shows real Lua/JS. Task 2/7 conditional steps specify exact trigger conditions. ✓

**Type/name consistency:** `getEditMode`/`cycleEditMode`/`getGraceWindow`, `overlayEnterEdit`, `resizeOverlayToContent`, `handleOverlayMessage`, `recordDictation(rec, edited, output)`, `pendingDictation` fields `{raw,refined,lang,app,model,time,copied}`, message actions `resize|copy|paste|close|editstart`, JS `lw.enterEdit/flashCopied/_send/_autogrow` — used identically across tasks. ✓

**Assumptions — verified against the code before handoff:**
- ✓ `hs.webview.new(rect, prefs, controller)` 3-arg form is valid — the dashboard uses exactly `hs.webview.new({...}, { developerExtrasEnabled = true }, controller)` (init.lua:1337–1338).
- ✓ `ctx.originalText` is always non-nil — `buildActionContext` sets `originalText = text` unconditionally, so the non-refine path is safe (the `or finalText` fallback in Task 5 Step 4 is just defensive).

**Remaining assumption to verify empirically during execution (not a blocker):**
- `overlay:allowTextEntry(true)` toggling on a *live* webview grants the textarea focus. If it doesn't, recreate the overlay already in editable state (the overlay is cheap to rebuild — `createOverlay` runs on every recording). Fallback noted at Task 3.
