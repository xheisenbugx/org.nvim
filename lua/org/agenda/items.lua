---@mod org.agenda.items Collecting agenda entries from org files
---
--- A port of the entry finders of org-agenda.el
--- (`org-agenda-get-deadlines`, `-scheduled`, `-timestamps`, `-blocks`,
--- `-sexps`, `-progress`, `-todos`, `org-scan-tags`, the search view and
--- `org-agenda-list-stuck-projects`) and of the sorting
--- (`org-entries-lessp`). Items carry the text properties Emacs sorts on:
--- time of day, urgency, priority, category, habit, ts-date and type.
---
--- This file holds the item fields, building items and iterating over
--- the headlines of the agenda files; the rest loads from
--- org/agenda/items/: times (times of day in entries), repeats
--- (org-closest-date), ranges (date ranges as org-tr-regexp reads them),
--- sexps (diary sexps), planning (deadlines and scheduled entries),
--- timestamps (plain, range and inactive timestamps), log (log mode),
--- day (the day agenda, `M.agenda`), lists (the TODO, tags, search and
--- stuck project lists) and sort (org-entries-lessp).

-- Not compiled by the JIT: building an agenda over many files ran 3 to 5
-- times faster interpreted. Its loops are short (an entry's dates, its
-- tags) and branch a lot, so most traces aborted ("leaving loop", closures)
-- and the many that were compiled filled the machine-code area, which
-- flushed every compiled trace in Neovim over and over ("failed to allocate
-- mcode memory", on macOS arm64). See "Performance budgets" in
-- CONTRIBUTING.md.
if jit then
  jit.off(true, true)
end

local config = require("org.config")
local date = require("org.date")

local M = {}

-- The parts in org/agenda/items/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.agenda.items"] = M

-- sexps already reported as bad (org agenda warns once per session)
M._warned_sexps = {}
-- results of the sexps evaluated in Emacs, by sexp, entry and day range
M._emacs_sexps = {}

--- Extra entries of agenda day views, not from org files (used by
--- extensions, e.g. calendar subscriptions): name -> `fun(from, to, opts)`
--- returning agenda items, each with `day` set. They are added after the
--- files and the diary like diary lines, in name order; an item without a
--- `filename` can't be visited or edited. Empty by default.
---@type table<string, fun(from: integer, to: integer, opts: table): org.AgendaItem[]>
M.day_sources = {}

---@class org.AgendaItem
---@field type string scheduled|deadline|timestamp|range|sexp|closed|clock|state|todo|tags|search|stuck
---@field headline org.Headline
---@field filename string|nil
---@field bufnr integer|nil
---@field lnum integer
---@field level integer outline level, odd levels reduced (0 outside an entry)
---@field fidx? integer index of the file (or diary, extra day source) it comes from, in a day agenda
---@field raw string
---@field title string headline text without TODO keyword, priority and tags
---@field display_title string|nil title as displayed (times/timestamps removed)
---@field todo string|nil
---@field priority string|nil
---@field category string
---@field tags string[]
---@field done boolean
---@field day integer|nil day the item is displayed on
---@field date table|nil the timestamp the item comes from
---@field time integer|nil minutes since midnight (time-of-day)
---@field sort_time? integer the time it sorts by, when not `time` (the first time in its DOTIME)
---@field end_time integer|nil
---@field extra string|nil leader ("Scheduled: ", "In   3 d.: ", ...)
---@field face string|nil highlight group for the text
---@field undone_face? string the face when not done
---@field fixface? boolean the face follows the TODO state (done or not)
---@field habit? table the parsed habit of a scheduled habit (org.agenda.habits.parse)
---@field urgency number Emacs 'urgency
---@field prio number Emacs 'priority (org-get-priority)
---@field ts_date integer|nil day number used by the ts-*/timestamp-* sorting
---@field ts_type string|nil Emacs 'type ("scheduled", "past-scheduled", "deadline", ...)
---@field ts_index integer|nil index in `headline.timestamps` of a plain timestamp item
---@field block_range? boolean a date range that is no timestamp object (`headline.block_ranges`)
---@field planning_kind "scheduled"|"deadline"|nil a block item from the date range of that planning keyword
---@field order integer insertion order (category-keep)

local order = 0

--- Emacs `org-get-priority`: 1000 * (lowest - priority).
local function pvalue(p)
  return tonumber(p) or (p and p:byte()) or 0
end

local function priority_value(hl)
  if type(config.opts.priority_get_priority_function) == "function" then
    return require("org.priority").get_priority(hl)
  end
  local pr = hl.file:priorities()
  local p = hl.priority or pr.default
  return 1000 * (pvalue(pr.lowest) - pvalue(p))
end
M.priority_value = priority_value

--- The face of a deadline line (org-agenda-deadline-face): the first of
--- `agenda.deadline_faces` ({ fraction, group } pairs) whose fraction is at
--- most `fraction`, the part of the warning period that has passed (1 on
--- the day, more when overdue).
---@param fraction number
---@return string?
function M.deadline_face(fraction)
  for _, f in ipairs(config.opts.agenda.deadline_faces or {}) do
    if f[1] <= fraction then
      return f[2]
    end
  end
  return nil
end

--- The title an agenda line shows for `hl`. A headline that is only tags
--- ("* :work:") shows them as its title too: Emacs takes the text of the
--- headline and removes the tags only after a blank (org-tag-group-re in
--- org-agenda-fix-displayed-tags), and there is none before them.
local function agenda_title(hl)
  local title = hl.title
  if title == "" and not hl.todo and not hl.priority and hl.raw then
    local tags = hl.raw:match("^%*+ +(:[%w_@#%%:\128-\255]+:)[ \t]*$")
    if tags then
      return tags
    end
  end
  return title
end

local function new_item(hl, fields)
  order = order + 1
  local item = {
    headline = hl,
    filename = hl.file.filename,
    bufnr = hl.file.bufnr,
    lnum = hl.line,
    raw = hl.raw,
    title = agenda_title(hl),
    todo = hl.todo,
    priority = hl.priority,
    category = hl:get_category(),
    tags = hl:get_tags(),
    done = hl:is_done(),
    level = hl:reduced_level(),
    order = order,
    prio = priority_value(hl),
  }
  for k, v in pairs(fields or {}) do
    item[k] = v
  end
  if item.urgency == nil then
    item.urgency = item.prio
  end
  return item
end
M.new_item = new_item

--- An item for line `lnum` of `file` outside any entry (a %%(sexp) line
--- before the first heading): no headline, the file's category and tags.
local function file_item(file, lnum, fields)
  order = order + 1
  local pr = file:priorities()
  local inherit = config.opts.use_tag_inheritance ~= false
  local item = {
    filename = file.filename,
    bufnr = file.bufnr,
    lnum = lnum,
    raw = file.lines[lnum],
    title = "",
    category = (file.properties or {}).CATEGORY or file:category(),
    tags = inherit and vim.deepcopy(file.settings.filetags or {}) or {},
    done = false,
    level = 0,
    order = order,
    prio = 1000 * (pvalue(pr.lowest) - pvalue(pr.default)),
  }
  for k, v in pairs(fields or {}) do
    item[k] = v
  end
  if item.urgency == nil then
    item.urgency = item.prio
  end
  return item
end
M.file_item = file_item

local function acfg_for(opts)
  return vim.tbl_extend("force", config.opts.agenda, (opts or {}).block or {})
end

--- Integer value of an option that may be a number (else nil).
local function int(v)
  return type(v) == "number" and v or nil
end

--- org-get-wdays for a deadline: a `deadline_warning_days` of 0 or less is
--- enforced as its absolute value, over any -Nd cookie; else the cookie,
--- else the option.
local function deadline_wdays(ts, tv)
  return date.deadline_warning_days(ts, tv)
end

---------------------------------------------------------------------------
-- Headline iteration
---------------------------------------------------------------------------

--- Is `hl` inside a COMMENT subtree (with agenda.skip_comment_trees,
--- org-agenda-skip-comment-trees), or an ARCHIVE-tagged one (unless
--- archived trees are included, org-agenda-archives-mode)?
-- a plain scan: vim.tbl_contains validates its arguments on every call,
-- and building a set per headline costs more than the few tags it holds
local function has_archive_tag(tags)
  for i = 1, #tags do
    if tags[i] == "ARCHIVE" then
      return true
    end
  end
  return false
end

local function hidden(hl, include_archived, memo)
  local v = memo[hl]
  if v == nil then
    local skip_comments = config.opts.agenda.skip_comment_trees ~= false
    v = (skip_comments and hl.commented) or (not include_archived and has_archive_tag(hl.tags))
    v = v or false
    if not v and hl.parent then
      v = hidden(hl.parent, include_archived, memo)
    end
    memo[hl] = v
  end
  return v
end

--- Skip predicates that skip the whole subtree of an entry they hold for
--- (org-agenda-skip-subtree-if), set by `org.agenda.skip_subtree_if`.
---@type table<function, boolean>
M.subtree_skips = setmetatable({}, { __mode = "k" })

--- Iterate visible headlines of `files` (skipping ARCHIVE/COMMENT
--- subtrees unless `all` is set, and those `agenda.skip_function_global`
--- or `opts.skip` skip, org-agenda-skip).
---
--- Like Emacs, which calls the skip function only at the entries a view
--- matches, a subtree skip (`M.subtree_skips`) is asked about the
--- headlines `opts.candidate` accepts (every headline without it), and
--- when it holds the headlines below are left out too.
---@param files org.File[]
---@param opts? { restrict?: { filename?: string, range?: integer[] }, skip?: (fun(hl): boolean), archives?: string|boolean, all?: boolean, candidate?: fun(hl): any }
function M.each_headline(files, opts, fn)
  opts = opts or {}
  local r = opts.restrict
  -- whether each headline is hidden, so that a subtree's ancestors are
  -- checked once rather than for every headline in it
  local memo = {}
  local skips = {}
  local global = config.opts.agenda.skip_function_global
  if type(global) == "function" then
    skips[#skips + 1] = { fn = global, subtree = M.subtree_skips[global] }
  end
  if opts.skip then
    skips[#skips + 1] = { fn = opts.skip, subtree = M.subtree_skips[opts.skip] }
  end
  local function skipped(s, hl)
    if s.subtree then
      local below = s.below
      if below and below.file == hl.file and hl.line <= below.end_line then
        return true
      end
      s.below = nil
      if opts.candidate and not opts.candidate(hl) then
        return false
      end
    end
    local s_ok, skip = pcall(s.fn, hl)
    if s_ok and skip then
      if s.subtree then
        s.below = hl
      end
      return true
    end
    return false
  end
  for fidx, file in ipairs(files) do
    for _, hl in ipairs(file.headlines) do
      local ok = opts.all or not hidden(hl, opts.archives, memo)
      if ok and r and r.range then
        ok = hl.line >= r.range[1] and hl.line <= r.range[2]
      end
      for i = 1, #skips do
        if not ok then
          break
        end
        ok = not skipped(skips[i], hl)
      end
      if ok then
        fn(hl, file, fidx)
      end
    end
  end
end

--- `opts` with `candidate` set: the entries a subtree skip is asked about.
local function with_candidate(opts, candidate)
  return vim.tbl_extend("force", opts, { candidate = candidate })
end
-- Local functions the parts below share
local shared = require("org.agenda.items.shared")
shared.acfg_for = acfg_for
shared.deadline_wdays = deadline_wdays
shared.file_item = file_item
shared.int = int
shared.new_item = new_item
shared.with_candidate = with_candidate
--- The next insertion order (`order` of an item).
function shared.next_order()
  order = order + 1
  return order
end

require("org.agenda.items.times")
require("org.agenda.items.repeats")
require("org.agenda.items.ranges")
require("org.agenda.items.sexps")
require("org.agenda.items.planning")
require("org.agenda.items.timestamps")
require("org.agenda.items.log")
require("org.agenda.items.day")
require("org.agenda.items.lists")
require("org.agenda.items.sort")

return M
