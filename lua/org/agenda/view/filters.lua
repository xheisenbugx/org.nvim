---@mod org.agenda.view.filters Agenda filters (org-agenda-filter and friends)
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local all_categories_in_view = shared.all_categories_in_view
local all_tags_in_view = shared.all_tags_in_view
local filter_tag_names = shared.filter_tag_names
local item_key = shared.item_key
local item_txt = shared.item_txt
local join = shared.join

---------------------------------------------------------------------------
-- Filters (org-agenda-filter and friends)
---------------------------------------------------------------------------

--- Set the effort filter from "<1:00", ">30", "=0:15", "-<1:00" ("" clears).
function M.set_effort_filter(input)
  input = vim.trim(input or "")
  if input == "" then
    M.state.filters.effort = {}
  else
    local neg, op, v = input:match("^([%+%-]?)([<>=]?)%s*(.+)$")
    local minutes = v and (tonumber(v) or date.parse_duration(v))
    if not minutes then
      utils.error("Invalid effort: " .. input)
      return
    end
    M.state.filters.effort = { (neg == "-" and "-" or "+") .. (op ~= "" and op or "<") .. v }
  end
  M.redo()
end

--- Set the tag filter to a list like { "+work", "-home" }.
function M.set_tag_filter(list)
  M.state.filters.tag = list or {}
  M.redo()
end

