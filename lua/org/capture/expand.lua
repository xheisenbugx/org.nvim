---@mod org.capture.expand Capture template expansion (org-capture-fill-template)
---
--- Part of org.capture, which loads it: the %-escapes, their prompts
--- (dates, tags, properties), %(sexp) and the template text.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.capture.shared")

local M = require("org.capture")

local CURSOR = shared.CURSOR
local EMPTY_TEMPLATES = shared.EMPTY_TEMPLATES

---------------------------------------------------------------------------
-- Expansion (org-capture-fill-template)
---------------------------------------------------------------------------

local function pick_date(prompt, with_time, default)
  local ok, cal = pcall(require, "org.calendar")
  if ok and cal.pick then
    return cal.pick({ prompt = prompt, with_time = with_time, default = default })
  end
  local v = utils.input({ prompt = (prompt or "Date") .. ": " })
  return v and date.read_date(v, default) or nil
end

--- The date of an answer given in advance to a date prompt (`%^t`, ...;
--- `opts.answers`), in the forms org.api takes a date in: a date table (an
--- org.date, or a table with year, month, day and optionally hour and
--- min), a Unix time, or a string (a timestamp, or what the date prompt
--- reads, from `base`). Raises an error for anything else.
local function answer_date(v, base)
  if type(v) == "number" then
    return date.from_time(v, true)
  elseif type(v) == "table" then
    if getmetatable(v) == date.Date then
      return v
    end
    if not (v.year and v.month and v.day) then
      error("a date needs year, month and day", 0)
    end
    return date.Date.new({
      year = v.year,
      month = v.month,
      day = v.day,
      hour = v.hour,
      min = v.hour and v.min or nil,
      end_hour = v.end_hour,
      end_min = v.end_min,
    })
  end
  local s = vim.trim(tostring(v))
  local d = date.parse(s) or date.read_date(s, base)
  if not d then
    error("invalid date: " .. s, 0)
  end
  return d
end

local function extend_today_until()
  return tonumber(config.opts.extend_today_until) or 0
end

--- The time used by %t %T %u %U and %<...> (the `time` of
--- org-capture-fill-template): the capture date `d` (a date without a time
--- is taken at `extend_today_until` o'clock, like the agenda's
--- org-overriding-default-time) or now. Before `extend_today_until`
--- o'clock it is 23:59 of the previous day.
---@param d? org.Date
---@return org.Date
function M.default_time(d)
  local ext = extend_today_until()
  local t = d and (d.hour and d:clone() or d:clone({ hour = ext, min = 0 })) or date.now()
  t = t:clone({ range_end = vim.NIL, end_hour = vim.NIL, end_min = vim.NIL })
  if t.hour < ext then
    t = t:add(-1, "d"):clone({ hour = 23, min = 59 })
  end
  return t
end

--- The capture date of a date picked for `time_prompt` / C-1 without a
--- time (org-capture-set-target-location): today's date keeps the current
--- time, another date starts at `extend_today_until` o'clock.
local function prompted_time(d)
  if d.hour then
    return d
  end
  local now = M.default_time()
  if d:days() == now:days() then
    return d:clone({ hour = now.hour, min = now.min })
  end
  return d:clone({ hour = extend_today_until(), min = 0 })
end

local function fmt_date(d, with_time, active)
  local c = d:clone({ active = active, repeater = vim.NIL, warning = vim.NIL, range_end = vim.NIL })
  if with_time then
    if not c.hour then
      local now = date.now()
      c.hour, c.min = now.hour, now.min
    end
  else
    c.hour, c.min, c.end_hour, c.end_min = nil, nil, nil, nil
  end
  return c:to_string()
end

