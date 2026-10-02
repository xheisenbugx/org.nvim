---@mod org.extensions.transclusion.highlight Highlighted chunks for virtual lines
---
--- Virtual lines can't use the buffer's syntax, so transcluded text is
--- split into `{ text, hl_group }` chunks here: an approximation of org
--- highlighting (headlines, TODO keywords, tags, keywords, blocks,
--- drawers, lists, links, emphasis and timestamps) with tree-sitter
--- colours for code when a parser is installed.

local M = {}

local EMPHASIS = {
  ["*"] = "OrgBold",
  ["/"] = "OrgItalic",
  ["_"] = "OrgUnderline",
  ["+"] = "OrgStrikethrough",
  ["="] = "OrgVerbatim",
  ["~"] = "OrgCode",
}

-- one UTF-8 character
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- `s` with its tabs expanded to the next tab stop, `col` display cells
-- into the line; returns the new text and the column after it
local function tabs(s, col)
  if not s:find("\t", 1, true) then
    return s, col + vim.api.nvim_strwidth(s)
  end
  local ts = vim.o.tabstop > 0 and vim.o.tabstop or 8
  local out = {}
  for ch in s:gmatch(CHAR) do
    if ch == "\t" then
      local n = ts - (col % ts)
      out[#out + 1] = string.rep(" ", n)
      col = col + n
    else
      out[#out + 1] = ch
      col = col + vim.api.nvim_strwidth(ch)
    end
  end
  return table.concat(out), col
end

--- Chunks of inline markup in `text` on a `base` group.
---@param text string
---@param base string|nil
---@return table[]
function M.inline(text, base)
  local out = {}
  local plain = {}
  local function flush()
    if #plain > 0 then
      out[#out + 1] = { table.concat(plain), base }
      plain = {}
    end
  end
  local function push(t, hl)
    flush()
    out[#out + 1] = { t, hl }
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    local rest = text:sub(i)
    local done = false
    if c == "[" then
      -- org-link-bracket-re: the target has no brackets, so a plain
      -- [[link]] doesn't run on into a later [[target][desc]]
      local s, e, target, desc = rest:find("^%[%[([^%[%]]+)%]%[(.-)%]%]")
      if target then
        push(desc, "OrgLink")
      else
        s, e, target = rest:find("^%[%[([^%[%]]+)%]%]")
        if target then
          push(target, "OrgLink")
        end
      end
      if not e then
        s, e = rest:find("^%[%d%d%d%d%-%d%d%-%d%d[^%]]-%]")
        if e then
          push(rest:sub(s, e), "OrgTimestampInactive")
        else
          s, e = rest:find("^%[[ Xx%-]%]")
          if e then
            push(rest:sub(s, e), "OrgCheckbox")
          end
        end
      end
      if e then
        i = i + e
        done = true
      end
    elseif c == "<" then
      local s, e = rest:find("^<%d%d%d%d%-%d%d%-%d%d[^>]->")
      if e then
        push(rest:sub(s, e), "OrgTimestamp")
        i = i + e
        done = true
      end
    elseif EMPHASIS[c] then
      local prev = i > 1 and text:sub(i - 1, i - 1) or ""
      local nxt = text:sub(i + 1, i + 1)
      if (prev == "" or prev:match("[%s%(%{'\"%-]")) and nxt ~= "" and not nxt:match("%s") then
        local j = i + 1
        local close
        while true do
          local k = text:find(c, j + 1, true)
          if not k then
            break
          end
          local before = text:sub(k - 1, k - 1)
          local after = text:sub(k + 1, k + 1)
          if not before:match("%s") and (after == "" or after:match("[%s%-%.,;:!%?'\"%)%}%[\\]")) then
            close = k
            break
          end
          j = k
        end
        if close then
          push(text:sub(i, close), EMPHASIS[c])
          i = close + 1
          done = true
        end
      end
    end
    if not done then
      plain[#plain + 1] = c
      i = i + 1
    end
  end
  flush()
  return out
end

local function append(dst, chunks)
  for _, c in ipairs(chunks) do
    dst[#dst + 1] = c
  end
  return dst
end

-- Highlighted ranges of the headline as written: the text is never
-- rebuilt, so COMMENT and the spacing before aligned tags stay.
local function headline(line, level, todo_cfg)
  local parts = require("org.parser").parse_headline_line(line, todo_cfg)
  local hl = "OrgHeadlineLevel" .. (((level - 1) % 8) + 1)
  local pos = line:match("^%*+ +()")
  local out = { { line:sub(1, pos - 1), hl } }
  local stop = #line + 1
  if #parts.tags > 0 then
    -- the tags as the parser found them, with the space before them
    stop = line:find("%s:[%w_@#%%:\128-\255]+:%s*$", pos - 1) + 1
  end
  local function ws()
    local e = line:match("^%s*()", pos)
    if e > pos then
      out[#out + 1] = { line:sub(pos, e - 1), hl }
      pos = e
    end
  end
  if parts.todo then
    local cfg = todo_cfg or require("org.todo_keywords").global()
    out[#out + 1] = { parts.todo, cfg:is_done(parts.todo) and "OrgDone" or "OrgTodo" }
    pos = pos + #parts.todo
    ws()
  end
  if parts.priority then
    local e = line:match("^%[#[^%]]+%]()", pos)
    out[#out + 1] = { line:sub(pos, e - 1), "OrgPriority" }
    pos = e
    ws()
  end
  if parts.commented then
    out[#out + 1] = { "COMMENT", hl }
    pos = pos + #"COMMENT"
    ws()
  end
  if stop > pos then
    append(out, M.inline(line:sub(pos, stop - 1), hl))
  end
  if stop <= #line then
    out[#out + 1] = { line:sub(stop), "OrgTags" }
  end
  return out
end

local function code_runs(code_lines, lang)
  if not lang or #code_lines == 0 then
    return nil
  end
  local ok, runs = pcall(require("org.export.fontify").runs, table.concat(code_lines, "\n"), lang)
  if not ok or not runs then
    return nil
  end
  local out = {}
  for i, r in ipairs(runs) do
    local chunks = {}
    for _, run in ipairs(r) do
      chunks[#chunks + 1] = { run[1], run[2] and ("@" .. run[2] .. "." .. lang) or "OrgBlock" }
    end
    out[i] = chunks
  end
  return out
end

--- Chunks of code lines in `lang` (plain when there is no parser).
---@param lines string[]
---@param lang string|nil
---@return table[][]
function M.code(lines, lang)
  local runs = code_runs(lines, lang) or {}
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = runs[i] or { { l, nil } }
  end
  return M.expand_tabs(out)
end

--- Chunks of org lines.
---@param lines string[]
---@param todo_cfg? org.TodoConfig the source file's TODO keywords
---@return table[][]
function M.org(lines, todo_cfg)
  local out = {}
  -- src blocks first, to highlight each block's code as a whole
  local code = {}
  local i = 1
  while i <= #lines do
    local lang = lines[i]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+([^%s]+)")
    if lang then
      local j = i + 1
      while j <= #lines and not lines[j]:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]%s*$") do
        j = j + 1
      end
      local runs = code_runs(vim.list_slice(lines, i + 1, j - 1), lang)
      if runs then
        for k = i + 1, j - 1 do
          code[k] = runs[k - i]
        end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  local block, drawer
  for idx, line in ipairs(lines) do
    local chunks
    local level = line:match("^(%*+) ")
    local lower = line:lower()
    if block then
      if lower:match("^%s*#%+end_") then
        block = nil
        chunks = { { line, "OrgBlockDelimiter" } }
      else
        chunks = code[idx] or { { line, block == "quote" and "OrgQuoteBlock" or "OrgBlock" } }
      end
    elseif level then
      chunks = headline(line, #level, todo_cfg)
    elseif lower:match("^%s*#%+begin_") then
      block = lower:match("^%s*#%+begin_(%S+)")
      chunks = { { line, "OrgBlockDelimiter" } }
    elseif line:match("^%s*#%+") then
      local lead, key, val = line:match("^(%s*#%+[^:%s]+:)(%s*)(.*)$")
      if lead then
        local isTitle = lead:lower():match("title:$")
        chunks = append({ { lead .. key, "OrgKeyword" } }, M.inline(val, isTitle and "OrgTitle" or "OrgKeywordValue"))
      else
        chunks = { { line, "OrgKeyword" } }
      end
    elseif line:match("^%s*#%s") or line:match("^%s*#$") then
      chunks = { { line, "OrgComment" } }
    elseif line:match("^%s*:[%w_%-]+:%s*$") then
      drawer = not line:match("^%s*:[Ee][Nn][Dd]:")
      chunks = { { line, "OrgDrawer" } }
    elseif drawer and line:match("^%s*:[^%s:]+:") then
      local key, val = line:match("^(%s*:[^%s:]+:)(.*)$")
      chunks = { { key, "OrgPropertyKey" }, { val, "OrgPropertyValue" } }
    elseif line:match("^%s*SCHEDULED:") or line:match("^%s*DEADLINE:") or line:match("^%s*CLOSED:") then
      chunks = M.inline(line, "OrgPlanning")
    elseif line:match("^%s*|") then
      chunks = { { line, "OrgTable" } }
    elseif line:match("^%s*:%s") or line:match("^%s*:$") then
      chunks = { { line, "OrgVerbatim" } }
    elseif line:match("^%s*%-%-%-%-%-+%s*$") then
      chunks = { { line, "OrgHorizontalRule" } }
    else
      local lead, bullet, rest = line:match("^(%s*)([%-+]%s)(.*)$")
      if not lead then
        lead, bullet, rest = line:match("^(%s+)(%*%s)(.*)$")
      end
      if not lead then
        lead, bullet, rest = line:match("^(%s*)(%d+[%.%)]%s)(.*)$")
      end
      if lead then
        chunks = append({ { lead, nil }, { bullet, "OrgListBullet" } }, M.inline(rest, nil))
      else
        chunks = M.inline(line, nil)
      end
    end
    out[idx] = chunks
  end
  return M.expand_tabs(out)
end

--- Expand the tabs of each line's chunks in place, tab stops counted in
--- display cells from the start of the line (as the source buffer shows).
function M.expand_tabs(lines)
  for _, chunks in ipairs(lines) do
    local col = 0
    for _, c in ipairs(chunks) do
      c[1], col = tabs(c[1], col)
    end
  end
  return lines
end

return M