--- Parse an org-agenda-filter string ("+work-John<0:10-/plot/") into
--- filter lists. Tags win over categories.
function M.parse_filter(s, negate)
  local tags, cats = {}, {}
  for _, t in ipairs(filter_tag_names()) do
    tags[t] = true
  end
  for _, c in ipairs(all_categories_in_view()) do
    cats[c] = true
  end
  local out = { tag = {}, category = {}, regexp = {}, effort = {} }
  local function push(list, v)
    if not vim.tbl_contains(list, v) then
      list[#list + 1] = v
    end
  end
  -- a hyphen inside double quotes belongs to the name
  s = s:gsub('"([^"]*)-([^"]*)"', '"%1~~~%2"')
  while true do
    local ws, pm = s:match("^([ \t]*)([%+%-]?)")
    local rest = s:sub(#ws + #pm + 1)
    local name = rest:match("^[^%-%+<>=/ \t]+")
    local eff = not name and rest:match("^[<>=][%d:]+")
    local re, re_full
    if not name and not eff then
      re_full, re = rest:match("^(/([^/]+)/?)")
    end
    if not (name or eff or re) then
      break
    end
    pm = pm ~= "" and pm or "+"
    if negate then
      pm = pm == "+" and "-" or "+"
    end
    if name then
      name = name:gsub("~~~", "-")
      if tags[name] then
        push(out.tag, pm .. name)
      elseif cats[(name:gsub('^"(.*)"$', "%1"))] then
        push(out.category, pm .. name:gsub('^"(.*)"$', "%1"))
      else
        utils.notify(string.format("`%s%s' filter ignored because tag/category is not represented", pm, name))
      end
      s = rest:sub(#name + 1)
    elseif eff then
      push(out.effort, pm .. eff)
      s = rest:sub(#eff + 1)
    else
      push(out.regexp, pm .. re)
      s = rest:sub(#re_full + 1)
    end
  end
  return out
end

--- The current filters as an org-agenda-filter string.
local function filter_string()
  local f = M.state.filters
  local s = join(f.category) .. join(f.tag)
  if f.effort[1] then
    s = s .. f.effort[1]:gsub("^%+", "")
  end
  if f.regexp[1] then
    s = s .. "/" .. f.regexp[1]:gsub("^%+", "") .. "/"
  end
  return s
end

--- Tag filter from `auto_exclude_function` (org-agenda-auto-exclude-function).
local function auto_exclude()
  local fn = config.opts.agenda.auto_exclude_function
  if type(fn) ~= "function" then
    utils.error("`agenda.auto_exclude_function' is undefined")
    return
  end
  M.state.filters.tag = {}
  for _, t in ipairs(all_tags_in_view()) do
    local m = fn(t:lower())
    if m then
      M.state.filters.tag[#M.state.filters.tag + 1] = m
    end
  end
  M.redo()
end

--- org-agenda-filter-by-tag with a key: a tag selection key, SPC (any tag),
--- `?` (untagged), TAB (completion), `.` (tags of the entry at point), `\`
--- (off), RET (auto exclude), `+`/`-` (filter for/against), q (quit,
--- unless a tag uses q as its key).
function M.filter_by_tag(count)
  local exclude = count == 1
  local accumulate = count == 2
  local keys = {}
  local chars = {}
  for _, f in ipairs(files.agenda_files()) do
    for _, d in ipairs(f:tag_definitions()) do
      if d.key and d.name and not keys[d.key] then
        keys[d.key] = d.name
        chars[#chars + 1] = d.key
      end
    end
  end
  local tag
  while true do
    local prompt = string.format(
      "%s by tag: [%s ]tag-char [TAB]tag [?]untagged %s[\\]off [q]uit",
      exclude and "Exclude[+]" or "Filter[-]",
      table.concat(chars, ""),
      config.opts.agenda.auto_exclude_function and "[RET] " or ""
    )
    local ch = utils.getchar(prompt)
    if not ch or (ch == "q" and not keys.q) then
      return
    elseif ch == "-" then
      exclude = true
    elseif ch == "+" then
      exclude = false
    elseif ch == "\\" then
      M.state.filters.tag = {}
      M.redo()
      return
    elseif ch == "\r" then
      if config.opts.agenda.auto_exclude_function then
        auto_exclude()
      else
        M.state.filters.tag = {}
        M.redo()
      end
      return
    elseif ch == "." then
      local item = M.item_at_cursor()
      M.state.filters.tag = {}
      for _, t in ipairs(item and item.tags or {}) do
        M.state.filters.tag[#M.state.filters.tag + 1] = "+" .. t
      end
      M.redo()
      return
    elseif ch == "\t" then
      tag = utils.input_complete("Tag: ", filter_tag_names())
      if not tag or tag == "" then
        return
      end
      break
    elseif ch == " " then
      tag = ""
      break
    elseif ch == "?" then
      tag, exclude = "", not exclude
      break
    elseif keys[ch] then
      tag = keys[ch]
      break
    else
      utils.error("Invalid tag selection character " .. ch)
      return
    end
  end
  local new = { (exclude and "-" or "+") .. tag }
  if accumulate then
    vim.list_extend(new, M.state.filters.tag)
  end
  M.state.filters.tag = new
  M.redo()
end

--- org-agenda-filter-by-effort: an operator key, then the index of an
--- Effort_ALL value (1..9, 0 = 10th).
function M.filter_by_effort(count)
  local negative = count == 1
  local keep = count == 2
  local op
  while not op do
    local ch = utils.getchar("Effort operator? (> = or <)     or press `_' again to remove filter")
    if not ch then
      return
    elseif ch == "_" then
      M.state.filters.effort = {}
      M.redo()
      utils.notify("Effort filter removed")
      return
    elseif ch == "<" or ch == ">" or ch == "=" then
      op = ch
    end
  end
  local all = (config.opts.global_properties or {})[(config.opts.effort_property or "Effort") .. "_ALL"]
    or "0 0:10 0:30 1:00 2:00 3:00 4:00 5:00 6:00 7:00"
  local efforts = vim.split(all, "%s+", { trimempty = true })
  local labels = {}
  for i, e in ipairs(efforts) do
    labels[#labels + 1] = string.format("[%d]%s", i % 10, e)
  end
  local idx
  while not idx do
    local ch = utils.getchar("Effort " .. op .. " " .. table.concat(labels, " "))
    if not ch then
      return
    end
    local n = tonumber(ch)
    if n then
      n = n == 0 and 10 or n
      if efforts[n] then
        idx = n
      end
    end
  end
  local new = { (negative and "-" or "+") .. op .. efforts[idx] }
  if keep then
    vim.list_extend(new, M.state.filters.effort)
  end
  M.state.filters.effort = new
  M.redo()
end

--- Set a limit (org-agenda-limit-interactively); count > 0 removes them.
function M.limit(count)
  if count and count > 0 then
    M.state.limits = {}
    M.redo()
    utils.notify("Agenda limits removed")
    return
  end
  local ch = utils.getchar("Number of [e]ntries [t]odos [T]ags [E]ffort? ")
  local names = { e = "max_entries", t = "max_todos", T = "max_tags", E = "max_effort" }
  local name = ch and names[ch]
  if not name then
    return
  end
  local prompt = name == "max_effort" and "How many minutes? " or "How many? "
  local n = tonumber(utils.input({ prompt = prompt }) or "")
  if not n then
    return
  end
  M.state.limits[name] = n
  M.redo()
end

--- Mark every entry whose agenda line and text (the TODO keyword,
--- priority, headline and tags, without the prefix) match `pattern`, an
--- Emacs regexp (org-agenda-bulk-mark-regexp tests the `txt' property).
function M.mark_regexp(pattern)
  local ok, re = pcall(require("org.agenda.search").compile_emacs_regexp, pattern)
  if not ok then
    ok, re = pcall(vim.regex, "\\c" .. pattern)
  end
  if not ok then
    utils.error("Invalid regexp: " .. pattern)
    return 0
  end
  local n = 0
  for lnum, item in pairs(M.state.line_items) do
    local line = vim.api.nvim_buf_get_lines(M.state.buf, lnum - 1, lnum, false)[1] or ""
    if re:match_str(line) and re:match_str(item_txt(item)) then
      M.state.marks[item_key(item)] = item
      n = n + 1
    end
  end
  M.render_marks()
  utils.notify(string.format("%d entries marked", n))
  return n
end

shared.auto_exclude = auto_exclude
shared.filter_string = filter_string
