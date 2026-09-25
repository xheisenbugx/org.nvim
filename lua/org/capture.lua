---@mod org.capture Capture (org-capture)
---
--- Templates live in `capture.templates`, keyed by their selection key:
---
---   templates = {
---     t = { description = "Task", template = "* TODO %?\n  %U", target = "~/org/inbox.org", headline = "Tasks" },
---     j = { description = "Journal", template = "* %<%H:%M> %?", target = "~/org/journal.org", datetree = true },
---     w = "Work",                                  -- group; its templates use keys "wX"
---     wm = { description = "Meeting", template = "* MEETING %? :meeting:\n  %T", olp = { "Work", "Meetings" } },
---   }
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

--- Active capture sessions: bufnr -> session
M.sessions = {}

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

local function is_template(v)
  return type(v) == "table" and (v.template ~= nil or v.type ~= nil or v.target ~= nil or v.file ~= nil)
end

--- Template for `key` (a copy with `key` set), or nil.
function M.get_template(key)
  local t = (config.opts.capture.templates or {})[key]
  if not is_template(t) then
    return nil
  end
  local copy = vim.tbl_extend("force", {}, t)
  copy.key = key
  return copy
end

--- Menu items for the selection dispatcher.
function M.menu_items()
  local entries = {}
  for key, t in pairs(config.opts.capture.templates or {}) do
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
--- visual mode the selection becomes `opts.initial` (`%i`). Must run inside
--- a coroutine; `require("org").capture()` handles that.
---@param opts? table `{ initial?: string, date?: table }`, as for `capture()`
---@return integer|nil capture buffer (nil when cancelled)
function M.prompt(opts)
  opts = opts or {}
  opts.initial = opts.initial or visual_selection()
  local items = M.menu_items()
  if #items == 0 then
    utils.warn("No capture templates configured")
    return
  end
  local key = ui.menu({ title = "Capture", items = items })
  if type(key) ~= "string" then
    return
  end
  return M.capture(key, opts)
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
-- Expansion
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

local function all_tags(target_file)
  local seen, out = {}, {}
  local function add(t)
    if t and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  if target_file then
    for _, d in ipairs(target_file:tag_definitions()) do
      add(d.name)
    end
  end
  for _, spec in ipairs(config.opts.tags or {}) do
    for tok in spec:gmatch("%S+") do
      add((tok:match("^([^%(]+)") or tok))
    end
  end
  for _, f in ipairs(files.agenda_files()) do
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        add(t)
      end
    end
    for _, t in ipairs(f.settings.filetags) do
      add(t)
    end
  end
  table.sort(out)
  return out
end

