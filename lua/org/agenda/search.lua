---@mod org.agenda.search Tags / property / TODO match expressions
---
--- Implements the Emacs `org-make-tags-matcher` syntax:
---
---   +work-boss               tag work, not tag boss
---   work&urgent|home         (work AND urgent) OR home
---   {^proj}                  a tag matching a regexp
---   PRIORITY="A" LEVEL>1     property comparisons (= <> != < <= > >=)
---   Effort<60 TODO="WAIT"    numbers compare numerically
---   SCHEDULED<="<today>"     dates: <today> <tomorrow> <+2d> <2026-01-01>
---   CATEGORY={^w}            regexp property match
---   .../TODO|NEXT            TODO part: keywords (OR), -KW excludes
---   .../!                    only not-done TODO entries (`/!-WAIT` etc.)

local date = require("org.date")
local utils = require("org.utils")

local M = {}

local OPS = { "<=", ">=", "<>", "!=", "==", "=", "<", ">" }

local function parse_value(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    local j = s:find('"', i + 1, true)
    if not j then
      error("unterminated string in match: " .. s)
    end
    local v = s:sub(i + 1, j - 1)
    if v:match("^[<%[].*[>%]]$") then
      return { kind = "date", value = v }, j + 1
    end
    return { kind = "string", value = v }, j + 1
  elseif c == "{" then
    local j = s:find("}", i + 1, true)
    if not j then
      error("unterminated regexp in match: " .. s)
    end
    return { kind = "regex", value = s:sub(i + 1, j - 1) }, j + 1
  end
  local num = s:match("^%-?%d+%.?%d*", i)
  if num then
    return { kind = "number", value = tonumber(num) }, i + #num
  end
  local word = s:match("^[^&|%s]+", i) or ""
  return { kind = "string", value = word }, i + #word
end

local function compile_regex(re)
  local ok, r = pcall(vim.regex, re)
  if not ok then
    error("invalid regexp {" .. re .. "}")
  end
  return r
end

--- Resolve a date match value: "<today>", "<+2d>", "<2026-01-01>", "<now>".
function M.resolve_date(v)
  local inner = v:sub(2, -2)
  local lower = inner:lower()
  if lower == "now" then
    return date.now()
  elseif lower == "today" then
    return date.today()
  elseif lower == "tomorrow" then
    return date.today():add(1, "d")
  elseif lower == "yesterday" then
    return date.today():add(-1, "d")
  end
  local rel_sign, n, unit = lower:match("^([%+%-])(%d+)([hdwmy]?)$")
  if rel_sign then
    n = tonumber(n) * (rel_sign == "-" and -1 or 1)
    return date.today():add(n, unit ~= "" and unit or "d")
  end
  local parsed = date.parse("<" .. inner .. ">")
  if parsed then
    return parsed
  end
  return date.read_date(inner)
end

--- Parse one AND-group of tag/property terms.
local function parse_group(g)
  local terms = {}
  local i = 1
  local n = #g
  while i <= n do
    local c = g:sub(i, i)
    if c == "&" or c:match("%s") then
      i = i + 1
    else
      local neg = false
      if c == "+" or c == "-" then
        neg = c == "-"
        i = i + 1
        c = g:sub(i, i)
      end
      if c == "{" then
        local j = g:find("}", i + 1, true)
        if not j then
          error("unterminated regexp in match: " .. g)
        end
        terms[#terms + 1] = { kind = "tagre", neg = neg, re = compile_regex(g:sub(i + 1, j - 1)) }
        i = j + 1
      else
        local name = g:match("^[%w_@#%%%.:]+", i)
        if not name then
          error("unexpected character '" .. c .. "' in match: " .. g)
        end
        i = i + #name
        local op
        for _, o in ipairs(OPS) do
          if g:sub(i, i + #o - 1) == o then
            op = o
            break
          end
        end
        if op then
          i = i + #op
          local value
          value, i = parse_value(g, i)
          if value.kind == "regex" then
            value.re = compile_regex(value.value)
          elseif value.kind == "date" then
            value.date = M.resolve_date(value.value)
            if not value.date then
              error("invalid date in match: " .. value.value)
            end
          end
          if op == "==" then
            op = "="
          elseif op == "!=" then
            op = "<>"
          end
          terms[#terms + 1] = { kind = "prop", neg = neg, name = name:upper(), op = op, value = value }
        else
          terms[#terms + 1] = { kind = "tag", neg = neg, name = name }
        end
      end
    end
  end
  return terms
end

local function cmp(a, b, op)
  if op == "=" then
    return a == b
  elseif op == "<>" then
    return a ~= b
  elseif op == "<" then
    return a < b
  elseif op == "<=" then
    return a <= b
  elseif op == ">" then
    return a > b
  elseif op == ">=" then
    return a >= b
  end
  return false
end

--- Raw value of a property for matching.
local function prop_value(hl, name)
  if name == "LEVEL" then
    return hl.level
  elseif name == "TODO" then
    return hl.todo
  elseif name == "SCHEDULED" or name == "DEADLINE" or name == "CLOSED" then
    return hl.planning[name:lower()]
  elseif name == "TIMESTAMP" then
    return hl.timestamps[1] and hl.timestamps[1].date or nil
  elseif name == "ITEM" then
    return hl.title
  end
  return hl:get_property(name)
end

local function eval_prop(hl, t)
  local v = prop_value(hl, t.name)
  local val = t.value
  if val.kind == "regex" then
    local matched = v ~= nil and val.re:match_str(tostring(v)) ~= nil
    if t.op == "<>" then
      return not matched
    end
    return matched
  elseif val.kind == "number" then
    local n = tonumber(v) or 0
    if type(v) == "string" and not tonumber(v) then
      local dur = date.parse_duration(v)
      n = dur or 0
    end
    return cmp(n, val.value, t.op)
  elseif val.kind == "date" then
    local d = v
    if type(v) == "string" then
      d = date.parse(v)
    end
    if type(d) ~= "table" then
      return false
    end
    local a = d:has_time() and d:minutes() or d:days() * 1440
    local b = val.date:has_time() and val.date:minutes() or val.date:days() * 1440
    return cmp(a, b, t.op)
  else
    return cmp(v ~= nil and tostring(v) or "", val.value, t.op)
  end
end

local function eval_term(hl, t, tags)
  local r
  if t.kind == "tag" then
    r = tags[t.name] == true
  elseif t.kind == "tagre" then
    r = false
    for tag in pairs(tags) do
      if t.re:match_str(tag) then
        r = true
        break
      end
    end
  else
    r = eval_prop(hl, t)
  end
  if t.neg then
    return not r
  end
  return r
end

--- Compile the TODO part ("TODO|NEXT", "!-WAIT", "-DONE").
local function compile_todo(s)
  local only_todo = false
  if s:sub(1, 1) == "!" then
    only_todo = true
    s = s:sub(2)
  end
  local groups = {}
  for g in (s .. "|"):gmatch("([^|]*)|") do
    local terms = {}
    for sign, kw in g:gmatch("([%+%-]?)([^&%+%-%s]+)") do
      terms[#terms + 1] = { neg = sign == "-", kw = kw }
    end
    if #terms > 0 then
      groups[#groups + 1] = terms
    end
  end
  return function(hl)
    if only_todo and not hl:is_todo() then
      return false
    end
    if #groups == 0 then
      return true
    end
    for _, terms in ipairs(groups) do
      local all = true
      for _, t in ipairs(terms) do
        local r = hl.todo == t.kw
        if t.neg then
          r = not r
        end
        if not r then
          all = false
          break
        end
      end
      if all then
        return true
      end
    end
    return false
  end
end

--- Compile a match string into predicate(headline) -> boolean.
--- Errors (invalid syntax) are raised; use `M.try_compile` for (nil, err).
---@param match string
---@return fun(hl: org.Headline): boolean
function M.compile(match)
  match = vim.trim(match or "")
  local tag_part, todo_part = match, nil
  -- split on the first "/" outside {} and ""
  local depth, inq = 0, false
  for i = 1, #match do
    local c = match:sub(i, i)
    if c == '"' then
      inq = not inq
    elseif not inq and c == "{" then
      depth = depth + 1
    elseif not inq and c == "}" then
      depth = depth - 1
    elseif c == "/" and depth == 0 and not inq then
      tag_part, todo_part = match:sub(1, i - 1), match:sub(i + 1)
      break
    end
  end

  local groups = {}
  tag_part = vim.trim(tag_part)
  if tag_part ~= "" then
    -- split on | outside {} and ""
    local cur, d, q = {}, 0, false
    for i = 1, #tag_part do
      local c = tag_part:sub(i, i)
      if c == '"' then
        q = not q
      elseif not q and c == "{" then
        d = d + 1
      elseif not q and c == "}" then
        d = d - 1
      end
      if c == "|" and d == 0 and not q then
        groups[#groups + 1] = parse_group(table.concat(cur))
        cur = {}
      else
        cur[#cur + 1] = c
      end
    end
    groups[#groups + 1] = parse_group(table.concat(cur))
  end
  local todo_pred = todo_part and compile_todo(vim.trim(todo_part)) or nil

  return function(hl)
    if todo_pred and not todo_pred(hl) then
      return false
    end
    if #groups == 0 then
      return true
    end
    local tags = {}
    for _, t in ipairs(hl:get_tags()) do
      tags[t] = true
    end
    for _, terms in ipairs(groups) do
      local all = true
      for _, t in ipairs(terms) do
        if not eval_term(hl, t, tags) then
          all = false
          break
        end
      end
      if all then
        return true
      end
    end
    return false
  end
end

---@return (fun(hl: org.Headline): boolean)|nil, string|nil
function M.try_compile(match)
  local ok, res = pcall(M.compile, match)
  if not ok then
    return nil, tostring(res):gsub("^.-:%d+: ", "")
  end
  return res
end

---------------------------------------------------------------------------
-- Text search (agenda search view)
---------------------------------------------------------------------------

--- Compile a search-view query into predicate(headline).
--- Words starting with +/- or {regex} make it boolean (all required words
--- must appear, excluded words must not); otherwise the whole query is a
--- case-insensitive substring. A leading `*` restricts to headlines only,
--- a leading `!` to TODO entries.
function M.compile_text(query)
  query = vim.trim(query or "")
  local headline_only, todo_only = false, false
  while true do
    local c = query:sub(1, 1)
    if c == "*" then
      headline_only = true
    elseif c == "!" then
      todo_only = true
    else
      break
    end
    query = vim.trim(query:sub(2))
  end
  local boolean = query:match("^[%+%-{]") ~= nil
  local terms = {}
  if boolean then
    local i = 1
    while i <= #query do
      local c = query:sub(i, i)
      if c:match("%s") then
        i = i + 1
      else
        local neg = false
        if c == "+" or c == "-" then
          neg = c == "-"
          i = i + 1
          c = query:sub(i, i)
        end
        if c == "{" then
          local j = query:find("}", i + 1, true) or #query + 1
          terms[#terms + 1] = { neg = neg, re = compile_regex("\\c" .. query:sub(i + 1, j - 1)) }
          i = j + 1
        else
          local word = query:match("^%S+", i)
          terms[#terms + 1] = { neg = neg, word = word:lower() }
          i = i + #word
        end
      end
    end
  elseif query ~= "" then
    terms[1] = { neg = false, word = query:lower() }
  end
  return function(hl)
    if todo_only and not hl:is_todo() then
      return false
    end
    local text
    if headline_only then
      text = hl.raw
    else
      text = table.concat(vim.list_slice(hl.file.lines, hl.line, hl.body_end), "\n")
    end
    local lower = text:lower()
    for _, t in ipairs(terms) do
      local found
      if t.re then
        found = t.re:match_str(text) ~= nil
      else
        found = lower:find(t.word, 1, true) ~= nil
      end
      if t.neg == found then
        return false
      end
    end
    return #terms > 0
  end
end

---------------------------------------------------------------------------
-- Global heading jump
---------------------------------------------------------------------------

--- Pick any headline in the agenda files (plus current buffer) and jump to it.
function M.goto_heading()
  local entries = {}
  for _, file in ipairs(require("org.files").agenda_files_with_current()) do
    local fname = file.filename and vim.fn.fnamemodify(file.filename, ":t") or "[buffer]"
    for _, hl in ipairs(file.headlines) do
      local parts = { fname }
      vim.list_extend(parts, hl:outline_path())
      local title = hl:plain_title()
      if hl.todo then
        title = hl.todo .. " " .. title
      end
      parts[#parts + 1] = title
      entries[#entries + 1] = {
        text = table.concat(parts, " › "),
        filename = file.filename,
        bufnr = file.bufnr,
        lnum = hl.line,
      }
    end
  end
  if #entries == 0 then
    utils.warn("No headlines found in agenda files")
    return
  end
  local choice = utils.select(entries, {
    prompt = "Go to heading",
    kind = "org_heading",
    format_item = function(e)
      return e.text
    end,
  })
  if not choice then
    return
  end
  if choice.filename then
    utils.open_file(choice.filename, choice.lnum)
  elseif choice.bufnr then
    vim.api.nvim_set_current_buf(choice.bufnr)
    vim.api.nvim_win_set_cursor(0, { choice.lnum, 0 })
    vim.cmd("normal! zv")
  end
end

return M