--- Tags offered by %^g (the target file, or the agenda files when there
--- is none) and %^G (the agenda files), like org-global-tags-completion-table:
--- the tags used in the files plus their tag definitions (`#+TAGS:` or `tags`).
local function tag_candidates(target_file, global)
  local seen, out = {}, {}
  local function add(t)
    if t and t ~= "" and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  local list = {}
  if not global and target_file then
    list = { target_file }
  else
    list = files.agenda_files()
  end
  for _, f in ipairs(list) do
    local defs = f:tag_definitions()
    if #defs > 0 then
      for _, d in ipairs(defs) do
        add(d.name)
      end
    else
      for _, spec in ipairs(config.opts.tags or {}) do
        for tok in spec:gmatch("%S+") do
          if not tok:match("^[{}%[%]:]$") then
            add((tok:gsub("%(.%)$", "")))
          end
        end
      end
    end
    for _, t in ipairs(f.settings.filetags or {}) do
      add(t)
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        add(t)
      end
    end
  end
  table.sort(out)
  return out
end

local function clock_task()
  local ok, clock = pcall(require, "org.clock")
  if not ok or not clock.state then
    return nil
  end
  local bufnr, lnum = clock.find_open_clock()
  if not bufnr then
    return nil
  end
  return { bufnr = bufnr, lnum = lnum, title = clock.state.title }
end

--- Emacs's `user-full-name`: $NAME, the account's full name, or the login.
local full_name
local function user_full_name()
  if full_name then
    return full_name
  end
  full_name = vim.env.NAME
  if not full_name or full_name == "" then
    local user = vim.env.USER or vim.env.USERNAME or ""
    local ok, res = pcall(function()
      if vim.fn.has("mac") == 1 then
        return vim.fn.system({ "id", "-F", user })
      end
      return (vim.fn.system({ "getent", "passwd", user }):match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:,]*)"))
    end)
    full_name = ok and vim.v.shell_error == 0 and res and vim.trim(res) or ""
    if full_name == "" then
      full_name = user
    end
  end
  return full_name
end
M.user_full_name = user_full_name

local function register(name)
  local ok, v = pcall(vim.fn.getreg, name)
  if ok and v and v ~= "" then
    return (v:gsub("\n$", ""))
  end
  return nil
end

--- Remove the backslashes escaping the `%` at `pos` (org-capture-escaped-%).
---@return string s, integer pos, boolean escaped
local function unescape(s, pos)
  local n = 0
  while pos - n - 1 >= 1 and s:sub(pos - n - 1, pos - n - 1) == "\\" do
    n = n + 1
  end
  if n == 0 then
    return s, pos, false
  end
  local del = math.floor((n + 1) / 2)
  s = s:sub(1, pos - n - 1) .. s:sub(pos - n + del)
  return s, pos - del, n % 2 == 1
end

--- Walk `s` and replace every `%` placeholder recognized by `match(s, p)`
--- (returning its last position and data). `replace(data, s, p, e)`
--- returns the new string and the position to continue at. Escaped
--- placeholders lose their backslashes and stay literal.
local function scan(s, match, replace)
  local i = 1
  while true do
    local p = s:find("%", i, true)
    if not p then
      return s
    end
    local e, data = match(s, p)
    if not e then
      i = p + 1
    else
      local s2, p2, escaped = unescape(s, p)
      e = e - (p - p2)
      s, p = s2, p2
      if escaped then
        i = e + 1
      else
        s, i = replace(data, s, p, e)
      end
    end
  end
end

local function splice(s, p, e, v)
  return s:sub(1, p - 1) .. v .. s:sub(e + 1), p + #v
end

local function balanced_paren(s, p)
  -- `s:sub(p, p)` is "(": the position of the matching ")"
  local depth, quote = 0, nil
  for k = p, #s do
    local ch = s:sub(k, k)
    if quote then
      if ch == "\\" then
        k = k + 1
      elseif ch == quote then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
  end
end

