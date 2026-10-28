---@mod org.agenda.items.lists The TODO, tags, search and stuck project lists
---
--- The entries of the list views: the global TODO list (org-todo-list,
--- with the org-agenda-todo-ignore-* options), tags and property matches
--- (org-scan-tags), the search view and stuck projects
--- (org-agenda-list-stuck-projects). Part of org.agenda.items, which
--- loads it.

-- Not compiled by the JIT, like org.agenda.items (see the comment there).
if jit then
  jit.off(true, true)
end

local config = require("org.config")
local date = require("org.date")
local shared = require("org.agenda.items.shared")

local M = require("org.agenda.items")

local acfg_for = shared.acfg_for
local deadline_wdays = shared.deadline_wdays
local int = shared.int
local new_item = shared.new_item
local with_candidate = shared.with_candidate

--- org-agenda-todo-custom-ignore-p: is the timestamp at least `n` days
--- away (n >= 0), or at most `n` days (n < 0)?
local function custom_ignore(days, n)
  if n >= 0 then
    return days >= n
  end
  return days <= n
end

--- org-agenda-check-for-timestamp-as-reason-to-ignore-todo-item
local function ignored_by_date(hl, acfg, today)
  local s, dl = hl.planning.scheduled, hl.planning.deadline
  -- org-timestamp-to-now: days, or seconds with
  -- org-agenda-todo-ignore-time-comparison-use-seconds
  local seconds = acfg.todo_ignore_time_comparison_use_seconds
  local now = os.time()
  local function to_now(d)
    if seconds then
      return d:to_time() - now
    end
    return d:days() - today
  end
  local iw = acfg.todo_ignore_with_date
  if iw then
    if (s and s.active) or (dl and dl.active) or #hl.timestamps > 0 then
      return true
    end
  end
  local is = acfg.todo_ignore_scheduled
  -- org-scheduled-time-regexp and org-deadline-time-regexp only match
  -- active timestamps
  if is and s and s.active then
    local diff = to_now(s)
    if is == "future" then
      if diff > 0 then
        return true
      end
    elseif is == "past" then
      if diff <= 0 then
        return true
      end
    elseif int(is) then
      if custom_ignore(diff, is) then
        return true
      end
    else
      return true
    end
  end
  local id = acfg.todo_ignore_deadlines
  if id and dl and dl.active then
    local diff = to_now(dl)
    local wdays = acfg.deadline_warning_days or config.opts.deadline_warning_days
    -- org-deadline-close-p always compares days
    local close = dl:days() - today <= deadline_wdays(dl, wdays) and not hl:is_done()
    if id == "all" then
      return true
    elseif id == "far" then
      if not close then
        return true
      end
    elseif id == "future" then
      if diff > 0 then
        return true
      end
    elseif id == "past" then
      if diff <= 0 then
        return true
      end
    elseif int(id) then
      if custom_ignore(diff, id) then
        return true
      end
    elseif close then
      -- t and "near"
      return true
    end
  end
  local it = acfg.todo_ignore_timestamp
  if it and hl.timestamps[1] then
    local diff = to_now(hl.timestamps[1].date)
    if it == "future" then
      return diff > 0
    elseif it == "past" then
      return diff <= 0
    elseif int(it) then
      return custom_ignore(diff, it)
    end
    return true
  end
  return false
end
M.ignored_by_date = ignored_by_date

