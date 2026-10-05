---@mod org.ui.images.scan Buffer elements
---
--- Just enough of org-element to find paragraphs, their affiliated
--- keywords and the blocks images are never shown in (scan).
--- Part of org.ui.images, which loads it.

local M = require("org.ui.images")

---------------------------------------------------------------------------
-- The elements of a buffer (just enough of org-element)
---------------------------------------------------------------------------

local OPAQUE_BLOCKS = { src = true, example = true, export = true, comment = true }
local PARSED_KEYWORDS = { title = true, caption = true, author = true, date = true, subtitle = true }
local AFFILIATED =
  { attr = true, name = true, caption = true, header = true, plot = true, results = true, label = true }

---@class org.images.Line
---@field skip? boolean no links or LaTeX fragments here
---@field para? integer paragraph id
---@field env? integer LaTeX environment id

--- Per line: what may hold previews, which paragraph it belongs to, and
--- the paragraphs' affiliated keywords (#+ATTR_ORG ...). Paragraphs of list
--- items get no keywords (those belong to the list).
---@return org.images.Line[] lines, table<integer, { first: integer, last: integer, attrs: string[] }> paras, table<integer, { first: integer, last: integer, name: string }> envs
function M.scan(lines)
  local info, paras, envs = {}, {}, {}
  local dynamic, props = false, false
  local pending = {} -- affiliated keyword lines waiting for their element
  local para -- current paragraph
  local function other(li, keep_pending)
    -- a line that is not part of a paragraph
    para = nil
    if not keep_pending then
      pending = {}
    end
    return li
  end
  local function text(li, i)
    if not para then
      para = #paras + 1
      paras[para] = { first = i, last = i, attrs = pending }
      pending = {}
    end
    paras[para].last = i
    li.para = para
  end
  -- The blocks the line is in, innermost last: { name, stop }. A block
  -- needs its #+end_ line before the next headline (and inside the block
  -- around it); without one, Emacs reads #+begin_ as paragraph text.
  local stack = {}
  local function limit()
    local top = stack[#stack]
    return top and top.stop - 1 or #lines
  end
  local function block_end(name, from)
    local pat = "^[ \t]*#%+end_" .. vim.pesc(name) .. "[ \t]*$"
    for r = from, limit() do
      if lines[r]:match("^%*+%s") then
        return nil
      end
      if lines[r]:lower():match(pat) then
        return r
      end
    end
  end
  local i = 1
  while i <= #lines do
    local l = lines[i]
    local low = l:lower()
    local li = {}
    info[i] = li
    local top = stack[#stack]
    local block = top and top.name
    local no_elements = block and (OPAQUE_BLOCKS[block] or block == "verse")
    local key = low:match("^%s*#%+([%w_-]+)%[?[^:]*%]?:")
    local env = l:match("^[ \t]*\\begin{([%w*]+)}")
    local begin = low:match("^%s*#%+begin_([%w_-]+)")
    local begin_stop = begin and not props and not no_elements and block_end(begin, i + 1)
    local stop
    if env and not no_elements and not props then
      for r = i + 1, limit() do
        if lines[r]:match("^%*+%s") then
          break
        end
        if lines[r]:lower():match("^[ \t]*\\end{" .. vim.pesc(env:lower()) .. "}[ \t]*$") then
          stop = r
          break
        end
      end
    end
    if top and i == top.stop then
      li.skip = true
      stack[#stack] = nil
      other(li)
    elseif block and OPAQUE_BLOCKS[block] then
      li.skip = true
    elseif block == "verse" then
      -- a verse block holds objects only: every line is text
      if l:match("^%s*$") then
        other(li)
      else
        text(li, i)
      end
    elseif props then
      li.skip = true
      if low:match("^%s*:end:%s*$") then
        props = false
      end
    elseif begin_stop then
      -- quote, center and special blocks hold elements of their own
      li.skip = true
      stack[#stack + 1] = { name = begin, stop = begin_stop }
      other(li)
    elseif low:match("^%s*#%+begin:") then
      li.skip, dynamic = true, true
      other(li)
    elseif dynamic and low:match("^%s*#%+end:") then
      li.skip, dynamic = true, false
      other(li)
    elseif key then
      local base = key:match("^attr_") and "attr" or key
      -- links and fragments show in parsed keywords (TITLE, CAPTION...)
      li.skip = not PARSED_KEYWORDS[key] or nil
      if AFFILIATED[base] then
        pending[#pending + 1] = l
        other(li, true)
      else
        other(li)
      end
    elseif l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%s*:%s") or l:match("^%s*:$") then
      li.skip = true -- comments, fixed-width lines
      other(li)
    elseif low:match("^%s*:properties:%s*$") then
      li.skip, props = true, true
      other(li)
    elseif l:match("^%s*:[%w_-]+:%s*$") or l:match("^%s*%-%-%-%-%-+%s*$") or l:match("^%s*CLOCK:") then
      li.skip = true -- drawer delimiters, rules, clock lines
      other(li)
    elseif l:match("^%s*$") then
      other(li)
    elseif stop then
      envs[#envs + 1] = { first = i, last = stop, name = env }
      for r = i, stop do
        info[r] = { env = #envs, skip = true }
      end
      other(li)
      i = stop
    elseif l:match("^%*+%s") or l:match("^%s*|") or l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") then
      -- headlines and table rows hold objects but no paragraph
      other(li)
    elseif l:match("^%s*[-+]%s") or l:match("^%s+%*%s") or l:match("^%s*%d+[.)]%s") or l:match("^%s*%a[.)]%s") then
      -- a list item starts a paragraph of its own; the keywords above
      -- belong to the list
      para = #paras + 1
      paras[para] = { first = i, last = i, attrs = {} }
      li.para = para
      pending = {}
    else
      text(li, i)
    end
    i = i + 1
  end
  return info, paras, envs
end