local function prompt_tags(ctx, global)
  local candidates = all_tags(not global and ctx.target_file or nil)
  local v = utils.input_complete("Tags: ", candidates)
  if not v then
    utils.abort()
  end
  local tags = {}
  for t in v:gmatch("[^:%s]+") do
    tags[#tags + 1] = t
  end
  ctx.tags = tags
  if #tags == 0 then
    return ""
  end
  return ":" .. table.concat(tags, ":") .. ":"
end

local function clipboard_items()
  local out, seen = {}, {}
  for _, r in ipairs({ "+", "*", '"', "0" }) do
    local ok, v = pcall(vim.fn.getreg, r)
    if ok and v and v ~= "" and not seen[v] then
      seen[v] = true
      out[#out + 1] = (v:gsub("\n$", ""))
    end
  end
  return out
end

local function clock_task()
  local ok, clock = pcall(require, "org.clock")
  if not ok then
    return nil
  end
  for _, name in ipairs({ "get_active", "active", "current" }) do
    local f = clock[name]
    if type(f) == "function" then
      local ok2, info = pcall(f)
      if ok2 and type(info) == "table" then
        return info
      end
    end
  end
  return nil
end

local function ask(prompt, default, options)
  local v
  if options and #options > 1 then
    v = utils.input_complete(prompt .. ": ", options, default)
  else
    v = utils.input({ prompt = prompt .. ": ", default = default or "" })
  end
  if v == nil then
    utils.abort()
  end
  return v
end

--- Expand a template string. Must run inside a coroutine when it prompts.
---@param text string
---@param ctx table { origin_file?, annotation?, link?, link_desc?, initial?, date?, answers?, properties?, target_file? }
---@return string text with CURSOR marker, table ctx
function M.expand(text, ctx)
  ctx = ctx or {}
  ctx.answers = ctx.answers or {}
  ctx.properties = ctx.properties or {}
  local base_date = ctx.date
  local out = {}
  local i = 1
  local n = #text
  local function current_line_prefix()
    local joined = table.concat(out)
    return joined:match("([^\n]*)$") or ""
  end
  while i <= n do
    local p = text:find("%", i, true)
    if not p then
      out[#out + 1] = text:sub(i)
      break
    end
    out[#out + 1] = text:sub(i, p - 1)
    local rest = text:sub(p + 1)
    local consumed, value = 1, nil
    local m1, m2
    if rest:sub(1, 1) == "%" then
      value, consumed = "%", 1
    elseif rest:sub(1, 1) == "?" then
      value, consumed = CURSOR, 1
    elseif rest:match("^<[^>]+>") then
      m1 = rest:match("^<([^>]+)>")
      value = os.date(m1, (base_date or date.now()):to_time())
      consumed = #m1 + 2
    elseif rest:match("^%^{[^}]*}[tTuUgGpCL]?") then
      m1, m2 = rest:match("^%^{([^}]*)}([tTuUgGpCL]?)")
      consumed = 3 + #m1 + #m2
      local parts = vim.split(m1, "|", { plain = true })
      local label = parts[1]
      if m2 == "p" then
        local allowed = nil
        local v = ask(label, parts[2], allowed)
        ctx.properties[#ctx.properties + 1] = { label, v }
        value = ""
      elseif m2 == "t" or m2 == "T" or m2 == "u" or m2 == "U" then
        local d = pick_date(label, m2 == "T" or m2 == "U", base_date)
        if not d then
          utils.abort()
        end
        value = fmt_date(d, m2 == "T" or m2 == "U", m2 == "t" or m2 == "T")
        ctx.answers[#ctx.answers + 1] = value
      elseif m2 == "g" or m2 == "G" then
        value = prompt_tags(ctx, m2 == "G")
      elseif m2 == "C" or m2 == "L" then
        local items = clipboard_items()
        local v = #items > 1 and utils.select(items, { prompt = label }) or items[1] or ""
        value = m2 == "L" and ("[[" .. v .. "]]") or v
      else
        local options = {}
        for k = 2, #parts do
          options[#options + 1] = parts[k]
        end
        value = ask(label, parts[2], options)
        ctx.answers[#ctx.answers + 1] = value
      end
    elseif rest:match("^%^[tTuU]") then
      local k = rest:sub(2, 2)
      local d = pick_date("Date", k == "T" or k == "U", base_date)
      if not d then
        utils.abort()
      end
      value = fmt_date(d, k == "T" or k == "U", k == "t" or k == "T")
      consumed = 2
    elseif rest:match("^%^[gG]") then
      value = prompt_tags(ctx, rest:sub(2, 2) == "G")
      consumed = 2
    elseif rest:match("^%^[CL]") then
      local items = clipboard_items()
      local v = #items > 1 and utils.select(items, { prompt = "Clipboard" }) or items[1] or ""
      value = rest:sub(2, 2) == "L" and ("[[" .. v .. "]]") or v
      consumed = 2
    elseif rest:match("^\\%d") then
      local idx = tonumber(rest:sub(2, 2))
      value = ctx.answers[idx] or ""
      consumed = 2
    elseif rest:match("^:[%w_%-]+") then
      m1 = rest:match("^:([%w_%-]+)")
      local map = {
        link = ctx.link,
        description = ctx.link_desc,
        annotation = ctx.annotation,
        initial = ctx.initial,
      }
      value = map[m1] or (ctx.keywords and ctx.keywords[m1]) or ""
      consumed = 1 + #m1
    elseif rest:sub(1, 1) == "(" then
      -- %(lua expression), like Emacs %(sexp)
      local depth, j = 0, nil
      for k = 1, #rest do
        local ch = rest:sub(k, k)
        if ch == "(" then
          depth = depth + 1
        elseif ch == ")" then
          depth = depth - 1
          if depth == 0 then
            j = k
            break
          end
        end
      end
      if j then
        local expr = rest:sub(2, j - 1)
        local chunk, err = loadstring("return " .. expr)
        local ok_eval, res = false, err
        if chunk then
          ok_eval, res = pcall(chunk)
        end
        if not ok_eval then
          utils.warn("Capture %(" .. expr .. "): " .. tostring(res))
          res = ""
        end
        value = res == nil and "" or tostring(res)
        consumed = j
      else
        value = "%"
        consumed = 0
      end
    elseif rest:match("^%[[^%]]+%]") then
      m1 = rest:match("^%[([^%]]+)%]")
      local lines = utils.readfile(utils.expand(m1)) or {}
      value = table.concat(lines, "\n")
      consumed = #m1 + 2
    else
      local k = rest:sub(1, 1)
      if k == "t" or k == "T" or k == "u" or k == "U" then
        value = fmt_date(base_date or date.now(), k == "T" or k == "U", k == "t" or k == "T")
      elseif k == "a" then
        value = ctx.annotation or ""
      elseif k == "A" then
        if ctx.link then
          local d = utils.input({ prompt = "Link description: ", default = ctx.link_desc or "" })
          value = require("org.links").format(ctx.link, d)
        else
          value = ""
        end
      elseif k == "l" then
        value = ctx.link and ("[[" .. ctx.link .. "]]") or ""
      elseif k == "L" then
        value = ctx.link or ""
      elseif k == "i" then
        local init = ctx.initial or ""
        local prefix = current_line_prefix()
        local indent = prefix:match("^%s*$") and prefix or string.rep(" ", #prefix)
        value = init:gsub("\n", "\n" .. indent)
      elseif k == "x" then
        value = (vim.fn.getreg("+") or ""):gsub("\n$", "")
      elseif k == "c" then
        value = (vim.fn.getreg('"') or ""):gsub("\n$", "")
      elseif k == "f" then
        value = ctx.origin_file and vim.fn.fnamemodify(ctx.origin_file, ":t") or ""
      elseif k == "F" then
        value = ctx.origin_file or ""
      elseif k == "n" then
        value = vim.env.USER or vim.env.USERNAME or ""
      elseif k == "k" or k == "K" then
        local task = clock_task()
        if task then
          local title = task.title or (task.headline and task.headline.title) or ""
          if k == "k" then
            value = title
          else
            local fname = task.filename or task.file or task.path
            value = fname and ("[[file:" .. fname .. "::*" .. title .. "][" .. title .. "]]") or title
          end
        else
          value = ""
        end
      else
        value = "%"
        consumed = 0
      end
    end
    out[#out + 1] = value
    i = p + 1 + consumed
  end
  return table.concat(out), ctx
end

local DEFAULT_TEMPLATES = {
  entry = "* %?",
  item = "- %?",
  checkitem = "- [ ] %?",
  ["table-line"] = "| %? |",
  plain = "%?",
}

--- Normalize the expanded text according to the template type.
local function shape(text, ttype)
  if ttype == "entry" then
    if not text:match("^%*+%s") and not text:match("^%*+$") then
      text = "* " .. text
    end
  elseif ttype == "item" then
    if not text:match("^%s*[-+]%s") and not text:match("^%s*%d+[.)]%s") then
      text = "- " .. text
    end
  elseif ttype == "checkitem" then
    if not text:match("^%s*[-+]%s") then
      text = "- [ ] " .. text
    elseif not text:match("^%s*[-+]%s+%[.%]") then
      text = text:gsub("^(%s*[-+]%s+)", "%1[ ] ")
    end
  elseif ttype == "table-line" then
    if not text:match("^%s*|") then
      text = "| " .. text .. " |"
    end
  end
  return text
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

--- Absolute target file for a template.
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
  t = t or config.opts.default_notes_file
  return utils.expand(t)
end

--- Find or create a child headline `title` under `parent_lnum` (nil = top level).
---@param sorted? boolean insert among siblings in sorted order (datetrees)
local function ensure_child(bufnr, parent_lnum, title, level, sorted)
  local file = files.get_buffer(bufnr)
  local parent = parent_lnum and file:headline_at(parent_lnum) or nil
  local children = parent and parent.children or file.children
  for _, ch in ipairs(children) do
    if ch:plain_title() == title or ch.title == title then
      return ch.line
    end
  end
  level = parent and parent.level + 1 or (level or 1)
  local line = string.rep("*", level) .. " " .. title
  local at
  if sorted then
    for _, ch in ipairs(children) do
      if ch.title:match("^%d") and ch.title > title then
        at = ch.line - 1
        break
      end
    end
  end
  if not at then
    at = parent and parent.end_line or #file.lines
    -- keep trailing blank lines after the new node
    while at > (parent and parent.line or 0) and vim.trim(file.lines[at] or "x") == "" do
      at = at - 1
    end
  end
  if not parent and #file.lines == 1 and file.lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
    return 1
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { line })
  return at + 1
end

--- Create/find the datetree for `d` under parent; returns the day (or month) node line.
function M.ensure_datetree(bufnr, parent_lnum, d, tree_type)
  tree_type = tree_type or "day"
  local t = d:to_time()
  if tree_type == "week" then
    local year = os.date("%G", t)
    local y = ensure_child(bufnr, parent_lnum, year, nil, true)
    local w = ensure_child(bufnr, y, year .. "-W" .. os.date("%V", t), nil, true)
    return ensure_child(bufnr, w, d:to_date_string() .. " " .. date.DAY_NAMES_LONG[d:weekday()], nil, true)
  end
  local y = ensure_child(bufnr, parent_lnum, string.format("%04d", d.year), nil, true)
  local m = ensure_child(
    bufnr,
    y,
    string.format("%04d-%02d %s", d.year, d.month, date.MONTH_NAMES_LONG[d.month]),
    nil,
    true
  )
  if tree_type == "month" then
    return m
  end
  return ensure_child(bufnr, m, d:to_date_string() .. " " .. date.DAY_NAMES_LONG[d:weekday()], nil, true)
end

--- Resolve the parent headline line (nil = file top level) and extra info.
---@return integer|nil parent_lnum, integer|nil anchor_line (file+regexp)
function M.resolve_location(bufnr, tpl, ctx)
  local parent
  local t = tpl.target or tpl.file
  if t == "clock" then
    local _, line = M.clock_location()
    parent = line
  elseif tpl.id then
    local hl = files.get_buffer(bufnr):find_by_id(tpl.id)
    parent = hl and hl.line or nil
  elseif tpl.headline then
    local file = files.get_buffer(bufnr)
    local hl = file:find_by_title(tpl.headline)
    parent = hl and hl.line or ensure_child(bufnr, nil, tpl.headline, 1)
  elseif tpl.olp then
    local olp = type(tpl.olp) == "string" and vim.split(tpl.olp, "/", { trimempty = true }) or tpl.olp
    for _, name in ipairs(olp) do
      parent = ensure_child(bufnr, parent, name, 1)
    end
  elseif tpl.regexp then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if vim.fn.match(l, tpl.regexp) >= 0 then
        local hl = files.get_buffer(bufnr):headline_at(i)
        return hl and hl.line or nil, i
      end
    end
    utils.warn("No match for capture regexp: " .. tpl.regexp)
  elseif type(tpl.func) == "function" or type(tpl["function"]) == "function" then
    local fn = tpl.func or tpl["function"]
    parent = vim.api.nvim_buf_call(bufnr, function()
      return fn(bufnr)
    end)
  end
  if tpl.datetree then
    local tt = type(tpl.datetree) == "table" and tpl.datetree.tree_type or tpl.tree_type or "day"
    parent = M.ensure_datetree(bufnr, parent, ctx.date or date.today(), tt)
  end
  return parent
end

local function add_blank(lines, before, after)
  local out = {}
  for _ = 1, before or 0 do
    out[#out + 1] = ""
  end
  vim.list_extend(out, lines)
  for _ = 1, after or 0 do
    out[#out + 1] = ""
  end
  return out
end

local function is_item(line)
  return line:match("^%s*[-+]%s") or line:match("^%s+%*%s") or line:match("^%s*%d+[.)]%s")
end

--- Insert captured lines at the location. Returns the first inserted line.
function M.insert(bufnr, tpl, lines, ctx)
  local ttype = tpl.type or "entry"
  local parent_lnum, anchor = M.resolve_location(bufnr, tpl, ctx or {})
  local file = files.get_buffer(bufnr)
  local parent = parent_lnum and file:headline_at(parent_lnum) or nil
  local before = tpl.empty_lines_before or tpl.empty_lines or 0
  local after = tpl.empty_lines_after or tpl.empty_lines or 0

  if ttype == "entry" then
    local level = parent and parent.level + 1 or 1
    local new = edit.relevel(lines, level)
    local at
    if parent then
      at = tpl.prepend and parent.body_end or parent.end_line
    else
      at = tpl.prepend and file.preamble_end or #file.lines
    end
    if not tpl.prepend then
      while at > (parent and parent.line or 0) and vim.trim(file.lines[at] or "x") == "" do
        at = at - 1
      end
    end
    if not parent and #file.lines == 1 and file.lines[1] == "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, add_blank(new, 0, after))
      return 1
    end
    local block = add_blank(new, before, after)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
    return at + 1 + before
  end

  -- body-level insertion (item / checkitem / table-line / plain)
  local s, e
  if parent then
    s = edit.meta_end(parent) + 1
    e = parent.body_end
  else
    s, e = 1, file.preamble_end
  end
  -- skip drawers right after the meta lines
  local at
  if anchor then
    at = anchor
  elseif ttype == "item" or ttype == "checkitem" then
    local first, last, indent
    for i = s, e do
      local l = file.lines[i]
      if is_item(l) then
        first = first or i
        last = i
        indent = indent or l:match("^(%s*)")
      elseif first and (l:match("^%s+%S") and #l:match("^(%s*)") > #indent) then
        last = i
      elseif first and vim.trim(l) ~= "" then
        break
      end
    end
    if first then
      local new = vim.tbl_map(function(l)
        return indent .. l
      end, lines)
      at = tpl.prepend and first - 1 or last
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, new)
      return at + 1
    end
  elseif ttype == "table-line" then
    local first, last
    for i = s, e do
      local l = file.lines[i]
      if l:match("^%s*|") then
        first = first or i
        last = i
      elseif first then
        break
      end
    end
    if first then
      if tpl.prepend then
        -- after the header hline if there is one
        at = first
        for i = first, last do
          if file.lines[i]:match("^%s*|%-") then
            at = i
            break
          end
        end
      else
        at = last
        if file.lines[last]:match("^%s*|%-") and last > first then
          at = last - 1
        end
      end
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
      pcall(function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.api.nvim_win_set_cursor(0, { at + 1, 1 })
          require("org.table").align()
        end)
      end)
      return at + 1
    end
  end
  if not at then
    if tpl.prepend then
      at = s - 1
      if not parent then
        -- keep leading #+KEYWORD lines at the top of the file
        while at < e and (file.lines[at + 1] or ""):match("^#%+") do
          at = at + 1
        end
      end
    else
      at = e
      while at >= s and vim.trim(file.lines[at] or "x") == "" do
        at = at - 1
      end
    end
  end
  local block = add_blank(lines, before, after)
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
  return at + 1 + before
end

---------------------------------------------------------------------------
-- Capture session
---------------------------------------------------------------------------

local function origin_context(opts)
  local ctx = { keywords = {} }
  local bufnr = vim.api.nvim_get_current_buf()
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

local function save_if_hidden(bufnr)
  if vim.fn.bufwinid(bufnr) == -1 then
    utils.save_buffer(bufnr)
  end
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

--- Store the captured text at its target. Returns (bufnr, line).
function M.store(tpl, lines, ctx)
  ctx = ctx or {}
  lines = trim_blank(vim.deepcopy(lines))
  if #lines == 0 then
    utils.warn("Capture is empty, nothing stored")
    return nil
  end
  local path = M.target_path(tpl)
  if not path then
    utils.warn("Capture target is gone, nothing stored")
    return nil
  end
  local bufnr = utils.load_buffer(path)
  local line = M.insert(bufnr, tpl, lines, ctx)
  local ttype = tpl.type or "entry"
  if ttype == "entry" then
    line = first_headline_line(bufnr, line)
    if ctx.clock_start and tpl.clock_resume then
      local now = date.now():clone({ active = false })
      local start = ctx.clock_start:clone({ active = false })
      local mins = now:minutes() - start:minutes()
      edit.add_log_entry(bufnr, line, {
        string.format("CLOCK: %s--%s => %s", start:to_string(), now:to_string(), string.format("%2d:%02d", math.floor(mins / 60), mins % 60)),
      })
    elseif tpl.clock_in then
      local ok, clock = pcall(require, "org.clock")
      if ok and clock.clock_in then
        pcall(clock.clock_in, { bufnr = bufnr, lnum = line })
      end
    end
  end
  require("org.refile").remember(bufnr, line)
  run_hook(tpl.before_finalize, bufnr, line)
  if not tpl.no_save then
    save_if_hidden(bufnr)
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

--- Finish the capture in buffer `buf` (default: current).
---@param buf? integer
---@param opts? { refile?: boolean }
function M.finalize(buf, opts)
  opts = opts or {}
  buf = buf or vim.api.nvim_get_current_buf()
  local s = M.sessions[buf]
  if not s then
    utils.warn("Not a capture buffer")
    return
  end
  vim.cmd("stopinsert")
  run_hook(s.template.prepare_finalize, buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local dbuf, dline
  if opts.refile then
    local refile = require("org.refile")
    local dest = refile.pick_target({ prompt = "Refile capture to" })
    if not dest then
      return
    end
    close_session(buf)
    lines = trim_blank(lines)
    dbuf, dline = refile.insert_subtree(lines, dest)
    refile.remember(dbuf, dline)
    run_hook(s.template.before_finalize, dbuf, dline)
    save_if_hidden(dbuf)
    utils.notify("Captured and refiled to " .. dest.label:gsub("/$", ""))
  else
    close_session(buf)
    dbuf, dline = M.store(s.template, lines, s.ctx)
    if not dbuf then
      return
    end
    utils.notify("Captured to " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(dbuf), ":~"))
  end
  if s.template.jump_to_captured and dbuf then
    utils.open_file(vim.api.nvim_buf_get_name(dbuf), dline)
  end
  run_hook(s.template.after_finalize, dbuf, dline)
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
    if #items == 0 then
      utils.warn("No capture templates configured")
      return
    end
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
  local path = M.target_path(tpl)
  if not path then
    utils.warn("Capture target not found")
    return
  end
  local bufnr = utils.load_buffer(path)
  local parent, anchor = M.resolve_location(bufnr, tpl, { date = date.today() })
  vim.cmd("normal! m'")
  utils.open_file(path, anchor or parent or 1)
  return bufnr, anchor or parent or 1
end

--- Abort the capture.
function M.kill(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.sessions[buf] then
    return
  end
  vim.cmd("stopinsert")
  close_session(buf)
  utils.notify("Capture aborted")
end

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
    origin_buf = vim.api.nvim_get_current_buf(),
    origin_win = vim.api.nvim_get_current_win(),
  }
  M.sessions[buf] = session
  local win = ui.open_buffer_window(buf, (config.opts.capture or {}).window or "float", {
    title = "Capture: " .. (tpl.description or tpl.key or ""),
  })
  session.win = win
  vim.bo[buf].filetype = "org"
  vim.wo[win].winbar = hint()

  local maps = config.opts.mappings.capture or {}
  for _, lhs in ipairs(config.lhs_list(maps.finalize)) do
    vim.keymap.set({ "n" }, lhs, function()
      utils.run(M.finalize, buf)
    end, { buffer = buf, desc = "org: finalize capture" })
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
      utils.run(M.finalize, buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M.sessions[buf] = nil
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
---@param opts? { initial?: string, date?: table }
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
  if tpl.time_prompt and not ctx.date then
    ctx.date = pick_date("Capture date", false, date.today())
    if not ctx.date then
      return
    end
  end
  local target_path = M.target_path(tpl)
  if not target_path then
    local t = tpl.target or tpl.file
    local msg = t == "clock" and "No running clock to capture into" or ("Cannot find entry with ID " .. tostring(tpl.id))
    utils.warn(msg)
    return
  end
  ctx.target_file = files.get(target_path)
  local ttype = tpl.type or "entry"
  local text = tpl.template
  if type(text) == "function" then
    text = text(ctx)
  end
  if type(text) == "table" then
    text = table.concat(text, "\n")
  end
  text = text or DEFAULT_TEMPLATES[ttype] or "%?"
  local ok, expanded = pcall(M.expand, text, ctx)
  if not ok then
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
  if tpl.clock_in and tpl.clock_resume then
    ctx.clock_start = date.now()
  end
  if tpl.immediate_finish then
    local lines = vim.split(expanded:gsub(CURSOR, ""), "\n", { plain = true })
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
      utils.notify("Captured to " .. vim.fn.fnamemodify(target_path, ":~"))
      if tpl.jump_to_captured then
        utils.open_file(vim.api.nvim_buf_get_name(dbuf), dline)
      end
      run_hook(tpl.after_finalize, dbuf, dline)
    end
    return dbuf, dline
  end
  return open_buffer(tpl, expanded, ctx)
end

return M