--- Global TODO list (org-todo-list).
---@param keywords? string[] restrict to these keywords (nil = all not-done; "*" = any keyword)
function M.todo(files, keywords, opts)
  opts = opts or {}
  local acfg = acfg_for(opts)
  local today = date.today_days()
  local set, any
  if keywords and #keywords > 0 then
    set = {}
    for _, k in ipairs(keywords) do
      if k == "*" then
        any = true
      end
      set[k] = true
    end
  end
  local out = {}
  local skip_below
  -- the entries org-agenda-get-todos matches
  local function matches(hl)
    if not hl.todo then
      return false
    end
    if set and not any then
      return set[hl.todo] == true
    end
    return set ~= nil or hl:is_todo()
  end
  M.each_headline(files, with_candidate(opts, matches), function(hl)
    if skip_below and hl.file == skip_below.file and hl.line <= skip_below.end_line then
      return
    end
    skip_below = nil
    if not matches(hl) then
      return
    end
    if ignored_by_date(hl, acfg, today) then
      -- org-agenda-get-todos skips the subtree of an ignored entry too
      if acfg.todo_list_sublevels == false then
        skip_below = hl
      end
      return
    end
    local item =
      new_item(hl, { type = "todo", ts_type = "todo", face = hl:is_done() and "OrgAgendaDone" or nil, fixface = true })
    item.urgency = item.prio + 1
    out[#out + 1] = item
    if acfg.todo_list_sublevels == false then
      skip_below = hl
    end
  end)
  return out
end

--- Tags / property match (org-tags-view, org-scan-tags).
function M.tags(files, predicate, todo_only, opts)
  opts = opts or {}
  local acfg = acfg_for(opts)
  local today = date.today_days()
  local out = {}
  local skip_below
  local function matches(hl)
    return (not todo_only or hl:is_todo()) and predicate(hl)
  end
  M.each_headline(files, with_candidate(opts, matches), function(hl)
    if skip_below and hl.file == skip_below.file and hl.line <= skip_below.end_line then
      return
    end
    skip_below = nil
    if todo_only and not hl:is_todo() then
      return
    end
    if todo_only and acfg.tags_todo_honor_ignore_options and ignored_by_date(hl, acfg, today) then
      return
    end
    if predicate(hl) then
      out[#out + 1] = new_item(
        hl,
        { type = "tags", ts_type = "tagsmatch", face = hl:is_done() and "OrgAgendaDone" or nil, fixface = true }
      )
      if acfg.tags_match_list_sublevels == false then
        skip_below = hl
      end
    end
  end)
  return out
end

--- Text search (org-search-view).
function M.search(files, predicate, opts)
  local out = {}
  M.each_headline(files, with_candidate(opts or {}, predicate), function(hl)
    if predicate(hl) then
      out[#out + 1] = new_item(hl, {
        type = "search",
        ts_type = "search",
        face = hl:is_done() and "OrgAgendaDone" or nil,
        fixface = true,
        urgency = 1000,
        prio = 1000,
      })
    end
  end)
  return out
end

--- Stuck projects (org-agenda-list-stuck-projects). A project matching
--- `match` is not stuck when a heading of its subtree (the project heading
--- included) has one of `todo_keywords` ("*" = any not-done keyword) or
--- one of `tags` ("*" = any tag), or when its subtree text matches `text`.
function M.stuck(files, opts)
  opts = opts or {}
  local sp = vim.tbl_extend("force", config.opts.agenda.stuck_projects or {}, (opts.block or {}).stuck_projects or {})
  local pred = require("org.agenda.search").compile(sp.match or "+LEVEL=2/-DONE")
  -- the keywords are text, as in Emacs's regexp on the heading lines: a
  -- word that isn't a keyword in that file counts too; "*" stands for
  -- every not-done keyword of the agenda files (org-todo-keywords-for-agenda
  -- less org-done-keywords-for-agenda)
  local kws, tags = {}, {}
  local any_tag = false
  for _, k in ipairs(sp.todo_keywords or {}) do
    if k == "*" then
      local done = {}
      for _, f in ipairs(files) do
        local todo = f.settings and f.settings.todo
        for _, name in ipairs(todo and todo:names() or {}) do
          if todo:is_done(name) then
            done[name] = true
          else
            kws[name] = true
          end
        end
      end
      for name in pairs(done) do
        kws[name] = nil
      end
    else
      kws[k] = true
    end
  end
  for _, t in ipairs(sp.tags or {}) do
    if t == "*" then
      any_tag = true
    end
    tags[t] = true
  end
  local text_re = sp.text and sp.text ~= "" and vim.regex(sp.text) or nil
  if not (sp.todo_keywords and #sp.todo_keywords > 0) and not next(tags) and not text_re then
    error("Missing information to identify unstuck projects")
  end
  local function unstuck(h)
    local word = h.file.lines[h.line]:match("^%*+[ \t]+([^ \t]+)")
    if word and kws[word] then
      return true
    end
    for _, t in ipairs(h.tags) do
      if tags[t] or any_tag then
        return true
      end
    end
    return false
  end
  -- every heading of the subtree, inline tasks included, the project too
  local function subtree_active(hl)
    local hls = hl.file.headlines
    for i = hl.index, #hls do
      local h = hls[i]
      if h.line > hl.end_line then
        break
      end
      if unstuck(h) then
        return true
      end
    end
    return false
  end
  local out = {}
  M.each_headline(files, with_candidate(opts, pred), function(hl)
    if not pred(hl) then
      return
    end
    local active = subtree_active(hl)
    if not active and text_re then
      for i = hl.line, hl.end_line do
        if text_re:match_str(hl.file.lines[i]) then
          active = true
          break
        end
      end
    end
    if not active then
      out[#out + 1] = new_item(hl, { type = "stuck", ts_type = "tagsmatch" })
    end
  end)
  return out
end
