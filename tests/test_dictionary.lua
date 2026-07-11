#!/usr/bin/env lua
-- test_dictionary.lua — unit tests for the user-dictionary replacement +
-- whisper-prompt merge logic.
--
-- init.lua can't be loaded standalone (it needs Hammerspoon's hs.* globals
-- and runs side effects at load), so we extract just the pure functions
-- delimited by the "@dictionary-start" / "@dictionary-end" markers and load
-- that block in isolation. This keeps init.lua as the single source of truth.
--
-- Run:  lua tests/test_dictionary.lua   (from the repo root)

local function scriptDir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*)/[^/]-$") or "."
end

local INIT_PATH = scriptDir() .. "/../hammerspoon/init.lua"

local f = assert(io.open(INIT_PATH, "r"), "cannot open " .. INIT_PATH)
local source = f:read("*a")
f:close()

local block = source:match("%-%- @dictionary%-start%s*\n(.-)%-%- @dictionary%-end")
assert(block, "could not find @dictionary-start/@dictionary-end block in init.lua")

-- Expose the inner locals by appending a return of the public entry point.
local chunk = assert(load(block .. "\nreturn Dictionary", "dictionary-block"))
local Dictionary = chunk()
assert(type(Dictionary) == "table", "extracted block did not yield the Dictionary table")

local passed, failed = 0, 0
local function report(name, ok, expected, got)
    if ok then
        passed = passed + 1
        print(string.format("  ok  %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL  %s\n        expected: %q\n        got:      %q",
            name, tostring(expected), tostring(got)))
    end
end

local function entriesFor(map)
    return Dictionary.parse({ replacements = map }).entries
end

local function checkApply(name, map, input, expected)
    local got = Dictionary.apply(input, entriesFor(map))
    report(name, got == expected, expected, got)
end

local function checkMerge(name, userPrompt, decoded, maxChars, expected)
    local got = Dictionary.mergePrompt(userPrompt, Dictionary.parse(decoded), maxChars)
    report(name, got == expected, expected, got)
end

print("Dictionary.apply:")

checkApply("simple replacement",
    { clod = "Claude" }, "i use clod daily", "i use Claude daily")

checkApply("case-insensitive match",
    { clod = "Claude" }, "CLOD said so", "Claude said so")

checkApply("multi-word phrase",
    { ["hammer spoon"] = "Hammerspoon" }, "open hammer spoon now", "open Hammerspoon now")

checkApply("multi-space key normalized at parse",
    { ["hammer   spoon"] = "Hammerspoon" }, "open hammer spoon now", "open Hammerspoon now")

checkApply("longest key wins",
    { ["qn 3"] = "qwen3", qn = "qwen" }, "test qn 3 against qn", "test qwen3 against qwen")

checkApply("shorter key matches where longer key fails its boundary",
    { ["qn 3"] = "qwen3", qn = "qwen" }, "qn 3x", "qwen 3x")

checkApply("no mid-word replacement",
    { cord = "chord" }, "recording started", "recording started")

checkApply("punctuation-adjacent matches",
    { clod = "Claude" }, "ask clod, then clod.", "ask Claude, then Claude.")

checkApply("matches at string edges",
    { clod = "Claude" }, "clod is clod", "Claude is Claude")

checkApply("literal key with pattern-magic chars",
    { ["c++"] = "C++" }, "i like c++, yes", "i like C++, yes")

checkApply("frontier: non-word key edge needs no boundary on that side",
    { ["c++"] = "C++" }, "we use c++17 now", "we use C++17 now")

checkApply("single-char key replaced only as a standalone word",
    { i = "I" }, "i think i can, immediately", "I think I can, immediately")

checkApply("literal % in replacement value",
    { pct = "100%" }, "the pct sign", "the 100% sign")

checkApply("inserted values are not rescanned",
    { clod = "claude", claude = "Anthropic" }, "clod", "claude")

-- Invalid shapes: garbage in -> empty dict out, apply passes text through.
do
    local nilDict = Dictionary.parse(nil)
    report("parse(nil) yields empty entries", #nilDict.entries == 0, 0, #nilDict.entries)
    local strDict = Dictionary.parse("x")
    report("parse(string) yields empty entries", #strDict.entries == 0, 0, #strDict.entries)
    local mixed = Dictionary.parse({ replacements = { good = "Good", bad = 42, [1] = "y" } })
    report("parse skips non-string keys/values",
        #mixed.entries == 1 and mixed.entries[1].find == "good", "good", #mixed.entries)
    -- Load-bearing: a zero-length key would match everywhere and never advance
    -- the scan index -> infinite loop in Dictionary.apply.
    local ws = Dictionary.parse({ replacements = { ["   "] = "boom", real = "  \t " } })
    report("parse drops whitespace-only keys and values", #ws.entries == 0, 0, #ws.entries)
    local text = "anything at all"
    local got = Dictionary.apply(text, nilDict.entries)
    report("apply with empty entries is passthrough", got == text, text, got)
end

checkApply("vocabulary-only dict leaves text unchanged",
    {}, "plain text", "plain text")

print("\nDictionary.mergePrompt:")

checkMerge("user prompt only",
    "my prompt", nil, nil, "my prompt")

checkMerge("dict only: vocab first, values alpha-sorted",
    "", { vocabulary = { "PARA" }, replacements = { clod = "Claude" } }, nil,
    "PARA, Claude")

checkMerge("user text goes last",
    "my prompt", { vocabulary = { "PARA" }, replacements = { clod = "Claude" } }, nil,
    "PARA, Claude. my prompt")

checkMerge("terms already in user prompt are deduped",
    "i love claude", { vocabulary = { "Claude" }, replacements = { clod = "Claude" } }, nil,
    "i love claude")

checkMerge("dedupe is substring containment: term inside an unrelated word is dropped",
    "write a paragraph about dogs", { vocabulary = { "PARA" } }, nil,
    "write a paragraph about dogs")

checkMerge("values-only: case-insensitive alpha order",
    "", { replacements = { teh = "the", zed = "Zed", ac = "Anthropic" } }, nil,
    "Anthropic, the, Zed")

checkMerge("duplicate term across vocab and values appears once",
    "", { vocabulary = { "Claude" }, replacements = { clod = "Claude" } }, nil,
    "Claude")

-- Cap: terms are budgeted into maxChars, user prompt is never trimmed.
do
    local user = string.rep("u", 100)
    local decoded = { vocabulary = { string.rep("a", 10), string.rep("b", 10) } }
    local got = Dictionary.mergePrompt(user, Dictionary.parse(decoded), 120)
    local ok = (#got <= 120) and (got:sub(-#user) == user)
        and (got:find(string.rep("a", 10), 1, true) ~= nil)
        and (got:find(string.rep("b", 10), 1, true) == nil)
    report("cap keeps user prompt whole, drops overflow terms", ok,
        "<=120 chars, ends with user prompt, first term kept, second dropped", got)
end

-- Budget boundary: "Ollama"(6) + ". "(2) + "notes"(5) = 13 exactly.
checkMerge("term filling the budget to exactly maxChars is kept",
    "notes", { vocabulary = { "Ollama" } }, 13, "Ollama. notes")

checkMerge("term one char over budget is dropped, user prompt intact",
    "notes", { vocabulary = { "Ollama" } }, 12, "notes")

checkMerge("oversized user prompt passes through untrimmed",
    string.rep("u", 30), { vocabulary = { "abc" } }, 10, string.rep("u", 30))

checkMerge("all empty yields empty string",
    "", nil, nil, "")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
