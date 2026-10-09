-- Shrinking a document that differs from Emacs to a small one that still
-- does: whole subtrees first, then lines (delta debugging,
-- tests/helpers/fuzz.lua's shrink), then words within the lines left.

local fuzz = require("tests.helpers.fuzz")

local M = {}

--- The line ranges of the subtrees of `lines`, outermost first.
local function subtrees(lines)
  local out = {}
  for i, l in ipairs(lines) do
    local stars = l:match("^(%*+)%s")
    if stars then
      local j = i + 1
      while j <= #lines do
        local s = lines[j]:match("^(%*+)%s")
        if s and #s <= #stars then
          break
        end
        j = j + 1
      end
      out[#out + 1] = { i, j - 1, #stars }
    end
  end
  table.sort(out, function(a, b)
    if a[3] ~= b[3] then
      return a[3] < b[3]
    end
    return a[1] < b[1]
  end)
  return out
end

local function without(lines, i, j)
  local out = {}
  for k, l in ipairs(lines) do
    if k < i or k > j then
      out[#out + 1] = l
    end
  end
  return out
end

--- The smallest version of `lines` found for which `fails` still holds,
--- in at most `budget` calls of `fails` (default 400).
---@param lines string[]
---@param fails fun(lines: string[]): boolean
---@param budget? integer
---@return string[] lines, integer calls
function M.minimise(lines, fails, budget)
  budget = budget or 400
  local calls = 0
  local function try(cand)
    if calls >= budget then
      return false
    end
    calls = calls + 1
    local okc, res = pcall(fails, cand)
    return okc and res
  end
  local cur = lines

  -- subtrees
  local progress = true
  while progress and calls < budget do
    progress = false
    for _, r in ipairs(subtrees(cur)) do
      local cand = without(cur, r[1], r[2])
      if #cand > 0 and try(cand) then
        cur, progress = cand, true
        break
      end
    end
  end

  -- lines
  if calls < budget then
    cur = fuzz.shrink(cur, function(cand)
      return try(cand)
    end, nil, budget - calls)
  end

  -- words: drop one space-separated word at a time, last first
  for i = 1, #cur do
    local j = 0
    while calls < budget do
      local words = vim.split(cur[i], " ", { plain = true })
      j = j + 1
      local k = #words - j + 1
      if k < 1 then
        break
      end
      table.remove(words, k)
      local cand = vim.deepcopy(cur)
      cand[i] = table.concat(words, " ")
      if cand[i] ~= cur[i] and try(cand) then
        cur = cand
        j = j - 1
      end
    end
  end

  -- blank lines left over
  local i = 1
  while i <= #cur and calls < budget do
    if cur[i]:match("^%s*$") then
      local cand = without(cur, i, i)
      if try(cand) then
        cur = cand
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return cur, calls
end

return M