local function untabify(s)
  return (
    s:gsub("[^\n]*", function(line)
      if not line:find("\t", 1, true) then
        return line
      end
      local out, col = {}, 0
      for ch in line:gmatch(".") do
        if ch == "\t" then
          local n = 8 - col % 8
          out[#out + 1] = string.rep(" ", n)
          col = col + n
        else
          out[#out + 1] = ch
          col = col + 1
        end
      end
      return table.concat(out)
    end)
  )
end

--- Named template expansions for extensions: `%(name)` in a template
--- calls `M.expansions[name](ctx)` with the capture context (its
--- `origin_buf`, `origin_cursor`, `initial`...) and inserts the string it
--- returns. Empty unless an extension adds some (the `code` extension's
--- `%(code-link)`, `%(code-block)`...).
---@type table<string, fun(ctx: table): string|nil>
M.expansions = {}

--- The value of a `%(expr)` of a template (`expr` is the text inside the
--- parentheses, its escapes already expanded). Emacs Lisp like
--- org-capture-expand-embedded-elisp: `%(format-time-string "%Y")` runs on
--- the Lisp interpreter of table formulas or, for what it does not
--- implement, in a separate Emacs (`babel.emacs_lisp`); a string is
--- inserted, nil inserts nothing and an error `%![Error: ...]`. A Lua
--- expression (`%(os.date("%Y"))`) is evaluated as Lua: forms whose head
--- is a Lisp function the interpreter knows are Lisp, other text that
--- compiles as Lua is Lua, and Lisp is tried when the Lua fails.
---
--- A bare name registered in `M.expansions` (`%(code-link)`) calls that
--- function with the capture context instead.
---@param expr string
---@param ctx? table the capture context
---@return string
function M.eval_sexp(expr, ctx)
  local named = M.expansions[vim.trim(expr)]
  if named then
    local ok, v = pcall(named, ctx or {})
    if not ok then
      return "%![Error: " .. tostring(v) .. "]"
    end
    return v == nil and "" or tostring(v)
  end
  local el = require("org.table.elisp")
  local form = "(" .. expr .. ")"
  local is_lisp = pcall(el.read, form)
  local chunk, lua_err = loadstring("return " .. expr)
  local function lisp()
    local v, err = require("org.babel.elisp").eval(form, { condition = true, requires = { "org" } })
    if err then
      return "%![Error: " .. err .. "]"
    elseif v ~= nil and type(v) ~= "string" then
      utils.warn(string.format("Capture template sexp `%s' must evaluate to string or nil", form))
      return ""
    end
    return v or ""
  end
  if is_lisp and (el.looks_like(form) or not chunk) then
    return lisp()
  end
  local ok, res = false, lua_err
  if chunk then
    ok, res = pcall(chunk)
  end
  if ok then
    return res == nil and "" or tostring(res)
  elseif is_lisp then
    return lisp()
  end
  utils.warn("Capture %(" .. expr .. "): " .. tostring(res))
  return ""
end

--- Expand a template string like org-capture-fill-template: `%[file]`,
--- then the non-interactive escapes, `%(lua)`, the prompts `%^...` and
--- finally the backreferences `%\N` / `%\*N`. The first `%?` becomes the
--- cursor marker. Must run inside a coroutine when it prompts.
---@param text string
---@param ctx org.Config.CaptureContext|table
---@return string text with the CURSOR marker
---@return table ctx
function M.expand(text, ctx)
  ctx = ctx or {}
  ctx.properties = ctx.properties or {}
  local now = M.default_time(ctx.time or ctx.date)
  local time = now:to_time()
  local base_date = ctx.date
  local annotation = ctx.annotation or ""
  if annotation == "[[]]" then
    annotation = ""
  end
  local link, desc = annotation:match("^%[%[(.-)%]%[(.-)%]%]$")
  if not link then
    link = annotation:match("^%[%[(.-)%]%]$")
  end
  local v = {
    a = annotation,
    A = link and ("[[" .. link .. "][%^{Link description}]]") or annotation,
    l = link and ("[[" .. link .. "]]") or annotation,
    L = link or annotation,
    c = register('"') or "",
    f = ctx.origin_file and vim.fn.fnamemodify(ctx.origin_file, ":t") or "",
    F = ctx.origin_file or "",
    i = ctx.initial or "",
  }
  local keywords = vim.tbl_extend("force", {
    link = ctx.link or link,
    description = ctx.link_desc or desc,
    annotation = annotation,
    initial = v.i,
    type = (ctx.link or link or ""):match("^([%w%-]+):"),
    file = ctx.origin_file,
  }, ctx.keywords or {})

  -- %[file]: contents of a file
  text = scan(text, function(s, p)
    local f = s:match("^%%%[([^\n]+)%]", p)
    return f and (p + #f + 2) or nil, f
  end, function(f, s, p, e)
    -- lint: allow expand: %[file] of a configured capture template
    local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(f), ":p"))
    local fd, err = io.open(path, "r")
    local content
    if fd then
      content = fd:read("*a"):gsub("\r\n", "\n")
      fd:close()
    else
      content = string.format("%%![could not insert %s: %s]", path, tostring(err))
    end
    return splice(s, p, e, content)
  end)

  -- non-interactive escapes; `in_expr`: inside %(...), quote the values
  local function expand_simple(s, in_expr)
    return scan(s, function(str, p)
      local c = str:sub(p + 1, p + 1)
      if c == ":" then
        local k = str:match("^:([%-A-Za-z]+)", p + 1)
        return k and (p + 1 + #k) or nil, { ":", k }
      elseif c == "<" then
        local f = str:match("^<([^>\n]+)>", p + 1)
        return f and (p + #f + 2) or nil, { "<", f }
      elseif c ~= "" and ("aAcfFikKlLntTuUx"):find(c, 1, true) then
        return p + 1, { c }
      end
    end, function(d, str, p, e)
      local k, val = d[1], nil
      if k == "<" then
        val = os.date(d[2], time)
      elseif k == ":" then
        val = keywords[d[2]] or ""
      elseif k == "i" then
        if in_expr then
          val = v.i
        else
          -- repeat the text before %i on every line of the initial content
          local lead = str:sub(1, p - 1):match("([^\n]*)$")
          val = v.i:gsub("\n", function()
            return "\n" .. lead
          end)
        end
      elseif k == "t" or k == "T" or k == "u" or k == "U" then
        val = fmt_date(now, k == "T" or k == "U", k == "t" or k == "T")
      elseif k == "x" then
        val = register("*") or register("+") or ""
      elseif k == "n" then
        val = user_full_name()
      elseif k == "k" then
        local task = clock_task()
        val = task and task.title or ""
      elseif k == "K" then
        local task = clock_task()
        val = ""
        if task then
          local ok, l = pcall(require("org.links").link_to_location, { bufnr = task.bufnr, lnum = task.lnum })
          if ok and l then
            val = require("org.links").format(l.link, l.desc)
          end
        end
      else
        val = v[k] or ""
      end
      val = tostring(val or "")
      if in_expr then
        val = val:gsub('[\\"]', "\\%0")
      end
      return splice(str, p, e, val)
    end)
  end

  -- mark %(...) expressions; they are evaluated after the simple escapes
  local exprs = {}
  text = scan(text, function(s, p)
    if s:sub(p + 1, p + 1) ~= "(" then
      return nil
    end
    local close = balanced_paren(s, p + 1)
    return close, close and s:sub(p + 2, close - 1) or nil
  end, function(expr, s, p, e)
    exprs[#exprs + 1] = expr
    return splice(s, p, e, "\31" .. #exprs .. "\31")
  end)
  text = expand_simple(text)
  text = text:gsub("\31(%d+)\31", function(idx)
    return M.eval_sexp(expand_simple(exprs[tonumber(idx)], true), ctx)
  end)

  -- prompts; `ctx.answers` answers them by label (the text before `|` in
  -- `%^{...}`, "Tags" / "Date" without one) or by position, and with
  -- `ctx.noninteractive` the others take their default
  local strings, strings_all = {}, {}
  local nprompt = 0
  local batch = ctx.noninteractive
  local function preset(label)
    nprompt = nprompt + 1
    local answers = ctx.answers
    if type(answers) ~= "table" then
      return nil
    end
    local a = label and answers[label]
    if a == nil then
      a = answers[nprompt]
    end
    return a
  end
  text = scan(text, function(s, p)
    if s:sub(p + 1, p + 1) ~= "^" then
      return nil
    end
    local e = p + 1
    local label = s:match("^{([^}]*)}", e + 1)
    if label then
      e = e + #label + 2
    end
    local key = s:match("^[CgGLptTuU]", e + 1)
    if key then
      e = e + 1
    end
    return e, { label = label, key = key }
  end, function(d, s, p, e)
    local items = d.label and vim.split(d.label, "|", { plain = true }) or {}
    local prompt, default = items[1], items[2]
    local key = d.key
    local dates = key and key ~= "g" and key ~= "G" and key ~= "C" and key ~= "L" and key ~= "p"
    local pre = preset(prompt or (key == "g" or key == "G") and "Tags" or dates and "Date" or nil)
    if key == "g" or key == "G" then
      local answer
      if pre ~= nil then
        answer = type(pre) == "table" and table.concat(pre, ":") or tostring(pre)
      elseif batch then
        answer = ""
      else
        local candidates = tag_candidates(ctx.target_file, key == "G")
        answer = utils.input_complete((prompt or "Tags") .. ": ", candidates)
      end
      if answer == nil then
        utils.abort()
      end
      local tags = {}
      for t in answer:gmatch("[^:%s]+") do
        tags[#tags + 1] = t
      end
      if #tags == 0 then
        return splice(s, p, e, "")
      end
      local ins = table.concat(tags, ":")
      strings_all[#strings_all + 1] = ":" .. ins .. ":"
      if s:sub(p - 1, p - 1) ~= ":" then
        ins = ":" .. ins
      end
      if s:sub(e + 1, e + 1) ~= ":" then
        ins = ins .. ":"
      end
      local out, i = splice(s, p, e, ins)
      -- realign the tags when on a heading (org-align-tags)
      local ls = out:sub(1, p - 1):match(".*\n()") or 1
      local le = (out:find("\n", i, true) or (#out + 1)) - 1
      local line = out:sub(ls, le)
      if parser.headline_level(line) then
        local todo = ctx.target_file and ctx.target_file.settings.todo or nil
        local aligned = edit.auto_align_tags() and edit.align_tags_line(line, todo) or line
        -- resume right after the tags: a later %^{...} on the line still prompts
        local rest = out:sub(i, le)
        out = out:sub(1, ls - 1) .. aligned .. out:sub(le + 1)
        if rest ~= "" and aligned:sub(-#rest) == rest then
          i = ls + #aligned - #rest
        else
          i = ls + #aligned
        end
      end
      return out, i
    elseif key == "C" or key == "L" then
      local clips = { v.i }
      for _, r in ipairs({ "*", "+", '"' }) do
        local val = register(r)
        if val and not vim.tbl_contains(clips, val) then
          clips[#clips + 1] = val
        end
      end
      local val = clips[1]
      if pre ~= nil then
        val = tostring(pre)
      elseif #clips > 1 and not batch then
        val = utils.input_complete("Clipboard/kill value: ", clips, clips[1])
        if val == nil then
          utils.abort()
        end
      end
      strings_all[#strings_all + 1] = val
      return splice(s, p, e, key == "L" and ("[[" .. val .. "]]") or val)
    elseif key == "p" then
      prompt = prompt or "Property"
      local allowed = ctx.target_hl and ctx.target_hl:get_allowed_values(prompt or "")
      local answer
      if pre ~= nil then
        answer = tostring(pre)
      elseif batch then
        answer = default or ""
      elseif allowed and #allowed > 0 then
        answer = utils.input_complete(prompt .. ": ", allowed, default)
      else
        answer = utils.input({ prompt = prompt .. ": ", default = default or "" })
      end
      if answer == nil then
        utils.abort()
      end
      if answer == "" and default then
        answer = default
      end
      ctx.properties[#ctx.properties + 1] = { prompt, answer }
      strings_all[#strings_all + 1] = answer
      return splice(s, p, e, "")
    elseif key then
      -- t T u U
      local with_time = key == "T" or key == "U"
      local d
      if pre ~= nil then
        d = answer_date(pre, base_date)
      elseif batch then
        d = base_date or (with_time and date.now() or date.today())
      else
        d = pick_date(prompt or "Date", with_time, base_date)
      end
      if not d then
        utils.abort()
      end
      local val = fmt_date(d, with_time or d.hour ~= nil, key == "t" or key == "T")
      strings_all[#strings_all + 1] = val
      return splice(s, p, e, val)
    end
    local completions = vim.list_slice(items, 3)
    local label = (prompt or "Enter string") .. (default and default ~= "" and (" [" .. default .. "]") or "")
    local answer
    if pre ~= nil then
      answer = tostring(pre)
    elseif batch then
      answer = default or ""
    elseif #completions > 0 then
      answer = utils.input_complete(label .. ": ", completions)
    else
      answer = utils.input({ prompt = label .. ": " })
    end
    if answer == nil then
      utils.abort()
    end
    if answer == "" and default then
      answer = default
    end
    strings[#strings + 1] = answer
    strings_all[#strings_all + 1] = answer
    return splice(s, p, e, answer)
  end)

  -- %\N: the Nth %^{...} answer; %\*N: the Nth answer of any prompt
  text = scan(text, function(s, p)
    local n = s:match("^\\([1-9]%d*)", p + 1)
    return n and (p + 1 + #n) or nil, tonumber(n)
  end, function(n, s, p, e)
    return splice(s, p, e, strings[n] or "")
  end)
  text = scan(text, function(s, p)
    local n = s:match("^\\%*([1-9]%d*)", p + 1)
    return n and (p + 2 + #n) or nil, tonumber(n)
  end, function(n, s, p, e)
    return splice(s, p, e, strings_all[n] or "")
  end)

  -- no blank lines before the text, nothing after its last non-blank line
  text = text:gsub("^[ \t\n]*\n", "")
  local last = text:match("()[^ \t\n][ \t\n]*$")
  if not last then
    text = ""
  else
    local eol = text:find("\n", last, true)
    if eol then
      text = text:sub(1, eol - 1)
    end
  end
  text = untabify(text)
  local c = text:find("%?", 1, true)
  if c then
    text = text:sub(1, c - 1) .. CURSOR .. text:sub(c + 2)
  end
  return text, ctx
end

--- Make the expanded text fit the template type (the "* " of an entry,
--- the bullet of an item, the "| " of a table line).
local function shape(text, ttype)
  if ttype == "entry" then
    if not text:match("^%*+%s") and not text:match("^%*+$") and not text:match("^%*+" .. CURSOR) then
      text = "* " .. text
    end
  elseif ttype == "item" or ttype == "checkitem" then
    local first = text:match("^[^\n]*")
    if not require("org.lists").parse_item_line(first) then
      text = "- " .. text:gsub("\n", "\n  ")
    end
  elseif ttype == "table-line" then
    if not text:match("^%s*|") then
      text = "| " .. text
    end
  end
  return text
end

local function template_text(tpl, ctx)
  local t = tpl.template
  if type(t) == "function" then
    t = t(ctx)
  end
  if type(t) == "table" then
    if t.file then
      local path = utils.expand(t.file)
      local lines = utils.readfile(path)
      t = lines and table.concat(lines, "\n") or string.format('* Template file "%s" not found', t.file)
    else
      t = table.concat(t, "\n")
    end
  end
  if t == nil or not tostring(t):match("%S") then
    t = EMPTY_TEMPLATES[tpl.type or "entry"] or ""
  end
  return tostring(t)
end

-- Shared with the parts loaded after this one
shared.pick_date = pick_date
shared.prompted_time = prompted_time
shared.shape = shape
shared.template_text = template_text
