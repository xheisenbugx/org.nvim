---@mod org.capture Capture (org-capture)
---
--- Templates live in `capture.templates`, keyed by their selection key:
---
---   templates = {
---     t = { description = "Task", template = "* TODO %?\n  %u", target = "~/org/inbox.org", headline = "Tasks" },
---     j = { description = "Journal", template = "* %<%H:%M> %?", target = "~/org/journal.org", datetree = true },
---     w = "Work",                                  -- group; its templates use keys "wX"
---     wm = { description = "Meeting", template = "* MEETING %? :meeting:\n  %T", olp = { "Work", "Meetings" } },
---   }
---
--- The target is resolved when the capture starts (like Emacs, which
--- inserts the template into the target right away): headlines and date
--- tree nodes are created then, and the location is tracked with an
--- extmark until the capture is finished. The text is edited in a separate
--- capture buffer and stored at that location on finalize.
---
--- Template fields: see `:h org-capture-templates`.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

local CURSOR = "\30"
local ns = vim.api.nvim_create_namespace("org_capture")

--- Active capture sessions: bufnr -> session
M.sessions = {}

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

--- Used when no template is configured (or none is available in the
--- current context), like the fallback of org-capture-select-template.
M.DEFAULT_TEMPLATES = {
  t = { description = "Task", type = "entry", target = "", headline = "Tasks", template = "* TODO %?\n  %u\n  %a" },
}

--- Templates used when the template text is empty (org-capture-set-plist).
local EMPTY_TEMPLATES = {
  entry = "* %?\n  %a",
  item = "- %?",
  checkitem = "- [ ] %?",
  ["table-line"] = "| %? |",
}

local function is_template(v)
  return type(v) == "table"
    and (
      v.template ~= nil
      or v.type ~= nil
      or v.target ~= nil
      or v.file ~= nil
      or v.headline ~= nil
      or v.olp ~= nil
      or v.id ~= nil
      or v.datetree ~= nil
      or v.location ~= nil
    )
end

local function rx_match(str, re)
  return str ~= nil and str ~= "" and vim.fn.match(str, re) >= 0
end

--- The context used by `capture.templates_contexts`: the current buffer.
local function context_env()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  return {
    file = (name ~= "" and vim.bo[bufnr].buftype == "") and name or nil,
    mode = vim.bo[bufnr].filetype,
    buffer = name ~= "" and vim.fn.fnamemodify(name, ":t") or "",
  }
end

--- Does one context rule hold (org-contextualize-validate-key)?
local function rule_ok(rule, env)
  if type(rule) == "function" then
    return rule() and true or false
  end
  if type(rule) ~= "table" then
    return false
  end
  return (rule.in_file and env.file and rx_match(env.file, rule.in_file))
    or (rule.in_mode and rx_match(env.mode, rule.in_mode))
    or (rule.in_buffer and rx_match(env.buffer, rule.in_buffer))
    or (rule.not_in_file and env.file and not rx_match(env.file, rule.not_in_file))
    or (rule.not_in_mode and not rx_match(env.mode, rule.not_in_mode))
    or (rule.not_in_buffer and not rx_match(env.buffer, rule.not_in_buffer))
    or false
end

--- Normalize a `templates_contexts` entry to { key, replacement, rules }.
local function normalize_context(c)
  local key, repl, rules = c[1], c[2], c[3]
  if type(repl) ~= "string" or repl == "" then
    rules, repl = c[2], key
  end
  if type(rules) == "function" or (type(rules) == "table" and not vim.islist(rules)) then
    rules = { rules }
  end
  return { key = key, repl = repl, rules = rules or {} }
end

--- The templates available in the current context: `capture.templates`
--- filtered and remapped by `capture.templates_contexts`
--- (org-contextualize-keys), or the default template when none is left.
---@return table<string, table|string>
function M.templates(env)
  local templates = config.opts.capture.templates or {}
  local contexts = vim.tbl_map(normalize_context, config.opts.capture.templates_contexts or {})
  local out, hidden = {}, {}
  if #contexts == 0 then
    out = templates
  else
    env = env or context_env()
    for key, t in pairs(templates) do
      local mine = vim.tbl_filter(function(c)
        return c.key == key
      end, contexts)
      if #mine == 0 then
        out[key] = t
      else
        local valid, repl = false, nil
        for _, c in ipairs(mine) do
          for _, r in ipairs(c.rules) do
            if rule_ok(r, env) then
              valid = true
              if c.repl ~= c.key then
                repl = c.repl
              end
            end
          end
        end
        if valid and not repl then
          out[key] = t
        elseif valid then
          if templates[repl] == nil then
            error(string.format("Undefined key `%s' as contextual replacement for `%s'", repl, key), 0)
          end
          out[key] = templates[repl]
          hidden[repl] = true
        end
      end
    end
    for k in pairs(hidden) do
      out[k] = nil
    end
  end
  if vim.tbl_isempty(out) then
    return M.DEFAULT_TEMPLATES
  end
  return out
end

--- Template for `key` (a copy with `key` set), or nil.
function M.get_template(key, env)
  local t = M.templates(env)[key]
  if not is_template(t) then
    return nil
  end
  local copy = vim.tbl_extend("force", {}, t)
  copy.key = key
  return copy
end

