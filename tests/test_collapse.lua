#!/usr/bin/env lua
-- test_collapse.lua — unit tests for the repetitive-artifact collapse logic.
--
-- init.lua can't be loaded standalone (it needs Hammerspoon's hs.* globals
-- and runs side effects at load), so we extract just the pure functions
-- delimited by the "@collapse-start" / "@collapse-end" markers and load that
-- block in isolation. This keeps init.lua as the single source of truth.
--
-- Run:  lua tests/test_collapse.lua   (from the repo root)

local function scriptDir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*)/[^/]-$") or "."
end

local INIT_PATH = scriptDir() .. "/../hammerspoon/init.lua"

local f = assert(io.open(INIT_PATH, "r"), "cannot open " .. INIT_PATH)
local source = f:read("*a")
f:close()

local block = source:match("%-%- @collapse%-start%s*\n(.-)%-%- @collapse%-end")
assert(block, "could not find @collapse-start/@collapse-end block in init.lua")

-- Expose the inner locals by appending a return of the public entry point.
local chunk = assert(load(block .. "\nreturn collapseRepetitiveArtifacts",
    "collapse-block"))
local collapse = chunk()
assert(type(collapse) == "function", "extracted block did not yield a function")

local passed, failed = 0, 0
local function check(name, input, expected)
    local got = collapse(input)
    if got == expected then
        passed = passed + 1
        print(string.format("  ok  %s", name))
    else
        failed = failed + 1
        print(string.format("FAIL  %s\n        input:    %q\n        expected: %q\n        got:      %q",
            name, input, expected, got))
    end
end

print("collapseRepetitiveArtifacts:")

-- Word-level loops (single token repeated >= 6x), with punctuation variants.
check("single-word loop x6 dropped",
    "URL URL URL URL URL URL", "")
check("punctuated single-word loop dropped",
    "URL, URL, URL, URL, URL, URL", "")
check("word loop embedded in real prose",
    "the meeting is URL URL URL URL URL URL on tuesday",
    "the meeting is on tuesday")

-- Multi-word English loop (char pass; clean tiling incl. trailing separator).
check("multi-word phrase loop x6 dropped",
    string.rep("thanks for watching ", 6), "")

-- CJK loop with no spaces (char pass; word pass sees one token).
check("CJK loop x6 dropped",
    string.rep("谢谢观看", 6), "")

-- Rhetorical / emphatic repetition stays (under threshold).
check("rhetorical 'no' x5 preserved",
    "no no no no no", "no no no no no")
check("emphatic 'yeah' x3 preserved",
    "yeah yeah yeah", "yeah yeah yeah")
check("normal sentence untouched",
    "So the meeting is at 3pm on Tuesday.",
    "So the meeting is at 3pm on Tuesday.")

-- Exactly at threshold boundary: 5 repeats kept, 6 dropped.
check("word run of exactly 5 preserved",
    "ha ha ha ha ha", "ha ha ha ha ha")
check("word run of exactly 6 dropped",
    "ha ha ha ha ha ha", "")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
