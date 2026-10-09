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
  local res = { emacs = e, ours = o, hunks = {}, unknown = {} }
  for _, l in ipairs(e) do
    if l:match("^!error") then
      res.emacs_error = l
      return res
    end
  end
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
      -- two known differences in one hunk: every applicable rewrite at once
      local a, b, first = table.concat(h.emacs, "\n"), table.concat(h.ours, "\n"), nil
      for _, k in ipairs(known) do
        if k.same and M.matches({ oracle = k.oracle, input = k.input }, oracle, h, opts.input) then
          a, b, first = k.same(a), k.same(b), first or k
        end
      end
      if first and a == b then
        h.known = first
      end
    end
    res.hunks[#res.hunks + 1] = h
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
