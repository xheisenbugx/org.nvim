---@mod org.extensions.drill.cloze Cloze deletions in org-drill syntax
---
--- A cloze is text in single square brackets, `[Paris]`, optionally with a
--- hint after `||`: `[Paris||capital]`. Other bracketed Org syntax is not a
--- cloze: links `[[...]]`, timestamps `[2026-09-29 Tue]`, checkboxes `[ ]`
--- `[X]` `[-]`, statistics cookies `[1/3]` `[50%]`, footnotes `[fn:1]` and
--- priorities `[#A]`.

local M = {}

M.HINT_SEPARATOR = "||"

local function is_cloze_text(s)
  if s == "" or s:match("^%s") or s:find("[", 1, true) then
    return false
  end
  if s:match("^[ Xx%-]$") then
    return false -- checkbox
  end
  if s:match("^%d*/%d*$") or s:match("^%d*%%$") then
    return false -- statistics cookie
  end
  if s:match("^%d%d%d%d%-%d%d?%-%d%d?") then
    return false -- timestamp
  end
  if s:match("^fn:") or s:match("^#.$") or s:match("^cite[:/]") then
    return false
  end
  return true
end

---@class org.drill.Cloze
---@field s integer 1-based byte column of `[`
---@field e integer 1-based byte column of `]`
---@field text string the hidden text
---@field hint string|nil

--- The clozes of one line, left to right.
---@param line string
---@return org.drill.Cloze[]
function M.parse(line)
  local out = {}
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "[" and line:sub(i + 1, i + 1) == "[" then
      -- a link: skip to its end
      local e = line:find("]]", i + 2, true)
      i = e and e + 2 or n + 1
    elseif c == "[" then
      local e = line:find("]", i + 1, true)
      if not e then
        break
      end
      local inner = line:sub(i + 1, e - 1)
      if line:sub(e + 1, e + 1) ~= "]" and is_cloze_text(inner) then
        local text, hint = inner, nil
        local hs = inner:find(M.HINT_SEPARATOR, 1, true)
        if hs then
          text, hint = inner:sub(1, hs - 1), inner:sub(hs + #M.HINT_SEPARATOR)
          if hint == "" then
            hint = nil
          end
        end
        out[#out + 1] = { s = i, e = e, text = text, hint = hint }
        i = e + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

--- Does any of `lines` hold a cloze?
---@param lines string[]
---@return boolean
function M.has_any(lines)
  for _, l in ipairs(lines) do
    if #M.parse(l) > 0 then
      return true
    end
  end
  return false
end

--- The text shown for a hidden cloze: `[...]`, or `[hint...]`.
---@param c org.drill.Cloze
---@return string
function M.hidden_text(c)
  return c.hint and ("[" .. c.hint .. "...]") or "[...]"
end

return M
