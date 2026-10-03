---@mod org.api.agenda Agenda queries of the public API
---
--- The entries the agenda views show, as plain data, without opening the
--- agenda. See |org-api-agenda|.

local H = require("org.api.headline")

local M = {}

---@class org.api.AgendaItem
---@field type string where it comes from: scheduled, deadline, timestamp, range, sexp, closed, clock, state, todo, tags, search
---@field kind string|nil the agenda's finer type (`past-scheduled`, `upcoming-deadline`, `tagsmatch`, ...)
---@field title string headline text without TODO keyword, priority and tags
---@field todo string|nil
---@field priority string|nil
---@field category string
---@field tags string[] the tags the agenda shows (inherited ones included)
---@field done boolean
---@field day string|nil `YYYY-MM-DD` of the day it's listed on (agenda spans)
---@field date org.api.Date|nil the timestamp it comes from
---@field time string|nil `HH:MM` start time
---@field end_time string|nil `HH:MM` end time
---@field extra string|nil the agenda's leader ("Scheduled: ", "In   3 d.: ", ...)
---@field file string|nil
---@field line integer
---@field headline org.api.Headline|nil (nil for diary entries without one)

---@class org.api.AgendaDay
---@field date string `YYYY-MM-DD`
---@field day org.api.Date
---@field items org.api.AgendaItem[]

local function hhmm(minutes)
  if not minutes then
    return nil
  end
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function day_string(n)
  return n and require("org.date").from_days(n):to_date_string() or nil
end

---@param it org.AgendaItem
---@return org.api.AgendaItem
local function item(it)
  return {
    type = it.type,
    kind = it.ts_type,
    title = it.title,
    todo = it.todo,
    priority = it.priority,
    category = it.category,
    tags = vim.deepcopy(it.tags or {}),
    done = it.done and true or false,
    day = day_string(it.day),
    date = it.date and H.date(it.date) or nil,
    time = hhmm(it.time),
    end_time = hhmm(it.end_time),
    extra = it.extra ~= "" and it.extra or nil,
    file = it.filename or (it.headline and it.headline.file.filename),
    line = it.lnum,
    headline = it.headline and H.new(it.headline) or nil,
  }
end

--- The parsed files a query reads: `paths` (globs and directories too), or
--- the agenda files.
---@param paths? string|string[]
---@return org.File[]
function M.files(paths)
  local files = require("org.files")
  if paths == nil then
    return files.agenda_files()
  end
  if type(paths) == "string" then
    paths = { paths }
  end
  local out = {}
  for _, p in ipairs(require("org.utils").glob_org_files(paths)) do
    local f = files.get(p)
    if f then
      out[#out + 1] = f
    end
  end
  return out
end

local function finish(list, kind)
  local items = require("org.agenda.items")
  local render = require("org.agenda.render")
  local sorting = render.sorting_for({}, kind)
  if kind == "todo" or kind == "tags" then
    local ts_kind = items.list_timestamp_kind(sorting) or false
    for _, it in ipairs(list) do
      items.set_list_timestamp(it, sorting, ts_kind)
    end
  end
  items.sort(list, sorting)
  return vim.tbl_map(item, list)
end

--- The agenda for a span of days (org-agenda-list), as days with items.
--- `opts.from` (any date the API accepts, default today) and `opts.span`
--- ("day", "week", "fortnight", "month", "year" or a number of days;
--- default `agenda.span`). A week or fortnight starts on
--- `agenda.start_on_weekday` unless `opts.align` is false.
---@param opts? { from?: any, span?: string|integer, align?: boolean, files?: string|string[], log?: boolean, include_empty?: boolean }
---@return org.api.AgendaDay[]|nil days, string|nil err
function M.agenda(opts)
  opts = opts or {}
  local date = require("org.date")
  local config = require("org.config")
  local anchor = date.today_days()
  if opts.from ~= nil then
    local d, err = H.to_date(opts.from)
    if not d then
      return nil, err
    end
    anchor = d:days()
  end
  local span = opts.span or config.opts.agenda.span or "week"
  local render = require("org.agenda.render")
  if not render.span_days(span, anchor) then
    return nil, "invalid span: " .. tostring(span)
  end
  local from, to = render.range(span, anchor, opts.align ~= false)
  local by_day = require("org.agenda.items").agenda(M.files(opts.files), from, to, {
    today = date.today_days(),
    log_mode = opts.log or nil,
  })
  local out = {}
  for d = from, to do
    local list = by_day[d] or {}
    if #list > 0 or opts.include_empty ~= false then
      local day = date.from_days(d)
      out[#out + 1] = { date = day:to_date_string(), day = H.date(day), items = finish(list, "agenda") }
    end
  end
  return out
end

--- The global TODO list (org-todo-list): entries with a not-done keyword,
--- or with one of `opts.keywords` ("*": any keyword).
---@param opts? { keywords?: string|string[], files?: string|string[] }
---@return org.api.AgendaItem[]
function M.todo(opts)
  opts = opts or {}
  local kws = opts.keywords
  if type(kws) == "string" then
    kws = vim.split(kws, "[|%s]+", { trimempty = true })
  end
  return finish(require("org.agenda.items").todo(M.files(opts.files), kws, {}), "todo")
end

--- Entries matching a tags/property match string (org-tags-view), e.g.
--- `+work-urgent`, `PRIORITY="A"`, `+project/!TODO|NEXT`. `opts.todo_only`
--- keeps entries with a not-done keyword (C-u, `tags_todo`).
---@param match string
---@param opts? { todo_only?: boolean, files?: string|string[] }
---@return org.api.AgendaItem[]|nil items, string|nil err
function M.tags(match, opts)
  opts = opts or {}
  local pred, err = require("org.agenda.search").try_compile(match or "")
  if not pred then
    return nil, err
  end
  return finish(require("org.agenda.items").tags(M.files(opts.files), pred, opts.todo_only, {}), "tags")
end

--- Entries matching a search view query (org-search-view): words,
--- `+word`, `-word`, `"a phrase"`, `{regexp}`; a leading `*` searches
--- headlines only.
---@param query string
---@param opts? { todo_only?: boolean, files?: string|string[] }
---@return org.api.AgendaItem[]|nil items, string|nil err
function M.search(query, opts)
  opts = opts or {}
  local ok, pred = pcall(require("org.agenda.search").compile_text, (opts.todo_only and "!" or "") .. (query or ""))
  if not ok then
    return nil, tostring(pred)
  end
  return finish(require("org.agenda.items").search(M.files(opts.files), pred, {}), "search")
end

return M
