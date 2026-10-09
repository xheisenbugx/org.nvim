-- Comparing an oracle's Emacs and org.nvim outputs: the NORMALISE rules of
-- tests/emacs_parity.lua, a line diff split into hunks, and each hunk
-- matched against the known differences (tests/difftest/known.lua).

local P = require("tests.emacs_parity")
local oracles = require("tests.difftest.oracles")

local M = {}

---@class difftest.Hunk
---@field emacs string[] the Emacs lines of the hunk
---@field ours string[] org.nvim's lines
---@field at integer first Emacs line
---@field known? table the known.lua entry it matches

---@class difftest.Result
---@field emacs string[] normalised Emacs lines
---@field ours string[] normalised org.nvim lines
---@field hunks difftest.Hunk[] every hunk
---@field unknown difftest.Hunk[] the hunks no known entry matches
---@field emacs_error? string Emacs raised an error: nothing compared
---@field skipped string[] Emacs' errors in sections (agenda views, S-TAB steps, tables) left out of the comparison

--- Normalised lines of both outputs. `dir` (the input's directory) is
--- written as @DIR@ on both sides.
function M.normalise(oracle, emacs, ours, dir)
  local function prep(s)
    if dir then
      s = s:gsub(vim.pesc(dir), "@DIR@")
    end
    return P.lines(s)
  end
  return P.normalise(oracles.area(oracle), prep(emacs), prep(ours))
end

--- Whether the known entry `k` (see tests/difftest/known.lua) matches
--- hunk `h` of `oracle`, for an input whose lines are `input`.
---@param k difftest.Known|{ oracle?: string, input?: string|function }
---@param oracle string
---@param h difftest.Hunk
---@param input? string[]
function M.matches(k, oracle, h, input)
  if k.oracle and not oracle:match("^" .. k.oracle .. "$") then
    return false
  end
  if k.emacs and not table.concat(h.emacs, "\n"):match(k.emacs) then
    return false
  end
  if k.ours and not table.concat(h.ours, "\n"):match(k.ours) then
    return false
  end
  if k.input then
    local found = false
    if type(k.input) == "function" then
      found = k.input(input or {})
    else
      for _, l in ipairs(input or {}) do
        if l:match(k.input) then
          found = true
          break
        end
      end
    end
    if not found then
      return false
    end
  end
  if k.either then
    local a, b = table.concat(h.emacs, "\n"), table.concat(h.ours, "\n")
    if not (a:match(k.either) or b:match(k.either)) then
      return false
    end
  end
  if k.same and k.same(table.concat(h.emacs, "\n")) ~= k.same(table.concat(h.ours, "\n")) then
    return false
  end
  return true
end

local SKIPPED = "!error skipped"

--- The "=== <name>" sections of an agenda or visibility output.
local function sections(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("^=== ") then
      out[#out + 1] = { name = l, lines = {} }
    elseif #out == 0 then
      return nil
    else
      table.insert(out[#out].lines, l)
    end
  end
  return out
end

local function first_error(lines)
  for _, l in ipairs(lines) do
    if l:match("^!error") then
      return l
    end
  end
end

--- Leave out of both sides what Emacs raised an error on: the agenda view
--- or S-TAB step whose section holds an "!error" line, or the table an
--- "!error" line follows (difftest.el puts it back unchanged), when the
--- rest still lines up. `skipped` gets the errors left out. Nil when
--- nothing is left to compare (or the sides don't line up).
---@return string[]?, string[]?
local function skip_errors(oracle, e, o, skipped)
  local err = first_error(e)
  if not err then
    return e, o
  end
  if oracle == "agenda" or oracle == "visibility" then
    local se, so = sections(e), sections(o)
    if not se or not so or #se ~= #so then
      return nil
    end
    local e2, o2, left = {}, {}, 0
    for i, s in ipairs(se) do
      if s.name ~= so[i].name then
        return nil
      end
      e2[#e2 + 1], o2[#o2 + 1] = s.name, s.name
      local serr = first_error(s.lines)
      if serr then
        skipped[#skipped + 1] = s.name:sub(5) .. ": " .. serr
        e2[#e2 + 1], o2[#o2 + 1] = SKIPPED, SKIPPED
      else
        left = left + 1
        vim.list_extend(e2, s.lines)
        vim.list_extend(o2, so[i].lines)
      end
    end
    if left == 0 then
      return nil
    end
    return e2, o2
  elseif oracle == "table" then
    local e2, at = {}, {}
    for _, l in ipairs(e) do
      if l:match("^!error") then
        at[#at + 1] = { #e2, l }
      else
        e2[#e2 + 1] = l
      end
    end
    if #e2 ~= #o then
      return nil
    end
    local o2 = vim.deepcopy(o)
    for _, x in ipairs(at) do
      local j = x[1]
      if j == 0 or not e2[j]:match("^%s*#%+TBLFM:") then
        return nil
      end
      while j >= 1 and (e2[j]:match("^%s*|") or e2[j]:match("^%s*#%+TBLFM:")) do
        e2[j], o2[j] = SKIPPED, SKIPPED
        j = j - 1
      end
      skipped[#skipped + 1] = x[2]
    end
    return e2, o2
  end
  return nil
end

--- Compare the outputs of `oracle`.
---@param oracle string
---@param emacs string Emacs' output
---@param ours string org.nvim's output
---@param opts? { dir?: string, known?: difftest.Known[], input?: string[] }
---@return difftest.Result
function M.compare(oracle, emacs, ours, opts)
  opts = opts or {}
  local known = opts.known or require("tests.difftest.known")
  local e, o = M.normalise(oracle, emacs, ours, opts.dir)
  local res = { emacs = e, ours = o, hunks = {}, unknown = {}, skipped = {} }
  local e2, o2 = skip_errors(oracle, e, o, res.skipped)
  if not e2 or not o2 then
    res.emacs_error = first_error(e)
    res.skipped = {}
    return res
  end
  e, o = e2, o2
  res.emacs, res.ours = e, o
  local a, b = table.concat(e, "\n") .. "\n", table.concat(o, "\n") .. "\n"
  if a == b then
    return res
  end
  local idx = vim.diff(a, b, { result_type = "indices", algorithm = "histogram" }) --[[@as integer[][] ]]
  for _, d in ipairs(idx) do
    local h = {
      at = d[1],
      emacs = vim.list_slice(e, d[1], d[1] + d[2] - 1),
      ours = vim.list_slice(o, d[3], d[3] + d[4] - 1),
    }
    for _, k in ipairs(known) do
      if M.matches(k, oracle, h, opts.input) then
        h.known = k
        break
      end
    end
    if not h.known then
      -- two known differences in one hunk: every applicable rewrite at
      -- once, the broad ones (erasing digits, sorting lines) last so that
      -- they don't stop the narrower ones from applying
      local a, b, first = table.concat(h.emacs, "\n"), table.concat(h.ours, "\n"), nil
      for pass = 1, 2 do
        for _, k in ipairs(known) do
          if
            k.same
            and (pass == 2) == (k.broad == true)
            and M.matches({ oracle = k.oracle, input = k.input }, oracle, h, opts.input)
          then
            a, b, first = k.same(a), k.same(b), first or k
          end
        end
      end
      if first and a == b then
        h.known = first
      end
    end
    res.hunks[#res.hunks + 1] = h
  end
  -- lines moved from one hunk to another: the hunks left, all together
  local left = vim.tbl_filter(function(h)
    return not h.known
  end, res.hunks)
  if #left > 1 then
    local a, b = {}, {}
    for _, h in ipairs(left) do
      vim.list_extend(a, h.emacs)
      vim.list_extend(b, h.ours)
    end
    a, b = table.concat(a, "\n"), table.concat(b, "\n")
    for _, k in ipairs(known) do
      if k.moves and k.same and M.matches({ oracle = k.oracle, input = k.input }, oracle, left[1], opts.input) then
        if k.same(a) == k.same(b) then
          for _, h in ipairs(left) do
            h.known = k
          end
          break
        end
      end
    end
  end
  for _, h in ipairs(res.hunks) do
    if not h.known then
      res.unknown[#res.unknown + 1] = h
    end
  end
  return res
end

--- A unified diff of a result (Emacs: -, org.nvim: +).
---@param res difftest.Result
function M.unified(res)
  local d = vim.diff(table.concat(res.emacs, "\n") .. "\n", table.concat(res.ours, "\n") .. "\n", {
    algorithm = "histogram",
    ctxlen = 2,
  }) --[[@as string]]
  return "--- emacs\n+++ org.nvim\n" .. d
end

--- What kind of difference a hunk is, to group failures and to keep
--- shrinking on the same one: the words only one side has, by shape
--- (letters as "a", digits as "#"), or "whitespace".
---@param oracle string
---@param h difftest.Hunk
function M.signature(oracle, h)
  local function words(lines)
    local t = {}
    for _, l in ipairs(lines) do
      for w in l:gmatch("%S+") do
        w = w:gsub("%a+", "a"):gsub("%d+", "#")
        t[w] = (t[w] or 0) + 1
      end
    end
    return t
  end
  local function minus(a, b)
    local out = {}
    for w, n in pairs(a) do
      for _ = 1, n - (b[w] or 0) do
        out[#out + 1] = w
      end
    end
    table.sort(out)
    return table.concat(out, " ")
  end
  local e, o = words(h.emacs), words(h.ours)
  local removed, added = minus(e, o), minus(o, e)
  if removed == "" and added == "" then
    -- the shape of the first line that differs, punctuation kept
    local l = h.emacs[1] or h.ours[1] or ""
    l = l:gsub("%a+", "a"):gsub("%d+", "#"):gsub("[\128-\255]+", "u"):gsub("%s+", " ")
    return oracle .. "|whitespace " .. vim.trim(l):sub(1, 40)
  end
  return (oracle .. "|" .. removed .. " => " .. added):sub(1, 200)
end

return M
