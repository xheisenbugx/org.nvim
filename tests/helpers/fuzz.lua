-- Seeded random Org text for fuzz specs.
--
--   local fuzz = require("tests.helpers.fuzz")
--   for _, seed in ipairs(fuzz.seeds(20)) do
--     local rng = fuzz.rng(seed)
--     local lines = fuzz.doc(rng)
--   end
--
-- The default run uses a few fixed seeds so `make test` stays fast and
-- reproducible. ORG_FUZZ_ITERATIONS=5000 runs that many seeds,
-- ORG_FUZZ_SCALE=40 forty times each spec's default, ORG_FUZZ_START=S
-- starts at seed S instead of 1, and ORG_FUZZ_SEED=1234 runs just that
-- seed (to replay a failure). `make fuzz` runs a long session from a random
-- start; see "Fuzzing" in CONTRIBUTING.md.
local M = {}

--- A Park-Miller PRNG: the same numbers on every platform (products stay
--- below 2^53, so doubles are exact) and independent of math.random.
---@class fuzz.Rng
local Rng = {}
Rng.__index = Rng

function M.rng(seed)
  local s = (seed * 7919 + 17) % 2147483647
  if s == 0 then
    s = 1
  end
  return setmetatable({ s = s }, Rng)
end

--- A float in [0, 1).
function Rng:float()
  self.s = self.s * 16807 % 2147483647
  return (self.s - 1) / 2147483646
end

--- An integer in [a, b] (or [1, a]).
function Rng:int(a, b)
  if not b then
    a, b = 1, a
  end
  return a + math.floor(self:float() * (b - a + 1))
end

function Rng:chance(p)
  return self:float() < p
end

