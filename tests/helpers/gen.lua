-- Pathological Org input for the perf budgets (tests/spec/perf_budgets_spec.lua)
-- and for benchmarking by hand:
--
--   local gen = require("tests.helpers.gen")
--   local lines = gen.headlines(10000)
--
-- Every generator is deterministic (no randomness), so a timing compares the
-- same text from run to run, and returns a list of lines.
local M = {}

local WORDS = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }

--- `n` characters of plain prose.
function M.prose(n)
  local parts, len, i = {}, 0, 0
  while len < n do
    i = i + 1
    local w = WORDS[(i - 1) % #WORDS + 1]
    parts[#parts + 1] = w
    len = len + #w + 1
  end
  return table.concat(parts, " "):sub(1, n)
end

--- `n` characters of prose that is mostly markup: emphasis, verbatim,
--- links, timestamps, footnotes, entities, macros.
function M.marked(n)
  local pieces = {
    "*bold*",
    "/italic/",
    "=verb=",
    "~code~",
    "+strike+",
    "_under_",
    "[[https://example.com/a][link]]",
    "[[file:x.org][file]]",
    "<2026-10-05 Mon 10:00>",
    "[2026-10-05 Mon]",
    "[fn:: note]",
    "\\alpha",
    "{{{title}}}",
    "=code=",
    "@@html:<b>@@",
    "word",
  }
  local parts, len, i = {}, 0, 0
  while len < n do
    i = i + 1
    local p = pieces[(i - 1) % #pieces + 1]
    parts[#parts + 1] = p
    len = len + #p + 1
  end
  return table.concat(parts, " "):sub(1, n)
end

--- `n` characters of unbalanced markup characters, the worst case for
--- regexps that look for a closing marker: `* / = ~ + _ [[ <`.
function M.markers(n)
  local chunk = "*a /b =c ~d +e _f [[g <h *i/ =j~ [fn: {{{ "
  return string.rep(chunk, math.ceil(n / #chunk)):sub(1, n)
end

--- `n` characters without a blank (a hash or a minified blob).
function M.blob(n)
  local chunk = "a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ+-"
  return string.rep(chunk, math.ceil(n / #chunk)):sub(1, n)
end

--- One file with a headline and each kind of long line, `n` chars each.
function M.long_lines(n)
  return {
    "* Long lines",
    M.blob(n),
    "",
    M.prose(n),
    "",
    M.marked(n),
    "",
    M.markers(n),
    "",
    "- " .. M.prose(n) .. " :: term",
    "",
    "| " .. M.prose(n) .. " |",
    "",
    "** " .. M.prose(n) .. " :tag:",
    "after",
  }
end

--- Headlines nested `depth` levels deep, each with a body line.
function M.deep_headlines(depth)
  local out = {}
  for l = 1, depth do
    out[#out + 1] = string.rep("*", l) .. " Level " .. l
    out[#out + 1] = "text " .. l
  end
  return out
end

--- A plain list nested `depth` levels deep, and back out.
function M.deep_list(depth)
  local out = { "* Lists" }
  for l = 1, depth do
    out[#out + 1] = string.rep("  ", l - 1) .. "- item " .. l
  end
  for l = depth, 1, -1 do
    out[#out + 1] = string.rep("  ", l - 1) .. "- back " .. l
  end
  return out
end

--- Blocks and drawers nested `depth` levels deep (blocks inside special
--- blocks, a drawer inside each).
function M.deep_blocks(depth)
  local out = { "* Blocks" }
  for l = 1, depth do
    out[#out + 1] = "#+begin_b" .. l
    out[#out + 1] = ":D" .. l .. ":"
    out[#out + 1] = "in " .. l
    out[#out + 1] = ":END:"
  end
  out[#out + 1] = "#+begin_src lua"
  out[#out + 1] = "print(1)"
  out[#out + 1] = "#+end_src"
  for l = depth, 1, -1 do
    out[#out + 1] = "#+end_b" .. l
  end
  return out
end

--- `n` headlines with TODO keywords, priorities, tags, planning,
--- properties, a logbook with clocks, and a body. About 12 lines each.
function M.headlines(n)
  local out = { "#+TITLE: Big", "#+FILETAGS: :big:", "" }
  local kws = { "TODO", "DONE", "", "TODO", "" }
  for i = 1, n do
    local level = (i % 3) + 1
    local kw = kws[i % #kws + 1]
    local day = (i % 28) + 1
    local month = (i % 12) + 1
    out[#out + 1] = ("%s %s%s[#%s] Task number %d :t%d:shared:"):format(
      string.rep("*", level),
      kw,
      kw ~= "" and " " or "",
      ({ "A", "B", "C" })[i % 3 + 1],
      i,
      i % 50
    )
    if i % 2 == 0 then
      out[#out + 1] = ("SCHEDULED: <2026-%02d-%02d Mon 09:00> DEADLINE: <2026-%02d-%02d Tue>"):format(
        month,
        day,
        month,
        (day % 28) + 1
      )
    end
    out[#out + 1] = ":PROPERTIES:"
    out[#out + 1] = ":ID: id-" .. i
    out[#out + 1] = ":EFFORT: 1:00"
    out[#out + 1] = ":END:"
    out[#out + 1] = ":LOGBOOK:"
    out[#out + 1] = ("CLOCK: [2026-%02d-%02d Mon 09:00]--[2026-%02d-%02d Mon 10:30] =>  1:30"):format(
      month,
      day,
      month,
      day
    )
    out[#out + 1] = ":END:"
    out[#out + 1] = "Body with a [[https://example.com/" .. i .. "][link]] and *bold* text."
    out[#out + 1] = "- item one"
    out[#out + 1] = "- [ ] item two"
  end
  return out
end

--- A table of `rows` x `cols`, with a header, and optionally a #+TBLFM.
function M.table(rows, cols, opts)
  opts = opts or {}
  local out = { "* Table" }
  local head = {}
  for c = 1, cols do
    head[c] = "h" .. c
  end
  out[#out + 1] = "| " .. table.concat(head, " | ") .. " |"
  out[#out + 1] = "|" .. string.rep("---+", cols - 1) .. "---|"
  for r = 1, rows do
    local cells = {}
    for c = 1, cols do
      cells[c] = tostring(r * c)
    end
    if opts.long_cell and r == 1 then
      cells[1] = M.prose(opts.long_cell)
    end
    out[#out + 1] = "|" .. table.concat(cells, "|") .. "|"
  end
  if opts.formula then
    out[#out + 1] = "#+TBLFM: " .. opts.formula
  end
  return out
end

--- `blocks` Lua src blocks of `size` lines each, under a headline every 10
--- blocks, with a paragraph between blocks (a literate config).
function M.src_blocks(blocks, size)
  local out = {}
  for b = 1, blocks do
    if b % 10 == 1 then
      out[#out + 1] = "* Section " .. b
    end
    out[#out + 1] = "Block " .. b .. ": " .. M.prose(60)
    out[#out + 1] = "#+begin_src lua"
    for i = 1, size do
      local k = i % 4
      if k == 0 then
        out[#out + 1] = ("local v%d = { name = %q, n = %d } -- entry %d"):format(i, WORDS[i % #WORDS + 1], i, i)
      elseif k == 1 then
        out[#out + 1] = ("if v%d and v%d.n > %d then return %q end"):format(i - 1, i - 1, i, "s" .. i)
      elseif k == 2 then
        out[#out + 1] = ("local function f%d(a, b) return a .. b, %d end"):format(i, i)
      else
        out[#out + 1] = ('print(f%d(%q, "x"), #{ 1, 2, 3 })'):format(i - 1, WORDS[i % #WORDS + 1])
      end
    end
    out[#out + 1] = "#+end_src"
  end
  return out
end

--- `n` lines: headlines every 20 lines, prose in between (a big notes file).
function M.big_file(n)
  local out = {}
  for i = 1, n do
    if i % 20 == 1 then
      out[i] = string.rep("*", (math.floor(i / 20) % 3) + 1) .. " Section " .. i
    else
      out[i] = M.prose(60 + (i % 20))
    end
  end
  return out
end

--- A paragraph of `n` lines with links, targets and footnote references,
--- then the definitions.
function M.links_footnotes(n)
  local out = { "* Links" }
  for i = 1, n do
    out[#out + 1] = ("See [[https://example.com/%d][site %d]], [[file:f%d.org]], <<t%d>> [[t%d]] and a note[fn:%d]."):format(
      i,
      i,
      i,
      i,
      i,
      i
    )
  end
  out[#out + 1] = "* Footnotes"
  for i = 1, n do
    out[#out + 1] = ("[fn:%d] Note %d."):format(i, i)
  end
  return out
end

return M
