---@mod org.extensions.cli.read The read commands: agenda, search, headlines, show
---
--- `org agenda` (a view as text, CSV or items), `org search`, `org
--- headlines` with its filters and `org show`. Part of
--- org.extensions.cli.run, which loads it.

local data = require("org.extensions.cli.data")

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state
local arg_path = M.arg_path
local headline_line = M.headline_line
local int_flag = M.int_flag
local files_named = M.files_named

local SPANS = { day = "day", week = "week", fortnight = 14, month = "month", year = "year" }

--- The agenda view state after opening the view described by `words`.
local function open_agenda(words, flags)
  local agenda = require("org.agenda")
  local config = require("org.config")
  local what = words[1] or "agenda"
  local anchor
  if flags.date then
    local d = require("org.date").read_date(flags.date, require("org.date").today())
    if not d then
      fail("cannot read date " .. flags.date, "bad_value", { date = flags.date })
    end
    ---@cast d -nil
    anchor = d:days()
  end
  local span
  if flags.span then
    local n = tonumber(flags.span)
    if n and n >= 1 and n == math.floor(n) then
      span = n
    elseif SPANS[flags.span] then
      span = SPANS[flags.span]
    else
      fail(
        "--span needs a positive whole number or day, week, fortnight, month or year, not " .. flags.span,
        "bad_value",
        { span = flags.span }
      )
    end
  end
  ---@type string, string|vim.NIL
  local label, key = what, vim.NIL
  local custom = not (what == "todo" or what == "tags" or what == "tags-todo")
    and type((config.opts.agenda.custom_commands or {})[what]) == "table"
  if words[2] ~= nil and (what == "agenda" or SPANS[what] or custom) then
    fail(string.format("agenda %s takes no other argument, not %s", what, words[2]), "usage", { view = what })
  end
  if what == "agenda" or SPANS[what] then
    span = span or SPANS[what]
    agenda.open({ type = "agenda" }, { span = span, anchor = anchor })
    label = "agenda"
  elseif what == "todo" then
    agenda.open({ type = "todo", keywords = words[2] })
  elseif what == "tags" or what == "tags-todo" then
    if not words[2] then
      fail("agenda " .. what .. " needs a match, e.g. org agenda tags +work", "usage")
    end
    local ok, e = require("org.agenda.search").try_compile(words[2])
    if not ok then
      fail("bad match " .. words[2] .. ": " .. tostring(e), "bad_value", { match = words[2] })
    end
    agenda.open({ type = what == "tags" and "tags" or "tags_todo", match = words[2] })
  elseif custom then
    if span then
      config.opts.agenda.span = span
    end
    agenda.open_custom(what)
    label, key = "custom", what
  else
    fail(
      "unknown agenda view " .. what .. " (day, week, month, todo, tags or a custom command key)",
      "usage",
      { view = what }
    )
  end
  local S = require("org.agenda.view").state
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    fail("no agenda was built (are agenda_files set? see --files)", "failed")
  end
  return S, label, key
end

--- JSON data of the items of the agenda view `S`.
function M.agenda_items(S)
  local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
  local items = {}
  local day
  for l, line in ipairs(lines) do
    if S.day_lines and S.day_lines[l] then
      day = S.day_lines[l]
    end
    local it = S.line_items[l]
    if it then
      local hl = it.headline
      local d = it.day or (type(it.date) == "table" and it.date.days and it.date:days()) or (hl and day) or nil
      local extra = it.extra and vim.trim(it.extra) ~= "" and vim.trim(it.extra) or nil
      items[#items + 1] = {
        date = data.iso_day(d),
        time = data.hm(it.time),
        end_time = data.hm(it.end_time),
        type = data.nn(it.ts_type or it.type),
        todo = data.nn(it.todo),
        priority = data.nn(it.priority),
        title = hl and hl:plain_title() or it.title or "",
        tags = it.tags or {},
        category = data.nn(it.category),
        file = data.path(it.filename),
        line = data.nn(it.lnum),
        id = hl and data.nn(hl.properties.ID) or vim.NIL,
        level = data.nn(it.level),
        timestamp = data.timestamp(it.date),
        extra = data.nn(extra),
        done = it.done or false,
        text = vim.trim(line),
      }
    end
  end
  return items
end