function Rng:pick(t)
  return t[self:int(#t)]
end

--- The seeds a fuzz spec runs: `default` fixed ones (1..default), so that
--- `make test` stays fast and gives the same result every time. The
--- environment asks for more, or for one:
---   ORG_FUZZ_SEED=N        just seed N (replays a reported failure)
---   ORG_FUZZ_ITERATIONS=N  N seeds instead of `default`
---   ORG_FUZZ_SCALE=K       K times `default` (`make fuzz`)
---   ORG_FUZZ_START=S       start at seed S instead of 1 (S, S+1, ...)
---@param default integer
---@return integer[]
function M.seeds(default)
  local one = tonumber(vim.env.ORG_FUZZ_SEED or "")
  if one then
    return { one }
  end
  local n = tonumber(vim.env.ORG_FUZZ_ITERATIONS or "")
    or math.floor(default * (tonumber(vim.env.ORG_FUZZ_SCALE or "") or 1) + 0.5)
  local start = tonumber(vim.env.ORG_FUZZ_START or "") or 1
  local out = {}
  for i = 1, n do
    out[i] = start + i - 1
  end
  if M.long() then
    io.stderr:write(("fuzz: %s: seeds %d..%d\n"):format(M.spec(), start, start + n - 1))
  end
  return out
end

--- Whether a long run was asked for (specs may then print progress).
function M.long()
  return (vim.env.ORG_FUZZ_ITERATIONS or "") ~= "" or (vim.env.ORG_FUZZ_SCALE or "") ~= ""
end

--- The fuzz spec file running (tests/spec/fuzz_*_spec.lua), from the stack.
function M.spec()
  for level = 2, 50 do
    local info = debug.getinfo(level, "S")
    if not info then
      break
    end
    local f = info.source:match("(tests[/\\]spec[/\\][^/\\]+_spec%.lua)$")
    if f then
      return (f:gsub("\\", "/"))
    end
  end
  return "tests/spec/fuzz_*_spec.lua"
end

--- The command that replays `seed` of the running fuzz spec.
function M.replay(seed)
  return ("ORG_FUZZ_SEED=%d make test SPEC=%s"):format(seed, M.spec())
end

--- What kind of failure `msg` is, to keep shrinking on the same one: its
--- first line without the numbers (line numbers, counts).
function M.kind(msg)
  return (tostring(msg):match("^[^\n]*"):gsub("%d+", "#"))
end

--- The smallest `lines` found that still fail: drops chunks of lines, then
--- single lines (delta debugging), while `fails(candidate)` holds.
--- `keep` (a line index) is never dropped; the second result is its index
--- in the shrunk lines. At most `budget` calls of `fails` (default 3000).
---@param lines string[]
---@param fails fun(lines: string[], keep?: integer): boolean
---@param keep? integer
---@param budget? integer
---@return string[] lines, integer|nil keep
function M.shrink(lines, fails, keep, budget)
  budget = budget or 3000
  local cur = { lines = lines, keep = keep }
  local calls = 0
  --- `cur` without the lines i..j (but `keep`).
  local function without(i, j)
    local out, k = {}, nil
    for l, s in ipairs(cur.lines) do
      if l < i or l > j or l == cur.keep then
        out[#out + 1] = s
        if l == cur.keep then
          k = #out
        end
      end
    end
    return out, k
  end
  local chunk = math.max(1, math.floor(#cur.lines / 2))
  while chunk >= 1 and calls < budget do
    local progress = false
    local i = 1
    while i <= #cur.lines and calls < budget do
      local cand, k = without(i, i + chunk - 1)
      if #cand < #cur.lines then
        calls = calls + 1
        local ok_, res = pcall(fails, cand, k)
        if ok_ and res then
          cur = { lines = cand, keep = k }
          progress = true
        else
          i = i + chunk
        end
      else
        i = i + chunk
      end
    end
    if not progress then
      if chunk == 1 then
        break
      end
      chunk = math.max(1, math.floor(chunk / 2))
    end
  end
  return cur.lines, cur.keep
end

--- A failure report: the seed, how to replay it, the generated input and,
--- when shrinking found a smaller one, the minimal input.
---@param seed integer
---@param msg string
---@param input string[]
---@param minimal? string[]
---@param extra? string
function M.report(seed, msg, input, minimal, extra)
  local t = {
    ("seed %d: %s"):format(seed, msg),
    "replay: " .. M.replay(seed),
    "input = " .. M.dump(input),
  }
  if minimal and #minimal < #input then
    t[#t + 1] = "minimal input = " .. M.dump(minimal)
  end
  if extra then
    t[#t + 1] = extra
  end
  return table.concat(t, "\n")
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------

local WORDS = {
  "alpha",
  "beta",
  "gamma",
  "Delta",
  "task",
  "note",
  "x",
  "*bold*",
  "/it/",
  "=verb=",
  "~code~",
  "+strike+",
  "_under_",
  "ünïcödé",
  "日本語",
  "emoji🙂",
  "Ωμέγα",
  "a:b",
  "::",
  "[1/2]",
  "[50%]",
  "\\alpha",
  "$x^2$",
  "src_lua{1}",
  "call_f()",
  "@@html:<b>@@",
  "{{{macro(1)}}}",
  "<<target>>",
  "<<<radio>>>",
  "--",
  "...",
  "#",
  "*",
  "|",
  ":",
}
local KEYWORDS = { "TODO", "DONE", "NEXT", "WAITING" }
local TAGS = { "work", "home", "a_b", "@ctx", "ARCHIVE", "noexport", "ü" }
local DAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

local function words(rng, n)
  local t = {}
  for i = 1, n or rng:int(1, 6) do
    t[i] = rng:pick(WORDS)
  end
  return table.concat(t, " ")
end

--- A timestamp, sometimes a range, with repeaters and warnings.
function M.timestamp(rng, active)
  if active == nil then
    active = rng:chance(0.6)
  end
  local o, c = active and "<" or "[", active and ">" or "]"
  local function one()
    local s = ("%04d-%02d-%02d %s"):format(rng:int(1999, 2030), rng:int(1, 12), rng:int(1, 28), rng:pick(DAYS))
    if rng:chance(0.5) then
      s = s .. (" %02d:%02d"):format(rng:int(0, 23), rng:int(0, 59))
      if rng:chance(0.2) then
        s = s .. ("-%02d:%02d"):format(rng:int(0, 23), rng:int(0, 59))
      end
    end
    if rng:chance(0.25) then
      s = s .. " " .. rng:pick({ "+", "++", ".+" }) .. rng:int(1, 9) .. rng:pick({ "h", "d", "w", "m", "y" })
      if rng:chance(0.3) then
        s = s .. "/" .. rng:int(2, 9) .. rng:pick({ "d", "w" })
      end
    end
    if rng:chance(0.2) then
      s = s .. " " .. rng:pick({ "-", "--" }) .. rng:int(1, 9) .. rng:pick({ "d", "w" })
    end
    return o .. s .. c
  end
  local s = one()
  if rng:chance(0.15) then
    s = s .. "--" .. one()
  end
  if rng:chance(0.05) then
    s = s:sub(1, rng:int(1, #s)) -- truncated
  end
  return s
end

local function link(rng)
  local target = rng:pick({ "https://example.com/a?b=c", "file:x.org::*H", "id:abc-123", "#custom", "*Head", "fn:1" })
  if rng:chance(0.5) then
    return "[[" .. target .. "][" .. words(rng, 2) .. "]]"
  end
  return "[[" .. target .. "]]"
end

--- A line of paragraph text with inline objects.
function M.text(rng)
  local parts = { words(rng) }
  if rng:chance(0.2) then
    parts[#parts + 1] = link(rng)
  end
  if rng:chance(0.2) then
    parts[#parts + 1] = M.timestamp(rng)
  end
  if rng:chance(0.1) then
    parts[#parts + 1] = "[fn:" .. rng:int(1, 3) .. "]"
  end
  if rng:chance(0.05) then
    parts[#parts + 1] = "[fn::inline " .. words(rng, 2) .. "]"
  end
  if rng:chance(0.1) then
    parts[#parts + 1] = words(rng, 2)
  end
  local s = table.concat(parts, " ")
  if rng:chance(0.1) then
    s = string.rep(" ", rng:int(1, 4)) .. s
  end
  return s
end

local function headline(rng, level)
  local p = { string.rep("*", level) }
  if rng:chance(0.4) then
    p[#p + 1] = rng:pick(KEYWORDS)
  end
  if rng:chance(0.2) then
    p[#p + 1] = "[#" .. rng:pick({ "A", "B", "C", "1", "Z" }) .. "]"
  end
  if rng:chance(0.08) then
    p[#p + 1] = "COMMENT"
  end
  if rng:chance(0.95) then
    p[#p + 1] = words(rng, rng:int(1, 4))
  end
  if rng:chance(0.1) then
    p[#p + 1] = rng:pick({ "[/]", "[%]", "[1/3]", "[33%]" })
  end
  local s = table.concat(p, " ")
  if rng:chance(0.3) then
    local t = {}
    for i = 1, rng:int(1, 3) do
      t[i] = rng:pick(TAGS)
    end
    s = s .. string.rep(" ", rng:int(1, 8)) .. ":" .. table.concat(t, ":") .. ":"
  end
  if rng:chance(0.03) then
    s = s .. " " -- trailing space
  end
  return s
end

local function planning(rng)
  local p = {}
  for _, k in ipairs({ "CLOSED", "SCHEDULED", "DEADLINE" }) do
    if rng:chance(0.4) then
      p[#p + 1] = k .. ": " .. M.timestamp(rng, k ~= "CLOSED")
    end
  end
  if #p == 0 then
    p[1] = "SCHEDULED: " .. M.timestamp(rng, true)
  end
  return (rng:chance(0.2) and "  " or "") .. table.concat(p, " ")
end

local function properties(rng, out)
  out[#out + 1] = rng:chance(0.9) and ":PROPERTIES:" or ":properties:"
  for _ = 1, rng:int(0, 4) do
    local k = rng:pick({ "ID", "CUSTOM_ID", "Effort", "CATEGORY", "STYLE", "ORDERED", "A+", "with space", "" })
    out[#out + 1] = ":" .. k .. ":" .. (rng:chance(0.9) and (" " .. words(rng, rng:int(0, 2))) or "")
  end
  local r = rng:float()
  if r < 0.8 then
    out[#out + 1] = ":END:"
  elseif r < 0.9 then
    out[#out + 1] = ":end:"
  end -- else unterminated
end

local function clock(rng)
  local h1, h2 = rng:int(0, 11), rng:int(12, 23)
  local d = ("%04d-%02d-%02d %s"):format(rng:int(2000, 2030), rng:int(1, 12), rng:int(1, 28), rng:pick(DAYS))
  if rng:chance(0.15) then
    return ("CLOCK: [%s %02d:00]"):format(d, h1) -- running
  end
  return ("CLOCK: [%s %02d:00]--[%s %02d:30] => %2d:30"):format(d, h1, d, h2, h2 - h1)
end

local function logbook(rng, out)
  out[#out + 1] = ":LOGBOOK:"
  for _ = 1, rng:int(0, 4) do
    if rng:chance(0.7) then
      out[#out + 1] = clock(rng)
    else
      out[#out + 1] = '- State "DONE"       from "TODO"       ' .. M.timestamp(rng, false)
    end
  end
  if rng:chance(0.9) then
    out[#out + 1] = ":END:"
  end
end

local function list(rng, out, indent, depth)
  local kind = rng:pick({ "-", "+", "*", "1.", "1)", "a." })
  if indent == "" and kind == "*" then
    kind = "-" -- a star at column 0 is a headline
  end
  for i = 1, rng:int(1, 4) do
    local bullet = kind
    local n = kind:match("^%d") and tostring(i) or kind:match("^%a") and string.char(96 + i) or nil
    if n then
      bullet = n .. kind:sub(-1)
    end
    local s = indent .. bullet .. " "
    if n and rng:chance(0.1) then
      s = s .. "[@" .. rng:int(1, 20) .. "] "
    end
    if rng:chance(0.35) then
      s = s .. rng:pick({ "[ ] ", "[X] ", "[-] ", "[x] " })
    end
    if not n and rng:chance(0.15) then
      s = s .. words(rng, 1) .. " :: "
    end
    out[#out + 1] = s .. M.text(rng)
    if rng:chance(0.2) then
      out[#out + 1] = indent .. string.rep(" ", #bullet + 1) .. M.text(rng)
    end
    if rng:chance(0.1) then
      out[#out + 1] = ""
    end
    if depth < 3 and rng:chance(0.25) then
      list(rng, out, indent .. string.rep(" ", rng:pick({ 2, #bullet + 1, 4 })), depth + 1)
    end
  end
end

local function tbl(rng, out)
  local cols = rng:int(1, 4)
  local ind = rng:chance(0.2) and "  " or ""
  for r = 1, rng:int(1, 5) do
    if r == 2 and rng:chance(0.5) then
      out[#out + 1] = ind .. "|" .. string.rep("---+", cols - 1) .. "---|"
    end
    local cells = {}
    for c = 1, rng:int(1, cols + 1) do
      cells[c] = rng:chance(0.5) and tostring(rng:int(-50, 500)) or words(rng, rng:int(0, 2))
    end
    out[#out + 1] = ind .. "| " .. table.concat(cells, " | ") .. (rng:chance(0.85) and " |" or "")
  end
  if rng:chance(0.15) then
    out[#out + 1] = "#+TBLFM: $1=" .. rng:int(1, 9)
  end
end

local function block(rng, out)
  local name = rng:pick({ "src", "example", "quote", "center", "verse", "export", "comment", "SRC", "foo" })
  local head = "#+begin_" .. name
  if name:lower() == "src" then
    head = head .. " " .. rng:pick({ "lua", "sh", "python", "emacs-lisp", "" })
    if rng:chance(0.3) then
      head = head .. " :results output"
    end
  elseif name == "export" then
    head = head .. " html"
  end
  if rng:chance(0.2) then
    out[#out + 1] = "#+NAME: blk" .. rng:int(1, 9)
  end
  out[#out + 1] = (rng:chance(0.1) and "  " or "") .. head
  for _ = 1, rng:int(0, 4) do
    local r = rng:float()
    if r < 0.1 then
      out[#out + 1] = ",* not a headline"
    elseif r < 0.15 then
      out[#out + 1] = "* looks like a headline"
    elseif r < 0.2 then
      out[#out + 1] = ":END:"
    else
      out[#out + 1] = (rng:chance(0.3) and "  " or "") .. M.text(rng)
    end
  end
  if rng:chance(0.85) then
    out[#out + 1] = (rng:chance(0.3) and "#+END_" .. name:upper() or "#+end_" .. name)
  end
end

local function drawer(rng, out)
  out[#out + 1] = ":" .. rng:pick({ "NOTES", "note-s", "X" }) .. ":"
  for _ = 1, rng:int(0, 3) do
    out[#out + 1] = M.text(rng)
  end
  if rng:chance(0.85) then
    out[#out + 1] = rng:chance(0.8) and ":END:" or ":end:"
  end
end

--- Body elements of a section.
local function body(rng, out, level)
  for _ = 1, rng:int(0, 4) do
    local r = rng:float()
    if r < 0.25 then
      for _ = 1, rng:int(1, 3) do
        out[#out + 1] = M.text(rng)
      end
    elseif r < 0.4 then
      list(rng, out, rng:chance(0.1) and "  " or "", 0)
    elseif r < 0.5 then
      tbl(rng, out)
    elseif r < 0.62 then
      block(rng, out)
    elseif r < 0.67 then
      drawer(rng, out)
    elseif r < 0.72 then
      out[#out + 1] = "[fn:" .. rng:int(1, 3) .. "] " .. M.text(rng)
    elseif r < 0.77 then
      -- inline task (org-inlinetask-min-level is 15 by default)
      local lv = rng:chance(0.7) and 15 or rng:int(15, 17)
      out[#out + 1] = string.rep("*", lv) .. " " .. (rng:chance(0.5) and "TODO " or "") .. words(rng, 2)
      if rng:chance(0.5) then
        out[#out + 1] = M.text(rng)
        out[#out + 1] = string.rep("*", lv) .. " END"
      end
    elseif r < 0.8 then
      out[#out + 1] = rng:pick({ "-----", ": fixed width", "# comment", "#+KEYWORD: value", "\\begin{equation}" })
      if out[#out]:match("begin{") then
        out[#out + 1] = "x = 1"
        out[#out + 1] = "\\end{equation}"
      end
    elseif r < 0.85 then
      out[#out + 1] = clock(rng)
    elseif r < 0.9 then
      out[#out + 1] = rng:pick({ "*", "*bold* at start", "**", "*\t tab", " * indented star", "*** " })
    else
      for _ = 1, rng:int(1, 3) do
        out[#out + 1] = rng:chance(0.8) and "" or "   "
      end
    end
  end
  if level and rng:chance(0.1) then
    out[#out + 1] = ""
  end
end

local function entry(rng, out, level, depth, max_depth)
  out[#out + 1] = headline(rng, level)
  if rng:chance(0.3) then
    out[#out + 1] = planning(rng)
  end
  if rng:chance(0.3) then
    properties(rng, out)
  end
  if rng:chance(0.2) then
    logbook(rng, out)
  end
  body(rng, out, level)
  if depth < max_depth then
    for _ = 1, rng:int(0, 3) do
      local child = level + rng:int(1, rng:chance(0.8) and 1 or 3)
      entry(rng, out, child, depth + 1, max_depth)
    end
  end
end

---@class fuzz.DocOpts
---@field max_entries? integer top-level entries (default 4)
---@field max_depth? integer (default 3)
---@field crlf? boolean allow CRLF / BOM (default true)

--- A random Org document as lines.
---@param rng fuzz.Rng
---@param opts? fuzz.DocOpts
---@return string[]
function M.doc(rng, opts)
  opts = opts or {}
  local out = {}
  if rng:chance(0.3) then
    out[#out + 1] = "#+title: " .. words(rng, 2)
  end
  if rng:chance(0.1) then
    out[#out + 1] = "#+TODO: TODO NEXT | DONE"
  end
  if rng:chance(0.1) then
    out[#out + 1] = "#+STARTUP: " .. rng:pick({ "overview", "content", "showall", "indent" })
  end
  if rng:chance(0.1) then
    properties(rng, out)
  end
  if rng:chance(0.5) then
    body(rng, out)
  end
  for _ = 1, rng:int(0, opts.max_entries or 4) do
    entry(rng, out, rng:chance(0.85) and 1 or rng:int(2, 3), 0, opts.max_depth or 3)
  end
  if opts.crlf ~= false then
    if rng:chance(0.05) then
      out[1] = "\239\187\191" .. (out[1] or "")
    end
    if rng:chance(0.05) then
      for i, l in ipairs(out) do
        out[i] = l .. "\r"
      end
    end
  end
  return out
end

--- One random entry (a headline and its body) as lines, for mutations.
function M.entry(rng, level)
  local out = {}
  entry(rng, out, level or rng:int(1, 3), 2, 3)
  return out
end

--- A random line of any kind.
function M.line(rng)
  local r = rng:float()
  if r < 0.2 then
    return headline(rng, rng:int(1, 4))
  elseif r < 0.3 then
    return planning(rng)
  elseif r < 0.4 then
    return rng:pick({ ":PROPERTIES:", ":END:", ":LOGBOOK:", ":end:", "#+begin_src lua", "#+end_src", "#+END_QUOTE" })
  elseif r < 0.5 then
    return ""
  elseif r < 0.6 then
    return "- " .. (rng:chance(0.4) and "[ ] " or "") .. M.text(rng)
  elseif r < 0.7 then
    return "| " .. words(rng, 2) .. " | " .. rng:int(1, 99) .. " |"
  end
  return M.text(rng)
end

--- `lines` with 1-3 random line edits (insert / delete / change / insert
--- an entry). Returns a copy.
function M.mutate(rng, lines)
  local out = vim.deepcopy(lines)
  for _ = 1, rng:int(1, 3) do
    local r = rng:float()
    local i = rng:int(math.max(#out, 1))
    if r < 0.3 and #out > 0 then
      table.remove(out, i)
    elseif r < 0.6 then
      table.insert(out, math.min(i, #out + 1), M.line(rng))
    elseif r < 0.8 and #out > 0 then
      out[i] = out[i] .. " " .. words(rng, 1)
    else
      for j, l in ipairs(M.entry(rng)) do
        table.insert(out, math.min(i, #out + 1) + j - 1, l)
      end
    end
  end
  return out
end

--- Lines as a Lua literal, to paste a failing input into a regression spec.
function M.dump(lines)
  local t = {}
  for i, l in ipairs(lines) do
    t[i] = ("  %q,"):format(l)
  end
  return "{\n" .. table.concat(t, "\n") .. "\n}"
end

return M
