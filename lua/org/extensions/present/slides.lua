---@mod org.extensions.present.slides Splitting a file into slides
---
--- Every headline of level `slide_level` or less starts a slide that runs to
--- the next such headline, so a deeper subtree stays on its parent's slide.
--- The lines before the first slide are the title slide.

local M = {}

---@class org.present.Slide
---@field first integer first line (1-based)
---@field last integer last line (1-based, inclusive)
---@field title boolean the title slide (lines before the first headline)
---@field level integer|nil headline level (nil for the title slide)

-- Keywords the title slide shows; other `#+KEY:` lines are hidden.
M.shown_keywords = { title = true, author = true, date = true, email = true, subtitle = true }

--- The keyword of a `#+KEY: value` line, lower-cased, and its value.
---@param line string
---@return string|nil key
---@return string|nil value
function M.keyword(line)
  local key, value = line:match("^%s*#%+([%w_%-]+):%s*(.-)%s*$")
  if key then
    return key:lower(), value
  end
end

--- Whether a title-slide line shows anything once keywords are hidden.
---@param line string
---@param hide_keywords boolean
local function visible(line, hide_keywords)
  if line:match("^%s*$") then
    return false
  end
  local key, value = M.keyword(line)
  if key then
    return M.shown_keywords[key] and value ~= "" or not hide_keywords
  end
  return true
end

--- Split `lines` into slides.
---@param lines string[]
---@param opts { slide_level?: integer, title_slide?: boolean, hide_keywords?: boolean }
---@return org.present.Slide[]
function M.split(lines, opts)
  local level = opts.slide_level or 1
  local parser = require("org.parser")
  local inline = parser.inlinetask_min_level()
  local starts = {}
  for _, hl in ipairs(parser.parse(lines).headlines) do
    if hl.level <= level and not (inline and hl.level >= inline) then
      starts[#starts + 1] = hl
    end
  end
  local slides = {}
  local first_heading = starts[1] and starts[1].line or #lines + 1
  if opts.title_slide ~= false and first_heading > 1 then
    for i = 1, first_heading - 1 do
      if visible(lines[i], opts.hide_keywords ~= false) then
        slides[1] = { first = 1, last = first_heading - 1, title = true }
        break
      end
    end
  end
  for i, hl in ipairs(starts) do
    local next_hl = starts[i + 1]
    slides[#slides + 1] = {
      first = hl.line,
      last = next_hl and next_hl.line - 1 or #lines,
      title = false,
      level = hl.level,
    }
  end
  return slides
end

--- Index of the slide containing line `lnum` (the first slide when the line
--- is on no slide, e.g. in a hidden preamble).
---@param slides org.present.Slide[]
---@param lnum integer
---@return integer
function M.find(slides, lnum)
  for i, s in ipairs(slides) do
    if lnum >= s.first and lnum <= s.last then
      return i
    end
  end
  return 1
end

return M