local function agenda_result(words, flags)
  local S, label, key = open_agenda(words, flags)
  if flags.csv then
    if state.machine then
      fail("--csv and --json/--jsonl exclude each other", "usage")
    end
    return { text = require("org.agenda.export").csv_lines() }
  end
  if state.machine then
    local first, last
    for _, d in pairs(S.day_lines or {}) do
      first = math.min(first or d, d)
      last = math.max(last or d, d)
    end
    local items = M.agenda_items(S)
    return {
      data = { view = label, key = key, start = data.iso_day(first), ["end"] = data.iso_day(last), items = items },
      stream = items,
    }
  end
  local text = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    text[#text + 1] = (l:gsub("%s+$", ""))
  end
  return { text = text }
end

function M.cmd_agenda(words, flags)
  if state.session then
    -- leave the agendas open in the session as they are
    return require("org.agenda.view").offscreen(function()
      return agenda_result(words, flags)
    end)
  end
  return agenda_result(words, flags)
end

---------------------------------------------------------------------------
-- search, headlines, show
---------------------------------------------------------------------------

local function headline_result(hls, limit)
  if limit and #hls > limit then
    hls = vim.list_slice(hls, 1, limit)
  end
  local list = vim.tbl_map(data.headline, hls)
  local text = vim.tbl_map(headline_line, hls)
  return { data = list, text = text, code = #hls > 0 and 0 or 1 }
end

local function match_predicate(match)
  -- strict: text the match can't read is an error, not ignored as Emacs
  -- (and the agenda) ignore it
  local pred, e = require("org.agenda.search").try_compile(match, { strict = true })
  if not pred then
    fail("bad match " .. match .. ": " .. tostring(e), "bad_value", { match = match })
  end
  ---@cast pred -nil
  return pred
end

function M.cmd_search(words, flags)
  local query = table.concat(words, " ")
  local limit = int_flag(flags, "limit")
  local hls = {}
  if flags.match then
    local pred = match_predicate(flags.match)
    require("org.agenda.items").each_headline(require("org.files").agenda_files(), {}, function(hl)
      if pred(hl) and (query == "" or hl:plain_title():lower():find(query:lower(), 1, true)) then
        hls[#hls + 1] = hl
      end
    end)
    return headline_result(hls, limit)
  end
  if query == "" then
    fail("search needs a query (or --match MATCH)", "usage")
  end
  if require("org.extensions").enabled("ql") then
    local ok, res = pcall(require("org.extensions.ql").select, "agenda", query)
    if not ok then
      fail("bad query: " .. tostring(res), "bad_value", { query = query })
    end
    hls = res
  else
    require("org.agenda").open({ type = "search", match = query })
    local S = require("org.agenda.view").state
    local seen = {}
    local lnums = vim.tbl_keys(S.line_items or {})
    table.sort(lnums)
    for _, l in ipairs(lnums) do
      local hl = S.line_items[l].headline
      if hl and not seen[hl] then
        seen[hl] = true
        hls[#hls + 1] = hl
      end
    end
  end
  return headline_result(hls, limit)
end

--- A `FROM..TO` day range (either side optional; a single date is that
--- day), `any` or `none`, as a predicate on a timestamp (or nil).
local function date_range(spec, flag)
  local date = require("org.date")
  if spec == "any" then
    return function(ts)
      return ts ~= nil
    end
  elseif spec == "none" then
    return function(ts)
      return ts == nil
    end
  end
  local a, b = spec:match("^(.-)%.%.(.-)$")
  if not a then
    a, b = spec, spec
  end
  local function day(s)
    s = vim.trim(s)
    if s == "" then
      return nil
    end
    local d = date.read_date(s, date.today())
    if not d then
      fail(string.format("%s: cannot read date %s", flag, s), "bad_value", { date = s })
    end
    ---@cast d -nil
    return d:days()
  end
  local from, to = day(a), day(b)
  return function(ts)
    if not ts then
      return false
    end
    local n = ts:days()
    return (not from or n >= from) and (not to or n <= to)
  end
end

local function level_range(spec)
  local a, b = spec:match("^(%d*)%.%.(%d*)$")
  if not a then
    a = spec:match("^(%d+)$")
    b = a
  end
  if not a then
    fail("--level needs N or FROM..TO, not " .. spec, "bad_value")
  end
  local from, to = tonumber(a), tonumber(b)
  return function(n)
    return (not from or n >= from) and (not to or n <= to)
  end
end

--- A predicate on headlines from the filters of `org headlines`.
function M.headline_filter(flags)
  local preds = {}
  if #flags.todo > 0 then
    local want = flags.todo
    preds[#preds + 1] = function(hl)
      for _, w in ipairs(want) do
        if
          (w == "any" and hl.todo)
          or (w == "open" and hl:is_todo())
          or (w == "done" and hl:is_done())
          or (w == "none" and not hl.todo)
          or hl.todo == w
        then
          return true
        end
      end
      return false
    end
  end
  for _, t in ipairs(flags.tag) do
    preds[#preds + 1] = function(hl)
      return vim.tbl_contains(hl:get_tags(), t)
    end
  end
  for _, p in ipairs(flags.property) do
    local name, value = p:match("^([^=]+)=(.*)$")
    name = (name or p):upper()
    preds[#preds + 1] = function(hl)
      -- inherited per use_property_inheritance, like a property match
      local v = hl:get_property(name)
      if value then
        return v == value
      end
      return v ~= nil
    end
  end
  if flags.level then
    local ok = level_range(flags.level)
    preds[#preds + 1] = function(hl)
      return ok(hl.level)
    end
  end
  for _, kind in ipairs({ "scheduled", "deadline" }) do
    if flags[kind] then
      local ok = date_range(flags[kind], "--" .. kind)
      preds[#preds + 1] = function(hl)
        return ok(hl.planning[kind])
      end
    end
  end
  if flags.match then
    preds[#preds + 1] = match_predicate(flags.match)
  end
  return function(hl)
    for _, p in ipairs(preds) do
      if not p(hl) then
        return false
      end
    end
    return true
  end
end

function M.cmd_headlines(words, flags)
  local files
  if #words > 0 then
    files = {}
    for _, w in ipairs(words) do
      local p = arg_path(w)
      local f = vim.fn.filereadable(p) == 1 and require("org.files").get(p) or nil
      if not f then
        fail("no such file: " .. p, "bad_value", { file = p })
      end
      files[#files + 1] = f
    end
  else
    files = require("org.files").agenda_files()
  end
  if #flags.file > 0 then
    local sel, seen = {}, {}
    for _, name in ipairs(flags.file) do
      local named = files_named(name, files)
      if #named == 0 then
        fail("no agenda file " .. name, "bad_value", { file = name })
      end
      for _, f in ipairs(named) do
        if not seen[f] then
          seen[f] = true
          sel[#sel + 1] = f
        end
      end
    end
    files = sel
  end
  -- a --todo that is no keyword of these files (nor any, open, done,
  -- none) would just find nothing
  local known = { any = true, open = true, done = true, none = true }
  for _, n in ipairs(require("org.todo_keywords").global():names()) do
    known[n] = true
  end
  for _, f in ipairs(files) do
    for _, n in ipairs(f.settings.todo:names()) do
      known[n] = true
    end
  end
  for _, kw in ipairs(flags.todo) do
    if not known[kw] then
      local names = vim.tbl_keys(known)
      table.sort(names)
      fail(
        "unknown TODO keyword " .. kw .. " (any, open, done, none or a keyword of the files)",
        "bad_value",
        { keyword = kw, keywords = names }
      )
    end
  end
  local pred = M.headline_filter(flags)
  local hls = {}
  require("org.agenda.items").each_headline(files, { all = flags.archived or false }, function(hl)
    if pred(hl) then
      hls[#hls + 1] = hl
    end
  end)
  return headline_result(hls, int_flag(flags, "limit"))
end

--- The text of `org show` for headline `hl` (its data `entry`) and, with
--- --children, its child entries after it.
local function entry_text(hl, entry, text)
  text[#text + 1] = headline_line(hl)
  local function ts(label, t)
    if t then
      text[#text + 1] = label .. t:to_string()
    end
  end
  ts("  SCHEDULED: ", hl.planning.scheduled)
  ts("  DEADLINE: ", hl.planning.deadline)
  ts("  CLOSED: ", hl.planning.closed)
  local keys = vim.tbl_keys(hl.properties)
  table.sort(keys)
  for _, k in ipairs(keys) do
    text[#text + 1] = "  :" .. k .. ": " .. hl.properties[k]
  end
  if entry.clock.count > 0 then
    text[#text + 1] = "  clocked: " .. entry.clock.total .. " (" .. entry.clock.count .. " clocks)"
  end
  if entry.body ~= "" then
    text[#text + 1] = ""
    vim.list_extend(text, vim.split(entry.body, "\n", { plain = true }))
  end
  if type(entry.children) == "table" then
    for i, child in ipairs(hl.children or {}) do
      text[#text + 1] = ""
      entry_text(child, entry.children[i], text)
    end
  end
  return text
end

function M.cmd_show(words, flags)
  local hl = M.resolve_target(table.concat(words, " "), flags)
  local entry = data.entry(hl, { children = flags.children })
  return { data = entry, text = entry_text(hl, entry, {}) }
end