--- Menu items for the selection dispatcher.
function M.menu_items(env)
  local entries = {}
  for key, t in pairs(M.templates(env)) do
    if is_template(t) then
      entries[#entries + 1] = { key = key, label = t.description or key, value = key }
    else
      local label = type(t) == "string" and t or (type(t) == "table" and t.description) or key
      entries[#entries + 1] = { key = key, label = label }
    end
  end
  return ui.tree_from_keys(entries)
end

local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local srow, scol, erow, ecol = utils.visual_range()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
  if mode == "v" and #lines > 0 then
    lines[#lines] = lines[#lines]:sub(1, ecol)
    lines[1] = lines[1]:sub(scol)
  end
  return table.concat(lines, "\n")
end

--- Template selection menu, then capture with the chosen template. In
--- visual mode the selection becomes `opts.initial` (`%i`). A count works
--- like Emacs's prefix argument: 4 (C-u) goes to a template's target, 16
--- (C-u C-u) to the last stored entry, 1 (C-1) asks for the date tree
--- date. Must run inside a coroutine; `require("org").capture()` handles
--- that.
---@param opts? table `{ initial?: string, date?: table, here?: boolean }`, as for `capture()`
---@return integer|nil capture buffer (nil when cancelled)
function M.prompt(opts)
  opts = opts or {}
  local count = opts.count or vim.v.count
  if count == 4 then
    return M.goto_target()
  elseif count == 16 then
    return M.goto_last_stored()
  elseif count == 1 then
    opts.date_prompt = true
  end
  opts.initial = opts.initial or visual_selection()
  local env = context_env()
  local items = M.menu_items(env)
  local key = ui.menu({ title = "Capture", items = items })
  if type(key) ~= "string" then
    return
  end
  local tpl = M.get_template(key, env)
  if not tpl then
    utils.warn("No capture template for key: " .. key)
    return
  end
  return M.capture(tpl, opts)
end

--- Capture with a template inserted at the cursor (C-0 C-c c).
---@param opts? table as for `capture()`
function M.prompt_here(opts)
  return M.prompt(vim.tbl_extend("force", opts or {}, { here = true, count = 0 }))
end

--- `:Org capture [key]`: capture with the template at `key` of
--- `capture.templates`, or open the template menu when empty. Must run
--- inside a coroutine; `require("org").capture(key)` handles that.
---@param args? string template key
---@return integer|nil capture buffer (nil when cancelled / unknown key)
function M.command(args)
  local key = vim.trim(args or "")
  if key == "" then
    return M.prompt()
  end
  return M.capture(key)
end

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

--- Expand a template string like org-capture-fill-template: `%[file]`,
--- then the non-interactive escapes, `%(lua)`, the prompts `%^...` and
--- finally the backreferences `%\N` / `%\*N`. The first `%?` becomes the
--- cursor marker. Must run inside a coroutine when it prompts.
---@param text string
---@param ctx table { origin_file?, annotation?, link?, link_desc?, initial?, date?, target_file?, target_hl?, keywords? }
---@return string text with CURSOR marker, table ctx
function M.expand(text, ctx)
  ctx = ctx or {}
  ctx.properties = ctx.properties or {}
  local time = (ctx.date or date.now()):to_time()
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
    local path = vim.fn.fnamemodify(vim.fn.expand(f), ":p")
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
        val = fmt_date(base_date or date.now(), k == "T" or k == "U", k == "t" or k == "T")
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
    local expr = expand_simple(exprs[tonumber(idx)], true)
    local chunk, err = loadstring("return " .. expr)
    local ok, res = false, err
    if chunk then
      ok, res = pcall(chunk)
    end
    if not ok then
      utils.warn("Capture %(" .. expr .. "): " .. tostring(res))
      return ""
    end
    return res == nil and "" or tostring(res)
  end)

  -- prompts
  local strings, strings_all = {}, {}
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
    if key == "g" or key == "G" then
      local candidates = tag_candidates(ctx.target_file, key == "G")
      local answer = utils.input_complete((prompt or "Tags") .. ": ", candidates)
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
        local aligned = edit.align_tags_line(line, todo)
        out = out:sub(1, ls - 1) .. aligned .. out:sub(le + 1)
        i = ls + #aligned
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
      if #clips > 1 then
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
      if allowed and #allowed > 0 then
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
      local d = pick_date(prompt or "Date", with_time, base_date)
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
    if #completions > 0 then
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

---------------------------------------------------------------------------
-- Target resolution
---------------------------------------------------------------------------

--- Buffer and headline line of the running clock (the `clock` target).
---@return integer|nil bufnr, integer|nil lnum
function M.clock_location()
  local ok, clock = pcall(require, "org.clock")
  if not ok or not clock.state then
    return nil
  end
  local bufnr, lnum = clock.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return bufnr, hl and hl.line or nil
end

--- Absolute target file for a template (org-capture-expand-file): ""
--- is `default_notes_file`, relative names are relative to
--- `org_directory`. nil for the clock/ID/location targets that can't be
--- found.
function M.target_path(tpl)
  local t = tpl.target or tpl.file
  if type(t) == "function" then
    t = t()
  end
  if t == "clock" then
    local bufnr = M.clock_location()
    return bufnr and vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) or nil
  end
  if tpl.id and not t then
    local loc = require("org.id").find(tpl.id)
    return loc and loc.filename or nil
  end
  if t == nil or t == "" then
    t = config.opts.default_notes_file
  end
  return utils.expand(t)
end

local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
end

local function is_blank(l)
  return l ~= nil and l:match("^%s*$") ~= nil
end

--- A buffer holding only one empty line (a new file).
local function is_empty_buffer(bufnr)
  return vim.api.nvim_buf_line_count(bufnr) == 1 and get_line(bufnr, 1) == ""
end

--- Insert `lines` after line `at` (0 = top); an empty buffer is replaced.
local function put(bufnr, at, lines)
  if is_empty_buffer(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    return 0
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  return at
end

---------------------------------------------------------------------------
-- Date trees (org-datetree)
---------------------------------------------------------------------------

local function comparefun(pattern)
  return function(sibling, new)
    local a, b = sibling:match(pattern), new:match(pattern)
    if not (a and b) then
      return nil
    end
    return a < b and -1 or (a > b and 1 or 0)
  end
end

local GROUPINGS = {
  day = { "year", "month", "day" },
  month = { "year", "month" },
  week = { "year", "week", "day" },
}

--- Headline titles (with their comparison functions) of the date tree
--- nodes for `d` (org-datetree-find-create-entry). `grouping` is a subset
--- of { "year", "quarter", "month", "week", "day" }.
function M.datetree_hierarchy(grouping, d)
  local has = {}
  for _, g in ipairs(grouping) do
    has[g] = true
  end
  local t = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local iso_year = tonumber(os.date("%G", t))
  local week = tonumber(os.date("%V", t))
  local nominal_year = has.week and iso_year or d.year
  local nominal_month = d.month
  if has.week then
    -- the month containing the week's Thursday
    local wd = tonumber(os.date("%u", t))
    nominal_month = tonumber(os.date("%m", t + (4 - wd) * 86400))
  end
  local quarter = (has.week and not has.month) and math.min(4, 1 + math.floor((week - 1) / 13))
    or (1 + math.floor((nominal_month - 1) / 3))
  local out = {}
  if has.year then
    out[#out + 1] = { tostring(nominal_year), comparefun("([12]%d%d%d)") }
  end
  if has.quarter then
    out[#out + 1] = { string.format("%d-Q%d", nominal_year, quarter), comparefun("([12]%d%d%d%-Q[1-4])") }
  end
  if has.month then
    out[#out + 1] = {
      string.format("%04d-%02d %s", nominal_year, nominal_month, date.MONTH_NAMES_LONG[nominal_month]),
      comparefun("([12]%d%d%d%-[01]%d) %S"),
    }
  end
  if has.week then
    out[#out + 1] = { os.date("%G-W%V", t), comparefun("([12]%d%d%d%-W[0-5]%d)") }
  end
  if has.day then
    out[#out + 1] = {
      string.format("%04d-%02d-%02d %s", d.year, d.month, d.day, date.DAY_NAMES_LONG[d:weekday()]),
      comparefun("([12]%d%d%d%-[01]%d%-[0123]%d) %S"),
    }
  end
  return out
end

--- Find or create the headline `title` of `level` among the headlines in
--- lines [s, e] (org-datetree--find-create-subheading): the first one
--- comparing equal is used, a new one goes before the first later one.
---@return integer line
local function dt_subheading(bufnr, s, e, level, title, cmp)
  local file = files.get_buffer(bufnr)
  local sibling
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e and hl.level == level then
      local r = cmp(hl.title, title)
      if r == true or (type(r) == "number" and r >= 0) then
        sibling = hl
        break
      end
    end
  end
  if sibling then
    local r = cmp(sibling.title, title)
    if r == true or r == 0 then
      return sibling.line
    end
  end
  local at = sibling and sibling.line - 1 or e
  -- blank lines before the new node are removed ...
  local b = at
  while b >= s and b > 0 and is_blank(get_line(bufnr, b)) do
    b = b - 1
  end
  -- ... and one is added when org--blank-before-heading-p says so
  local blank = false
  local setting = config.opts.blank_before_new_entry
  setting = type(setting) == "table" and setting.heading or setting
  if setting == true then
    blank = b > 0
  elseif setting == "auto" and b > 0 then
    local f = files.get_buffer(bufnr)
    -- the buffer is narrowed to the parent's subtree: its heading is at bob
    local h = f:headline_at(b)
    if h and h.line > math.max(s - 1, 1) then
      blank = is_blank(get_line(bufnr, h.line - 1))
    elseif h then
      for _, n in ipairs(f.headlines) do
        if n.line > e then
          break
        elseif n.line > at + 1 then
          blank = is_blank(get_line(bufnr, n.line - 1))
          break
        end
      end
    end
  end
  if b < at then
    vim.api.nvim_buf_set_lines(bufnr, b, at, false, {})
    at = b
  end
  local new = { string.rep("*", level) .. " " .. title }
  if at == 0 or blank then
    -- Emacs inserts "\n* title\n": at the top of the buffer that leaves an
    -- empty first line
    table.insert(new, 1, "")
  end
  return put(bufnr, at, new) + #new
end

--- Create/find the date tree for `d` under `parent_lnum` (nil = top level,
--- or under the headline with a DATE_TREE / WEEK_TREE property); returns
--- the line of the innermost node.
---@param tree_type? "day"|"week"|"month"|string[]|fun(d: org.Date): table
function M.ensure_datetree(bufnr, parent_lnum, d, tree_type)
  tree_type = tree_type or "day"
  local hier
  if type(tree_type) == "function" then
    hier = {}
    for _, h in ipairs(tree_type(d)) do
      if type(h) == "string" then
        local title = h
        hier[#hier + 1] = {
          title,
          function(a, b)
            return a == b and 0 or nil
          end,
        }
      else
        hier[#hier + 1] = h
      end
    end
  else
    local grouping = type(tree_type) == "table" and tree_type or GROUPINGS[tree_type]
    if not grouping then
      error("Unrecognized :tree-type " .. tostring(tree_type), 0)
    end
    for _, g in ipairs(grouping) do
      if not vim.tbl_contains({ "year", "quarter", "month", "week", "day" }, g) then
        error("Unrecognized datetree grouping elements " .. tostring(g), 0)
      end
    end
    hier = M.datetree_hierarchy(grouping, d)
    if not parent_lnum and type(tree_type) == "string" then
      -- the old way of placing the tree: a headline with a property
      local prop = tree_type == "week" and "WEEK_TREE" or "DATE_TREE"
      local hl = files.get_buffer(bufnr):find_headline(function(h)
        return h.properties[prop] ~= nil
      end)
      parent_lnum = hl and hl.line or nil
    end
  end
  local level, s, e = 1, 1, vim.api.nvim_buf_line_count(bufnr)
  local line = parent_lnum
  for _, h in ipairs(hier) do
    if line then
      local hl = files.get_buffer(bufnr):headline_at(line)
      level, s, e = hl.level + 1, hl.line + 1, hl.end_line
    end
    line = dt_subheading(bufnr, s, e, level, h[1], h[2])
  end
  return line
end

--- Find the headline for a file+headline target, creating it at the end
--- of the file when missing.
local function find_or_create_headline(bufnr, title)
  local file = files.get_buffer(bufnr)
  local hl = file:find_by_title(title)
  if hl then
    return hl.line
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  return put(bufnr, n, { "* " .. title }) + 1
end

--- Resolve a template's target when the capture starts
--- (org-capture-set-target-location). Headlines of file+headline and the
--- date tree nodes are created now. Positions are tracked with extmarks.
---@param tpl table
---@param ctx table
---@return table|nil loc { bufnr, mark, target_entry_p, insert_here, new_buffer }
---@return string|nil error
function M.resolve_target(tpl, ctx)
  local bufnr, line, col, entry_p = nil, nil, 0, true
  local loc = {}
  local t = tpl.target or tpl.file
  if ctx.here then
    bufnr = ctx.origin_buf or vim.api.nvim_get_current_buf()
    local cur = ctx.origin_cursor or vim.api.nvim_win_get_cursor(0)
    line, col = cur[1], cur[2]
    loc.insert_here = true
    entry_p = false
  elseif type(tpl.location) == "function" then
    -- (function f): the function chooses the buffer and position
    local b, l, c = tpl.location()
    bufnr = b or vim.api.nvim_get_current_buf()
    if not l then
      local cur = vim.api.nvim_win_get_cursor(0)
      l, c = cur[1], cur[2]
    end
    line, col = l, c or 0
    entry_p = parser.headline_level(get_line(bufnr, line) or "") ~= nil and col == 0
    loc.exact = not entry_p
  elseif t == "clock" then
    bufnr, line = M.clock_location()
    if not bufnr then
      return nil, "No running clock that could be used as capture target"
    end
  elseif tpl.id and not t then
    local found = require("org.id").find(tpl.id)
    if not found then
      return nil, string.format('Cannot find target ID "%s"', tpl.id)
    end
    loc.new_buffer = utils.find_buffer(found.filename) == nil
    bufnr = found.bufnr or utils.load_buffer(found.filename)
    local hl = files.get_buffer(bufnr):find_by_id(tpl.id)
    line = hl and hl.line or nil
  else
    local path = M.target_path(tpl)
    if not path then
      return nil, "Invalid file location"
    end
    loc.new_buffer = utils.find_buffer(path) == nil
    bufnr = utils.load_buffer(path)
    loc.was_modified = vim.bo[bufnr].modified
    if tpl.headline then
      local title = tpl.headline
      if type(title) == "function" then
        title = title()
      end
      line = find_or_create_headline(bufnr, title)
    elseif tpl.olp then
      local olp = tpl.olp
      if type(olp) == "function" then
        olp = vim.api.nvim_buf_call(bufnr, olp)
      end
      if type(olp) == "string" then
        olp = vim.split(olp, "/", { trimempty = true })
      end
      local nodes = files.get_buffer(bufnr).children
      local hl
      for i, name in ipairs(olp) do
        hl = nil
        for _, h in ipairs(nodes) do
          if h:plain_title() == name or h.title == name then
            hl = h
            break
          end
        end
        if not hl then
          return nil, string.format("Heading not found on level %d: %s", i, name)
        end
        nodes = hl.children
      end
      line = hl and hl.line or nil
    elseif tpl.regexp then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, l in ipairs(lines) do
        local m = vim.fn.matchstrpos(l, tpl.regexp)
        if m[2] >= 0 then
          line, col = i, tpl.prepend and m[2] or m[3]
          break
        end
      end
      if not line then
        return nil, "No match for target regexp in file " .. path
      end
      entry_p = parser.headline_level(get_line(bufnr, line)) ~= nil
      loc.exact = true
    elseif type(tpl.func) == "function" or type(tpl["function"]) == "function" then
      -- file+function: the function returns the line (and column), or
      -- moves the cursor
      local fn = tpl.func or tpl["function"]
      local l, c
      vim.api.nvim_buf_call(bufnr, function()
        l, c = fn(bufnr)
        if not l then
          local cur = vim.api.nvim_win_get_cursor(0)
          l, c = cur[1], cur[2]
        end
      end)
      line, col = l, c or 0
      entry_p = parser.headline_level(get_line(bufnr, line) or "") ~= nil and col == 0
      loc.exact = not entry_p
    else
      entry_p = false
    end
  end
  if loc.was_modified == nil and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    loc.was_modified = vim.bo[bufnr].modified
  end
  if tpl.datetree and not ctx.here then
    local tt = type(tpl.datetree) == "table" and tpl.datetree.tree_type or tpl.tree_type or "day"
    line = M.ensure_datetree(bufnr, entry_p and line or nil, ctx.date or date.today(), tt)
    col, entry_p, loc.exact = 0, true, false
  end
  if entry_p and not line then
    return nil, "Capture target not found"
  end
  loc.bufnr = bufnr
  loc.target_entry_p = entry_p
  if line then
    local len = #(get_line(bufnr, line) or "")
    local heading = entry_p and not loc.insert_here and files.get_buffer(bufnr):headline_on(line)
    if heading then
      -- the mark goes invalid when the headline line is deleted (or
      -- rewritten); the title then finds it again
      loc.title, loc.level = heading.title, heading.level
      loc.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, { invalidate = true })
    else
      loc.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, math.min(col, len), {})
    end
  end
  return loc
end

--- Current (line, col) of a location's mark.
local function mark_pos(loc)
  if not loc.mark or not vim.api.nvim_buf_is_valid(loc.bufnr) then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, loc.bufnr, ns, loc.mark, { details = true })
  if not ok or not pos or not pos[1] then
    return nil
  end
  if pos[3] and pos[3].invalid then
    local file = files.get_buffer(loc.bufnr)
    local hl = file:headline_on(pos[1] + 1)
    if hl and hl.title == loc.title and hl.level == loc.level then
      return hl.line, 0
    end
    local found
    for _, h in ipairs(file.headlines) do
      if h.title == loc.title and h.level == loc.level then
        if found then
          return nil -- ambiguous
        end
        found = h
      end
    end
    return found and found.line or nil, 0
  end
  return pos[1] + 1, pos[2]
end

local function release(loc)
  if loc and loc.mark and vim.api.nvim_buf_is_valid(loc.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, loc.bufnr, ns, loc.mark)
  end
end

---------------------------------------------------------------------------
-- Placing the captured text
---------------------------------------------------------------------------

--- Does `org-blank-before-new-entry` let org-back-over-empty-lines move?
local function heading_blank_setting()
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  return v ~= false and v ~= nil
end

--- org--blank-before-heading-p at the insertion point after line `at`.
local function blank_before_heading_p(bufnr, at)
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  if v ~= "auto" then
    return v == true
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(math.max(at + 1, 1))
  if not hl then
    hl = file.headlines[1]
    if not hl then
      return false
    end
  end
  if hl.line > 1 then
    return is_blank(get_line(bufnr, hl.line - 1))
  end
  local nxt = file.headlines[2]
  return nxt ~= nil and is_blank(get_line(bufnr, nxt.line - 1))
end

--- org-capture-empty-lines-before: replace the blank lines before the
--- insertion point (after line `at`) by `n` blank lines. Returns the new
--- insertion point.
local function empty_lines_before(bufnr, at, n)
  if heading_blank_setting() then
    local b = at
    while b > 0 and is_blank(get_line(bufnr, b)) do
      b = b - 1
    end
    if b < at then
      vim.api.nvim_buf_set_lines(bufnr, b, at, false, {})
      at = b
    end
  end
  if n > 0 and not is_empty_buffer(bufnr) then
    local blanks = {}
    for _ = 1, n do
      blanks[#blanks + 1] = ""
    end
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, blanks)
    at = at + n
  end
  return at
end

--- org-capture-empty-lines-after: exactly `n` blank lines after line `last`.
local function empty_lines_after(bufnr, last, n)
  local e = last
  local count = vim.api.nvim_buf_line_count(bufnr)
  while e < count and is_blank(get_line(bufnr, e + 1)) do
    e = e + 1
  end
  local blanks = {}
  if e < count or n > 0 then
    for _ = 1, n do
      blanks[#blanks + 1] = ""
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, last, e, false, blanks)
end

--- Split the line at (line, col) when col is inside it (Emacs inserts a
--- newline at the exact position); returns the insertion point (the text
--- goes after the returned line number).
local function split_at(bufnr, line, col)
  local l = get_line(bufnr, line) or ""
  if col <= 0 then
    return line - 1
  end
  if col >= #l then
    return line
  end
  vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { l:sub(1, col), l:sub(col + 1) })
  return line
end

local function first_list(bufnr, s, e)
  if e < s then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lists = require("org.lists").parse_region(lines, s, e)
  local l = lists[1]
  if not l then
    return nil
  end
  local first, last = l.items[1], l.items[1]
  for _, it in ipairs(l.items) do
    if it.end_lnum > last.end_lnum then
      last = it
    end
  end
  return { first = first.lnum, last = math.max(last.end_lnum, last.lnum), indent = first.indent, ordered = first.is_ordered }
end

--- End of the metadata after a headline (org-end-of-meta-data): planning
--- and properties; with `full`, also clock lines, drawers and blank lines.
local function meta_end(bufnr, hl, full)
  local at = edit.meta_end(hl)
  if not full then
    return at
  end
  local n = hl.body_end
  local i = at + 1
  while i <= n do
    local l = get_line(bufnr, i)
    if is_blank(l) or l:match("^%s*CLOCK:") then
      i = i + 1
    elseif l:match("^%s*:[%w_-]+:%s*$") and not l:match("^%s*:END:%s*$") then
      local j = i + 1
      while j <= n and not get_line(bufnr, j):match("^%s*:END:%s*$") do
        j = j + 1
      end
      if j > n then
        break
      end
      i = j + 1
    else
      break
    end
  end
  return i - 1
end

local function place_entry(bufnr, loc, tpl, lines, pos_line, pos_col)
  local file = files.get_buffer(bufnr)
  local level, at
  if loc.insert_here then
    local hl = file:headline_at(pos_line)
    level = hl and hl.level or 1
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    level = hl.level + 1
    at = tpl.prepend and hl.body_end or hl.end_line
  elseif tpl.prepend then
    at = file.headlines[1] and file.preamble_end or #file.lines
    level = 1
  else
    at = #file.lines
    level = 1
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  local n = tpl.empty_lines_before or tpl.empty_lines
  if n == nil and blank_before_heading_p(bufnr, at) and not is_blank(get_line(bufnr, at)) and at > 0 then
    n = 1
  end
  at = empty_lines_before(bufnr, at, n or 0)
  local new = edit.relevel(lines, level)
  at = put(bufnr, at, new)
  empty_lines_after(bufnr, at + #new, tpl.empty_lines_after or tpl.empty_lines or 0)
  return at + 1
end

local function place_plain(bufnr, loc, tpl, lines, pos_line, pos_col)
  local file = files.get_buffer(bufnr)
  local at
  if loc.insert_here then
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    at = tpl.prepend and meta_end(bufnr, hl, true) or hl.body_end
  elseif loc.exact then
    at = split_at(bufnr, pos_line, pos_col)
  else
    at = tpl.prepend and 0 or #file.lines
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  at = empty_lines_before(bufnr, at, tpl.empty_lines_before or tpl.empty_lines or 0)
  at = put(bufnr, at, lines)
  empty_lines_after(bufnr, at + #lines, tpl.empty_lines_after or tpl.empty_lines or 0)
  return at + 1
end

local function place_item(bufnr, loc, tpl, lines, pos_line, pos_col)
  local lists = require("org.lists")
  local file = files.get_buffer(bufnr)
  local s, e
  if loc.insert_here then
    s, e = pos_line, pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    s, e = hl.line + 1, hl.body_end
  elseif loc.exact then
    local hl = file:headline_at(pos_line)
    s, e = pos_line, hl and hl.body_end or #file.lines
  else
    s, e = 1, #file.lines
  end
  local list = not loc.insert_here and first_list(bufnr, s, e) or nil
  local at
  if list then
    at = tpl.prepend and list.first - 1 or list.last
  elseif loc.insert_here then
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif not tpl.prepend then
    at = e
  elseif loc.target_entry_p then
    at = math.max(meta_end(bufnr, file:headline_at(pos_line), false), s - 1)
  elseif not file:headline_at(s) then
    at = s - 1
  else
    at = math.max(meta_end(bufnr, file:headline_at(s), false), s - 1)
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  local eb = tpl.empty_lines_before or tpl.empty_lines
  local ea = tpl.empty_lines_after or tpl.empty_lines
  if not (list and tpl.prepend) then
    at = empty_lines_before(bufnr, at, list and math.min(1, eb or 0) or (eb or 0))
  end
  local new = vim.deepcopy(lines)
  -- the template's own indentation is removed (org-remove-indentation)
  local common
  for _, l in ipairs(new) do
    if not is_blank(l) then
      local ind = #l:match("^%s*")
      common = common and math.min(common, ind) or ind
    end
  end
  for i, l in ipairs(new) do
    new[i] = l:sub((common or 0) + 1)
    if list and not is_blank(new[i]) then
      new[i] = string.rep(" ", list.indent) .. new[i]
    end
  end
  if list and tpl.prepend then
    -- prepending must not change the type of the existing list
    local item = lists.parse_item_line(new[1])
    if item and item.is_ordered ~= list.ordered then
      new[1] = new[1]:gsub("^(%s*)(%S+)", "%1" .. (list.ordered and "1." or "-"), 1)
    end
  end
  at = put(bufnr, at, new)
  if list then
    lists.repair(bufnr, at + 1)
  end
  if not (list and not tpl.prepend) then
    local n = list and math.min(1, ea or 0) or (ea or 0)
    empty_lines_after(bufnr, at + #new, n)
  end
  return at + 1
end

local function place_table_line(bufnr, loc, tpl, lines, pos_line)
  local file = files.get_buffer(bufnr)
  local s, e
  if loc.insert_here then
    s, e = pos_line, pos_line
  elseif not loc.target_entry_p then
    s, e = 1, #file.lines
  else
    local hl = file:headline_at(pos_line)
    s, e = hl.line + 1, hl.body_end
  end
  if loc.exact and not loc.insert_here then
    local hl = file:headline_at(pos_line)
    s, e = pos_line, hl and hl.body_end or #file.lines
  end
  -- the first table (with a data line) in the region
  local ts, te
  local i = s
  while i <= e do
    local l = get_line(bufnr, i)
    if l and l:match("^%s*|") then
      local j = i
      local has_data = false
      while j + 1 <= #file.lines and (get_line(bufnr, j + 1) or ""):match("^%s*|") do
        j = j + 1
      end
      for k = i, j do
        if not get_line(bufnr, k):match("^%s*|%-") then
          has_data = true
        end
      end
      if has_data then
        ts, te = i, j
        break
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  if not ts then
    -- no table: create one with an empty header
    local at = loc.insert_here and pos_line - 1 or e
    if is_empty_buffer(bufnr) then
      at = 0
    end
    at = put(bufnr, at, { "|   |", "|---|" })
    ts, te = at + 1, at + 2
  end
  local at
  local pos = tpl.table_line_pos
  if loc.insert_here then
    at = te
  elseif pos and pos:match("^(I+)([-+]%d+)") then
    local roman, delta = pos:match("^(I+)([-+]%d+)")
    delta = tonumber(delta)
    local nth, hline = 0, nil
    for k = ts, te do
      if get_line(bufnr, k):match("^%s*|%-") then
        nth = nth + 1
        if nth == #roman then
          hline = k - ts + 1
          break
        end
      end
    end
    if not hline then
      error(string.format("Invalid table line specification %q", pos), 0)
    end
    at = ts - 1 + hline + delta + (delta < 0 and 1 or 0) - 1
  elseif tpl.prepend then
    at = ts - 1
    for k = ts, te do
      if get_line(bufnr, k):match("^%s*|%-") then
        at = te
        for k2 = k + 1, te do
          if not get_line(bufnr, k2):match("^%s*|%-") then
            at = k2 - 1
            break
          end
        end
        break
      end
    end
  else
    at = te
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  pcall(require("org.table").align_at, bufnr, at + 1)
  return at + 1
end

--- Store `lines` at a resolved location. Returns the first stored line.
function M.place(loc, tpl, lines)
  local bufnr = loc.bufnr
  local line, col = mark_pos(loc)
  if loc.mark and not line then
    return nil
  end
  if loc.target_entry_p and not loc.insert_here then
    local hl = line and files.get_buffer(bufnr):headline_at(line)
    if not hl or hl.line ~= line then
      return nil
    end
  end
  line, col = line or 1, col or 0
  local ttype = tpl.type or "entry"
  local first
  if ttype == "entry" then
    first = place_entry(bufnr, loc, tpl, lines, line, col)
  elseif ttype == "item" or ttype == "checkitem" then
    first = place_item(bufnr, loc, tpl, lines, line, col)
  elseif ttype == "table-line" then
    first = place_table_line(bufnr, loc, tpl, lines, line)
  else
    first = place_plain(bufnr, loc, tpl, lines, line, col)
  end
  -- update statistics cookies around the new text
  pcall(require("org.lists").update_statistics_for, bufnr, first)
  return first
end

--- Resolve the target of `tpl` and insert `lines` there (no capture
--- buffer). Returns the first inserted line.
function M.insert(bufnr, tpl, lines, ctx)
  ctx = ctx or {}
  local loc, err = M.resolve_target(tpl, ctx)
  if not loc then
    error(err, 0)
  end
  if bufnr and loc.bufnr ~= bufnr then
    error("capture target is not in buffer " .. bufnr, 0)
  end
  local l = M.place(loc, tpl, lines)
  release(loc)
  return l
end

---------------------------------------------------------------------------
-- Capture session
---------------------------------------------------------------------------

local function origin_context(opts)
  local ctx = { keywords = {} }
  local bufnr = vim.api.nvim_get_current_buf()
  ctx.origin_buf = bufnr
  ctx.origin_cursor = vim.api.nvim_win_get_cursor(0)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and vim.bo[bufnr].buftype == "" then
    ctx.origin_file = name
  end
  local ok, l = pcall(function()
    return require("org.links").link_to_location({ interactive = false })
  end)
  if ok and l then
    ctx.link = l.link
    ctx.link_desc = l.desc
    ctx.annotation = require("org.links").format(l.link, l.desc)
  end
  ctx.initial = opts.initial or ""
  return ctx
end

local function trim_blank(lines)
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

--- Call a template hook (:prepare-finalize, :before-finalize,
--- :after-finalize), reporting errors without aborting the capture.
local function run_hook(fn, ...)
  if type(fn) ~= "function" then
    return
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    utils.error("Capture hook failed: " .. tostring(err))
  end
end

local function first_headline_line(bufnr, start)
  local n = vim.api.nvim_buf_line_count(bufnr)
  for i = start, n do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if parser.headline_level(l) then
      return i
    end
  end
  return start
end

--- :clock-in: the capture clocks into the new entry from the start of the
--- capture (the running clock is stopped then). At the end the clock keeps
--- running with :clock-keep; otherwise it is clocked out and, with
--- :clock-resume, the interrupted task is clocked in again.
local function start_clock(tpl, ctx)
  if not tpl.clock_in then
    return
  end
  local clock = require("org.clock")
  ctx.clock_start = date.now()
  ctx.interrupted_clock = clock.current_task()
  if ctx.interrupted_clock then
    clock.clock_out({ quiet = true })
  end
end

local function resume_interrupted(tpl, ctx)
  if tpl.clock_resume and not tpl.clock_keep and ctx.interrupted_clock then
    require("org.clock").clock_in_task(ctx.interrupted_clock)
    utils.notify("Interrupted clock has been resumed")
  end
end

local function finish_clock(tpl, ctx, bufnr, line)
  local clock = require("org.clock")
  -- a non-entry capture clocks the entry it lands in
  local hl = files.get_buffer(bufnr):headline_at(line)
  if not hl then
    return
  end
  if tpl.clock_keep then
    clock.clock_in({ bufnr = bufnr, lnum = hl.line }, { at = ctx.clock_start, no_count = true })
  else
    clock.add_clock(bufnr, hl.line, ctx.clock_start, date.now())
    resume_interrupted(tpl, ctx)
  end
end

--- Store the captured text at its target. Returns (bufnr, line), or nil
--- when the text could not be stored (the target is gone).
function M.store(tpl, lines, ctx)
  ctx = ctx or {}
  lines = trim_blank(vim.deepcopy(lines))
  local ttype = tpl.type or "entry"
  if #lines == 0 then
    utils.warn("Capture is empty, nothing stored")
    return nil
  end
  local loc = ctx.loc
  if not loc then
    local err
    loc, err = M.resolve_target(tpl, ctx)
    if not loc then
      utils.warn(err)
      return nil
    end
    ctx.loc = loc
  end
  lines = vim.split(shape(table.concat(lines, "\n"), ttype), "\n", { plain = true })
  local bufnr = loc.bufnr
  local ok, line = pcall(M.place, loc, tpl, lines)
  if not ok then
    utils.warn(tostring(line))
    return nil
  end
  if not line then
    utils.warn("Capture target is gone, the text is kept in the capture buffer")
    return nil
  end
  release(loc)
  if ttype == "entry" then
    line = first_headline_line(bufnr, line)
  end
  if ctx.clock_start then
    finish_clock(tpl, ctx, bufnr, line)
  end
  require("org.refile").remember(bufnr, line)
  run_hook(tpl.before_finalize, bufnr, line)
  if not tpl.no_save then
    utils.save_buffer(bufnr)
  end
  return bufnr, line
end

local function close_session(buf)
  local s = M.sessions[buf]
  M.sessions[buf] = nil
  if s and s.win and vim.api.nvim_win_is_valid(s.win) then
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, s.win, true)
    elseif s.origin_buf and vim.api.nvim_buf_is_valid(s.origin_buf) then
      vim.api.nvim_win_set_buf(s.win, s.origin_buf)
    end
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modified = false
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if s and s.origin_win and vim.api.nvim_win_is_valid(s.origin_win) then
    pcall(vim.api.nvim_set_current_win, s.origin_win)
  end
end

--- With :kill-buffer, unload a target buffer that the capture loaded.
local function kill_target(tpl, loc)
  if tpl.kill_buffer and loc and loc.new_buffer and vim.api.nvim_buf_is_valid(loc.bufnr) then
    if vim.fn.bufwinid(loc.bufnr) == -1 then
      utils.save_buffer(loc.bufnr)
      pcall(vim.api.nvim_buf_delete, loc.bufnr, {})
    end
  end
end

--- Finish the capture in buffer `buf` (default: current). With a count
--- (C-u C-c C-c) or `jump_to_captured`, jump to the stored entry.
---@param buf? integer
---@param opts? { refile?: boolean, jump?: boolean }
function M.finalize(buf, opts)
  opts = opts or {}
  local jump = opts.jump
  if jump == nil then
    jump = vim.v.count > 0
  end
  buf = buf or vim.api.nvim_get_current_buf()
  local s = M.sessions[buf]
  if not s then
    utils.warn("Not a capture buffer")
    return
  end
  local tpl = s.template
  if opts.refile and (tpl.type or "entry") ~= "entry" then
    utils.warn("Refiling from a capture buffer makes only sense for `entry'-type templates")
    return
  end
  vim.cmd("stopinsert")
  run_hook(tpl.prepare_finalize, buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- store first: the capture buffer stays open when that fails
  local dbuf, dline = M.store(tpl, lines, s.ctx)
  if not dbuf then
    return
  end
  close_session(buf)
  if opts.refile then
    local refile = require("org.refile")
    local rbuf, rline = refile.refile({ bufnr = dbuf, lnum = dline }, { targets = tpl.refile_targets })
    if rbuf then
      dbuf, dline = rbuf, rline
    end
  else
    utils.notify("Captured to " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(dbuf), ":~"))
  end
  kill_target(tpl, s.ctx.loc)
  if (tpl.jump_to_captured or jump) and dbuf then
    M.goto_last_stored()
  end
  run_hook(tpl.after_finalize, dbuf, dline)
  return dbuf, dline
end

--- Jump to the location of the last capture or refile
--- (org-capture-goto-last-stored, C-u C-u C-c c).
function M.goto_last_stored()
  return require("org.refile").goto_last_stored()
end

--- Choose a template and jump to its target location, creating missing
--- headlines like a capture would (org-capture-goto-target, C-u C-c c).
---@param key? string template key (prompted when nil)
function M.goto_target(key)
  if not key then
    local items = M.menu_items()
    key = ui.menu({ title = "Go to capture target", items = items })
    if type(key) ~= "string" then
      return
    end
  end
  local tpl = M.get_template(key)
  if not tpl then
    utils.warn("No capture template for key: " .. key)
    return
  end
  local loc, err = M.resolve_target(tpl, { date = date.today() })
  if not loc then
    utils.warn(err)
    return
  end
  local line = mark_pos(loc) or 1
  release(loc)
  vim.cmd("normal! m'")
  local name = vim.api.nvim_buf_get_name(loc.bufnr)
  utils.open_file(name, line)
  return loc.bufnr, line
end

--- Abort the capture.
function M.kill(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.sessions[buf] then
    return
  end
  vim.cmd("stopinsert")
  local s = M.sessions[buf]
  close_session(buf)
  local loc = s.ctx.loc
  release(loc)
  if loc and vim.api.nvim_buf_is_valid(loc.bufnr) and not loc.was_modified and vim.bo[loc.bufnr].modified then
    -- drop the headlines / date tree nodes created for the capture
    if loc.new_buffer and vim.fn.bufwinid(loc.bufnr) == -1 then
      pcall(vim.api.nvim_buf_delete, loc.bufnr, { force = true })
    else
      pcall(vim.api.nvim_buf_call, loc.bufnr, function()
        vim.cmd("silent! edit!")
      end)
    end
  end
  utils.notify("Capture aborted")
  if s.ctx.clock_start then
    -- nothing was clocked; :clock-resume restarts the interrupted clock
    resume_interrupted(vim.tbl_extend("force", s.template, { clock_keep = false }), s.ctx)
  end
end

--- Finalize, then refile the captured entry (org-capture-refile). The
--- template's `refile_targets` replace `refile.targets`.
function M.refile(buf)
  return M.finalize(buf, { refile = true })
end

local function hint()
  local maps = config.opts.mappings.capture or {}
  local function first(v)
    return config.lhs_list(v)[1] or "-"
  end
  return string.format(
    " Capture: finish %s  refile %s  abort %s  (:w finishes)",
    first(maps.finalize),
    first(maps.refile),
    first(maps.kill)
  ):gsub("%%", "%%%%")
end

--- Open the capture buffer.
local function open_buffer(tpl, text, ctx)
  local buf = vim.api.nvim_create_buf(false, false)
  local name = "CAPTURE-" .. (tpl.key or "x")
  if vim.fn.bufexists(name) == 1 then
    name = name .. "-" .. buf
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local lines = vim.split(text, "\n", { plain = true })
  local cursor
  for i, l in ipairs(lines) do
    local c = l:find(CURSOR, 1, true)
    if c and not cursor then
      cursor = { i, c - 1 }
    end
    lines[i] = l:gsub(CURSOR, "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, p in ipairs(ctx.properties or {}) do
    if parser.headline_level(lines[1] or "") then
      edit.set_property(buf, 1, p[1], p[2])
    end
  end
  vim.bo[buf].modified = false

  local session = {
    template = tpl,
    ctx = ctx,
    origin_buf = ctx.origin_buf or vim.api.nvim_get_current_buf(),
    origin_win = vim.api.nvim_get_current_win(),
  }
  M.sessions[buf] = session
  local win = ui.open_buffer_window(buf, (config.opts.capture or {}).window or "split", {
    title = "Capture: " .. (tpl.description or tpl.key or ""),
  })
  session.win = win
  vim.bo[buf].filetype = "org"
  vim.wo[win].winbar = hint()

  local maps = config.opts.mappings.capture or {}
  for _, lhs in ipairs(config.lhs_list(maps.finalize)) do
    vim.keymap.set({ "n" }, lhs, function()
      local jump = vim.v.count > 0
      utils.run(M.finalize, buf, { jump = jump })
    end, { buffer = buf, desc = "org: finalize capture (count: and jump to it)" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.kill)) do
    vim.keymap.set({ "n" }, lhs, function()
      M.kill(buf)
    end, { buffer = buf, desc = "org: abort capture" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.refile)) do
    vim.keymap.set({ "n" }, lhs, function()
      utils.run(M.refile, buf)
    end, { buffer = buf, desc = "org: refile capture" })
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      utils.run(M.finalize, buf, { jump = false })
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local s = M.sessions[buf]
      M.sessions[buf] = nil
      if s then
        release(s.ctx.loc)
      end
    end,
  })
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
    if not vim.g.org_test then
      local len = #(lines[cursor[1]] or "")
      if cursor[2] >= len then
        vim.cmd("startinsert!")
      else
        vim.cmd("startinsert")
      end
    end
  end
  return buf, win
end

--- Start a capture.
---@param tpl_or_key string|table template key or template table
---@param opts? { initial?: string, date?: table, here?: boolean, date_prompt?: boolean }
---@return integer|nil capture buffer (or target buffer with immediate_finish)
function M.capture(tpl_or_key, opts)
  opts = opts or {}
  local tpl = tpl_or_key
  if type(tpl_or_key) == "string" then
    tpl = M.get_template(tpl_or_key)
    if not tpl then
      utils.warn("No capture template for key: " .. tpl_or_key)
      return
    end
  end
  local ctx = origin_context(opts)
  ctx.date = opts.date
  ctx.here = opts.here
  if (tpl.time_prompt or (opts.date_prompt and tpl.datetree)) and not ctx.date then
    ctx.date = pick_date(tpl.time_prompt and "Capture date" or "Date for tree entry", false, date.today())
    if not ctx.date then
      return
    end
  end
  -- the target is resolved (and headlines / date tree nodes created)
  -- before the template is expanded, like Emacs
  local loc, err = M.resolve_target(tpl, ctx)
  if not loc then
    utils.warn(err)
    return
  end
  ctx.loc = loc
  ctx.target_file = files.get_buffer(loc.bufnr)
  local line = mark_pos(loc)
  ctx.target_hl = line and ctx.target_file:headline_at(line) or nil
  local ttype = tpl.type or "entry"
  local ok, expanded = pcall(M.expand, template_text(tpl, ctx), ctx)
  if not ok then
    release(loc)
    if tostring(expanded):find("org_abort", 1, true) then
      return
    end
    error(expanded, 0)
  end
  expanded = shape(expanded, ttype)
  if tpl.properties and ttype == "entry" then
    for k, v in pairs(tpl.properties) do
      ctx.properties[#ctx.properties + 1] = { k, v }
    end
  end
  start_clock(tpl, ctx)
  if tpl.immediate_finish then
    local lines = vim.split((expanded:gsub(CURSOR, "")), "\n", { plain = true })
    if #ctx.properties > 0 and ttype == "entry" then
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      for _, p in ipairs(ctx.properties) do
        edit.set_property(b, 1, p[1], p[2])
      end
      lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      vim.api.nvim_buf_delete(b, { force = true })
    end
    local dbuf, dline = M.store(tpl, lines, ctx)
    if dbuf then
      utils.notify("Captured to " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(dbuf), ":~"))
      kill_target(tpl, loc)
      if tpl.jump_to_captured then
        M.goto_last_stored()
      end
      run_hook(tpl.after_finalize, dbuf, dline)
    end
    return dbuf, dline
  end
  return open_buffer(tpl, expanded, ctx)
end

return M
