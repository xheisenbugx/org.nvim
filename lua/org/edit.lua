---@mod org.edit Low-level buffer editing primitives
---
--- Every high-level operation accepts an optional `target`:
---   `nil`                       -> headline at cursor in the current buffer
---   `{ bufnr = n, lnum = l }`   -> headline containing line `l` in buffer `n`
--- Primitives here never prompt and never log; they just rewrite lines.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

--- `ts_index`: which plain timestamp of the headline (timestamps.set_date
--- and shift; an agenda item's own).
---@alias org.Target { bufnr?: integer, lnum?: integer, ts_index?: integer }

--- Resolve a target to (bufnr, file, headline). headline may be nil.
---@param target? org.Target
---@return integer bufnr, org.File file, org.Headline|nil headline
function M.resolve(target)
  target = target or {}
  local bufnr = target.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local lnum = target.lnum
  if not lnum then
    if bufnr == vim.api.nvim_get_current_buf() then
      lnum = vim.api.nvim_win_get_cursor(0)[1]
    else
      lnum = 1
    end
  end
  local file = files.get_buffer(bufnr)
  return bufnr, file, file:headline_at(lnum)
end

--- Like resolve, but warns and returns nil when not on/under a headline.
function M.resolve_headline(target)
  local bufnr, file, hl = M.resolve(target)
  if not hl then
    utils.warn("Not under a headline")
    return nil
  end
  return bufnr, file, hl
end

--- In Visual mode, the headlines of the selection when
--- `loop_over_headlines_in_active_region` is set (Emacs
--- org-loop-over-headlines-in-active-region): leaves Visual mode and returns
--- a list of `{ bufnr, lnum = function }` whose `lnum()` follows edits.
--- Headlines hidden in a closed fold are skipped, like Emacs skips
--- invisible entries; with "start-level" only headlines of the first
--- headline's level are used. A match string acts like true: Emacs 9.8
--- documents it but its commands pass nil as the match. `skip(hl)` leaves
--- more headlines out. Returns nil outside Visual mode.
---@param skip? fun(hl: org.Headline): boolean
---@return { bufnr: integer, lnum: fun(): integer|nil }[]|nil
function M.region_headlines(skip)
  local loop = require("org.config").opts.loop_over_headlines_in_active_region
  local mode = vim.fn.mode()
  if not loop or not (mode == "v" or mode == "V" or mode == "\22") then
    return nil
  end
  local s, _, e = utils.visual_range()
  utils.exit_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  local out, level = {}, nil
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e then
      local fc = vim.fn.foldclosed(hl.line)
      level = level or hl.level
      if (fc == -1 or fc == hl.line) and (loop ~= "start-level" or hl.level == level) and not (skip and skip(hl)) then
        -- the edits made for earlier headlines move the later ones
        local mark = require("org.marks").set(bufnr, hl.line)
        out[#out + 1] = {
          bufnr = bufnr,
          lnum = function()
            local l = mark and mark:lnum()
            require("org.marks").del(mark)
            return l
          end,
        }
      end
    end
  end
  return out
end

--- Re-fetch a headline after an edit (same buffer, by line).
function M.refresh(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  return file:headline_at(lnum), file
end

--- Indentation used for planning lines / drawers under a headline.
function M.body_indent(level)
  if require("org.ui.decorations").adapt_indentation(0) then
    return string.rep(" ", level + 1)
  end
  return ""
end

---------------------------------------------------------------------------
-- Headline line
---------------------------------------------------------------------------

--- Display width of `s` from column 0, a tab reaching the next multiple
--- of 8 (Org fixes tab-width at 8).
local function line_width(s)
  if not s:find("\t", 1, true) then
    return utils.width(s)
  end
  local w = 0
  for seg, tab in s:gmatch("([^\t]*)(\t?)") do
    w = w + utils.width(seg)
    if tab ~= "" then
      w = w + 8 - w % 8
    end
  end
  return w
end

--- Place tags on a headline text according to `tags_column`.
---@param before string headline text without tags
---@param tags string[]
function M.with_tags(before, tags)
  before = before:gsub("%s+$", "")
  if not tags or #tags == 0 then
    -- A stars-only headline keeps its space, or it stops being a headline
    -- (Emacs leaves "* ").
    if before:match("^%*+$") then
      return before .. " "
    end
    return before
  end
  local tagstr = ":" .. table.concat(tags, ":") .. ":"
  local col = require("org.config").opts.tags_column or -77
  local w = line_width(before)
  local pad
  if col < 0 then
    pad = -col - w - utils.width(tagstr)
  else
    pad = col - w
  end
  pad = math.max(pad, 1)
  return before .. string.rep(" ", pad) .. tagstr
end

--- Build a headline line from parts.
---@param p { level: integer, todo?: string, priority?: string, commented?: boolean, title?: string, tags?: string[] }
function M.build_headline(p)
  local parts = { string.rep("*", p.level) }
  if p.todo and p.todo ~= "" then
    parts[#parts + 1] = p.todo
  end
  if p.priority and p.priority ~= "" then
    parts[#parts + 1] = "[#" .. p.priority .. "]"
  end
  if p.commented then
    parts[#parts + 1] = "COMMENT"
  end
  if p.title and p.title ~= "" then
    parts[#parts + 1] = p.title
  end
  local line = table.concat(parts, " ")
  if #parts == 1 then
    line = line .. " "
  end
  line = M.with_tags(line, p.tags)
  -- a headline with only a TODO keyword keeps a space after it (org-todo
  -- inserts " KEYWORD " in an empty headline)
  if #parts == 2 and parts[2] == p.todo and not (p.tags and #p.tags > 0) then
    line = line .. " "
  end
  return line
end

--- Realign the tags of a headline line.
function M.align_tags_line(line, todo_cfg)
  local p = parser.parse_headline_line(line, todo_cfg)
  if not p or #p.tags == 0 then
    return line
  end
  return M.build_headline(p)
end

--- Are tags realigned after edits (org-auto-align-tags)?
function M.auto_align_tags()
  return require("org.config").opts.auto_align_tags ~= false
end

--- Update components of the headline at `lnum`.
--- `changes` keys: todo, priority, title, tags, level, commented.
--- Use `false` to remove todo/priority. New tags are sorted with
--- `tags_sort_function`. With `auto_align_tags` off, the space before the
--- tags is kept, and new tags follow the title after one space. A change
--- of the tags fires `OrgTagsChanged` (org-set-tags runs
--- org-after-tags-change-hook), whose handlers may move the headline: the
--- second value is the line it is on afterwards.
---@return boolean ok, integer lnum
function M.update_headline(bufnr, lnum, changes)
  local file = files.get_buffer(bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local p = parser.parse_headline_line(line, file.settings.todo)
  if not p then
    return false, lnum
  end
  local old_tags = p.tags or {}
  if changes.tags then
    changes = vim.tbl_extend("force", changes, { tags = require("org.tags").sort(changes.tags) })
  end
  for k, v in pairs(changes) do
    if v == false and (k == "todo" or k == "priority") then
      p[k] = nil
    else
      p[k] = v
    end
  end
  local new
  if M.auto_align_tags() or not p.tags or #p.tags == 0 then
    new = M.build_headline(p)
  else
    local gap = line:match("(%s+):[^%s]+:%s*$")
    if not gap or not vim.deep_equal(old_tags, p.tags) then
      gap = " "
    end
    new = M.build_headline(vim.tbl_extend("force", p, { tags = {} })) .. gap .. ":" .. table.concat(p.tags, ":") .. ":"
  end
  -- a headline without title keeps its trailing space, as Emacs edits
  -- the keyword and the priority in place ("* " -> "* [#B] ")
  if (p.title or "") == "" and #(p.tags or {}) == 0 and line:match("%s$") and not new:match("%s$") then
    new = new .. " "
  end
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
  if changes.tags then
    lnum = require("org.tags").changed(bufnr, lnum, old_tags, p.tags or {})
  end
  return true, lnum
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

local PLANNING_WORD = { closed = "CLOSED", deadline = "DEADLINE", scheduled = "SCHEDULED" }

--- Build a planning line from { scheduled, deadline, closed } dates, in
--- the order of `order` (kinds; default closed, deadline, scheduled).
--- `raw` gives the text to write for some kinds (their timestamp as it was
--- written).
---@param order? string[]
---@param raw? table<string, string>
function M.build_planning(planning, indent, order, raw)
  local parts = {}
  local seen = {}
  local all = vim.list_extend(vim.deepcopy(order or {}), { "closed", "deadline", "scheduled" })
  for _, kind in ipairs(all) do
    if planning[kind] and not seen[kind] then
      seen[kind] = true
      parts[#parts + 1] = PLANNING_WORD[kind] .. ": " .. (raw and raw[kind] or planning[kind]:to_string())
    end
  end
  if #parts == 0 then
    return nil
  end
  return (indent or "") .. table.concat(parts, " ")
end

--- The timestamp after `word:` on planning line `line`, as written (a
--- range "<a>--<b>" whole), nil when there is none.
---@param line string
---@param word string
---@return string|nil
local function planning_stamp(line, word)
  local at = line:match("%f[%w]" .. word .. ":%s*()")
  if not at then
    return nil
  end
  local open = line:sub(at, at)
  local close = open == "<" and ">" or open == "[" and "]" or nil
  if not close then
    return nil
  end
  local stop = line:find(close, at + 1, true)
  if not stop then
    return nil
  end
  if line:sub(stop + 1, stop + 3) == "--" .. open then
    local stop2 = line:find(close, stop + 4, true)
    if stop2 then
      stop = stop2
    end
  end
  return line:sub(at, stop)
end

--- Set (or remove with nil) a planning entry for the headline at `lnum`.
--- Like org-add-planning-info, a new or changed entry goes first and the
--- others keep their order; with `opts.in_place` (a repeater shifting the
--- date, as org-auto-repeat-maybe does), it stays where it is.
---@param kind "scheduled"|"deadline"|"closed"
---@param opts? { in_place?: boolean }
function M.set_planning(bufnr, lnum, kind, value, opts)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return false
  end
  local planning = vim.deepcopy(hl.planning)
  -- deepcopy loses metatables; rebuild dates
  local date = require("org.date")
  for k, v in pairs(planning) do
    planning[k] = date.Date.new(v)
    if v.range_end then
      planning[k].range_end = date.Date.new(v.range_end)
    end
  end
  planning[kind] = value
  local indent = M.body_indent(hl.level)
  if hl.planning_line then
    indent = file.lines[hl.planning_line]:match("^(%s*)")
  end
  -- the kinds in the order of the planning line
  local order = {}
  if hl.planning_line then
    local found = {}
    for pos, word in file.lines[hl.planning_line]:gmatch("()(%u+):") do
      local k = word:lower()
      if PLANNING_WORD[k] == word and not found[k] then
        found[k] = true
        order[#order + 1] = { pos = pos, kind = k }
      end
    end
    table.sort(order, function(a, b)
      return a.pos < b.pos
    end)
    order = vim.tbl_map(function(o)
      return o.kind
    end, order)
  end
  if value and not (opts and opts.in_place and vim.tbl_contains(order, kind)) then
    order = vim.tbl_filter(function(k)
      return k ~= kind
    end, order)
    table.insert(order, 1, kind)
  end
  -- the other entries keep their text, as org-add-planning-info only
  -- replaces the one it sets (a wrong weekday stays wrong)
  local raw = {}
  if hl.planning_line then
    local pline = file.lines[hl.planning_line]
    for k, word in pairs(PLANNING_WORD) do
      if k ~= kind then
        raw[k] = planning_stamp(pline, word)
      end
    end
  end
  local line = M.build_planning(planning, indent, order, raw)
  if hl.planning_line then
    if line then
      vim.api.nvim_buf_set_lines(bufnr, hl.planning_line - 1, hl.planning_line, false, { line })
    else
      vim.api.nvim_buf_set_lines(bufnr, hl.planning_line - 1, hl.planning_line, false, {})
    end
  elseif line then
    vim.api.nvim_buf_set_lines(bufnr, hl.line, hl.line, false, { line })
  end
  return true
end

---------------------------------------------------------------------------
-- Properties & drawers
---------------------------------------------------------------------------

--- Line after the headline, planning line and property drawer.
function M.meta_end(hl)
  local l = hl.line
  if hl.planning_line then
    l = hl.planning_line
  end
  if hl.properties_range then
    l = hl.properties_range[2]
  end
  return l
end

--- A property drawer line `:NAME: value` formatted with `property_format`
--- (org-property-format, `%-10s %s`); an empty value leaves no trailing
--- space. The value loses its leading and trailing blanks, as with
--- org--align-node-property.
function M.property_line(indent, name, value)
  local fmt = require("org.config").opts.property_format or "%-10s %s"
  value = (value or ""):match("^[ \t]*(.-)[ \t]*$")
  local ok, text = pcall(string.format, fmt, ":" .. name .. ":", value)
  if not ok then
    text = ":" .. name .. ": " .. value
  end
  return (indent or "") .. text:gsub("%s+$", "")
end

--- Set or delete (value = nil) a property in the headline's drawer. Before
--- the first headline, the file-level property drawer at the top of the
--- file is used (created when needed), like Emacs. Deleting also removes
--- the `NAME+` lines.
function M.set_property(bufnr, lnum, name, value)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local range, indent, at
  if hl then
    range = hl.properties_range
    indent = M.body_indent(hl.level)
    at = hl.planning_line or hl.line
  else
    range = file.properties_range
    indent = ""
    -- after leading comments (org-insert-property-drawer)
    at = 0
    while file.lines[at + 1] and file.lines[at + 1]:match("^%s*#%s") do
      at = at + 1
    end
  end
  local upper = name:upper()
  if range then
    local s, e = range[1], range[2]
    indent = file.lines[s]:match("^(%s*)")
    if value == nil then
      local removed = 0
      for i = e - 1, s + 1, -1 do
        local key = parser.parse_property_line(file.lines[i])
        if key and (key:upper() == upper or key:upper() == upper .. "+") then
          vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
          removed = removed + 1
        end
      end
      if removed > 0 and e - s - 1 == removed then
        -- drawer is now empty: remove it
        vim.api.nvim_buf_set_lines(bufnr, s - 1, s + 1, false, {})
      end
      return true
    end
    for i = s + 1, e - 1 do
      local key = parser.parse_property_line(file.lines[i])
      if key and key:upper() == upper then
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { M.property_line(indent, name, value) })
        return true
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, { M.property_line(indent, name, value) })
    return true
  end
  if value == nil then
    return true
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, {
    indent .. ":PROPERTIES:",
    M.property_line(indent, name, value),
    indent .. ":END:",
  })
  return true
end

--- Ensure a drawer named `name` exists after the meta lines; returns its
--- (start, end) line numbers. `lnum` is on or under a headline.
---@param bufnr integer
---@param lnum integer
---@param name string
---@return integer start, integer end
function M.ensure_drawer(bufnr, lnum, name)
  local file = files.get_buffer(bufnr)
  local hl = assert(file:headline_at(lnum), "ensure_drawer: not under a headline")
  for _, d in ipairs(hl.drawers) do
    if d.name:upper() == name:upper() then
      return d.start, d["end"]
    end
  end
  local indent = M.body_indent(hl.level)
  local at = M.meta_end(hl)
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. ":" .. name .. ":", indent .. ":END:" })
  return at + 1, at + 2
end

--- Name of the log drawer, or nil when logging directly into the entry.
--- With a headline, `#+STARTUP: logdrawer|nologdrawer` and the (inherited)
--- LOG_INTO_DRAWER property override `log_into_drawer`.
---@param hl? org.Headline
---@return string|nil
function M.log_drawer_name(hl)
  ---@type string|boolean|nil
  local d = require("org.config").opts.log_into_drawer
  if hl then
    local startup = hl.file.settings.startup
    if startup.logdrawer then
      d = true
    elseif startup.nologdrawer then
      d = false
    end
    local prop = hl:get_property("LOG_INTO_DRAWER", true)
    if prop and prop ~= "" then
      if prop == "nil" then
        d = false
      elseif prop == "t" then
        d = true
      else
        d = prop
      end
    end
  end
  if d == true then
    return "LOGBOOK"
  end
  return type(d) == "string" and d or nil
end

--- Vim regex (very nomagic) matching a state-change note item, built from
--- the `state` entry of `log_note_headings` (org-skip-over-state-notes).
local function state_note_regex()
  local headings = require("org.config").opts.log_note_headings or {}
  local fmt = headings.state or M.DEFAULT_LOG_NOTE_HEADINGS.state
  local out, i = { "\\V\\^\\s\\*-\\s\\+" }, 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    local esc, conv = fmt:match("^(%%%-?[%d.]*)(%a)", i)
    if esc then
      if conv == "s" or conv == "S" then
        out[#out + 1] = '\\%("\\S\\+"\\)\\='
      elseif conv == "t" or conv == "d" then
        out[#out + 1] = "[\\d\\{4}-\\d\\d-\\d\\d\\[^]]\\*]"
      elseif conv == "T" or conv == "D" then
        out[#out + 1] = "<\\d\\{4}-\\d\\d-\\d\\d\\[^>]\\*>"
      else
        out[#out + 1] = "\\.\\{-}"
      end
      i = i + #esc + 1
    elseif c:match("%s") then
      out[#out + 1] = "\\s\\+"
      i = #fmt:match("^%s+", i) + i
    else
      out[#out + 1] = c == "\\" and "\\\\" or c
      i = i + 1
    end
  end
  return vim.regex(table.concat(out))
end

--- Where a log note goes in an entry without log drawer (org-log-beginning):
--- after the planning line and property drawer (with
--- `log_state_notes_insert_after_drawers`, also after clock lines and
--- drawers), then past blank lines; with the oldest notes first, after the
--- existing state notes. Returns the line the note is inserted before and
--- whether that line is a blank line the note replaces.
---@param lines string[]
---@param hl org.Headline
---@param reversed boolean
---@return integer lnum, boolean replace
local function log_beginning(lines, hl, reversed)
  local last = hl.body_end
  local function blank(l)
    return lines[l] ~= nil and lines[l]:match("^%s*$") ~= nil
  end
  local i = M.meta_end(hl) + 1
  if require("org.config").opts.log_state_notes_insert_after_drawers then
    -- org-end-of-meta-data with FULL = t
    while i <= last do
      local l = lines[i]
      if l:match("^%s*$") or l:match("^%s*CLOCK:") then
        i = i + 1
      elseif l:match("^%s*:[%w_-]+:%s*$") then
        local j = i + 1
        while j <= last and not lines[j]:match("^%s*:[eE][nN][dD]:%s*$") do
          j = j + 1
        end
        if j > last then
          break
        end
        i = j + 1
      else
        break
      end
    end
  end
  local endpos = i
  while i <= last and blank(i) do
    i = i + 1
  end
  if not reversed then
    local re = state_note_regex()
    while i <= last and re:match_str(lines[i]) do
      local n = #lines[i]:match("^(%s*)")
      i = i + 1
      while i <= last and (blank(i) or #lines[i]:match("^(%s*)") > n) do
        i = i + 1
      end
    end
    while i - 1 > hl.line and blank(i - 1) do
      i = i - 1
    end
    if i < endpos then
      i = endpos
    end
    return i, i <= last and blank(i)
  end
  return i, false
end

--- Add a log entry (list of lines, first starts with "- ") to the headline.
--- Fires the `OrgNoteStored` User autocmd (org-after-note-stored-hook).
function M.add_log_entry(bufnr, lnum, entry_lines)
  if not entry_lines or #entry_lines == 0 then
    return
  end
  local cfg = require("org.config").opts
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return
  end
  local drawer = M.log_drawer_name(hl)
  local reversed = cfg.log_states_order_reversed ~= false
  if file.settings.startup.logstatesreversed then
    reversed = true
  elseif file.settings.startup.nologstatesreversed then
    reversed = false
  end
  local first
  if drawer then
    local s, e = M.ensure_drawer(bufnr, hl.line, drawer)
    local indent = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1]:match("^(%s*)")
    local lines = vim.tbl_map(function(l)
      return indent .. l
    end, entry_lines)
    if reversed then
      vim.api.nvim_buf_set_lines(bufnr, s, s, false, lines)
      first = s + 1
    else
      vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, lines)
      first = e
    end
  else
    local indent = M.body_indent(hl.level)
    local lines = vim.tbl_map(function(l)
      return indent .. l
    end, entry_lines)
    local at, replace = log_beginning(file.lines, hl, reversed)
    vim.api.nvim_buf_set_lines(bufnr, at - 1, replace and at or at - 1, false, lines)
    first = at
  end
  M.note_stored(bufnr, first, hl.line)
end

--- Fire the `OrgNoteStored` User autocmd (org-after-note-stored-hook) for
--- a note stored at line `lnum` of the entry at line `headline`.
function M.note_stored(bufnr, lnum, headline)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgNoteStored",
    data = { bufnr = bufnr, lnum = lnum, headline = headline },
    modeline = false,
  })
end

--- Emacs default note headings (org-log-note-headings).
M.DEFAULT_LOG_NOTE_HEADINGS = {
  done = "CLOSING NOTE %t",
  state = "State %-12s from %-12S %t",
  note = "Note taken on %t",
  reschedule = "Rescheduled from %S on %t",
  delschedule = "Not scheduled, was %S on %t",
  redeadline = "New deadline from %S on %t",
  deldeadline = "Removed deadline, was %S on %t",
  refile = "Refiled on %t",
  ["clock-out"] = "",
}

--- What the `*Org Note*` buffer says the note is for, per purpose (the
--- "# Insert note for ..." line of org-add-log-note).
local NOTE_PURPOSES = {
  ["clock-out"] = "stopped clock",
  done = "closed todo item",
  reschedule = "rescheduling",
  delschedule = "no longer scheduled",
  redeadline = "changing deadline",
  deldeadline = "removing deadline",
  refile = "refiling",
  note = "this entry",
}

--- Description of a note of `purpose` for the note buffer; a state change
--- names both states.
---@param purpose string
---@param state? string new state
---@param previous? string previous state
function M.note_purpose(purpose, state, previous)
  if purpose == "state" then
    return string.format('state change from "%s" to "%s"', previous or "", state or "")
  end
  return NOTE_PURPOSES[purpose] or purpose
end

--- Quote a state or timestamp for a note heading (%s / %S): timestamps
--- are made inactive.
local function quote_state(v)
  if v == nil then
    return ""
  end
  if type(v) == "table" then
    v = v:clone({ active = false }):to_string({ range = false })
  elseif v:match("^<.*>$") then
    v = "[" .. v:sub(2, -2) .. "]"
  end
  return '"' .. v .. '"'
end

--- Heading of a log note for `purpose` ("done", "state", "note",
--- "reschedule", ...) from `log_note_headings` (org-log-note-headings),
--- with `%t %T %d %D %s %S %u %U` replaced, like org-store-log-note.
--- Returns the heading without the leading "- " ("" when the heading is
--- empty).
---@param purpose string
---@param state? string|table new state or timestamp (%s)
---@param previous? string|table previous state or timestamp (%S)
---@param time? table timestamp for %t (defaults to the effective time)
function M.log_heading(purpose, state, previous, time)
  local date = require("org.date")
  local headings = require("org.config").opts.log_note_headings or {}
  local fmt = headings[purpose]
  if fmt == nil then
    fmt = M.DEFAULT_LOG_NOTE_HEADINGS[purpose] or ""
  end
  time = time or date.effective_now()
  local values = {
    t = time:clone({ active = false }):to_string(),
    T = time:clone({ active = true }):to_string(),
    d = time:clone({ active = false, hour = vim.NIL, min = vim.NIL }):to_string(),
    D = time:clone({ active = true, hour = vim.NIL, min = vim.NIL }):to_string(),
    s = quote_state(state),
    S = quote_state(previous),
    u = vim.env.USER or vim.env.LOGNAME or "",
    U = vim.env.USER or "",
  }
  return (
    fmt:gsub("%%(%-?%d*)([a-zA-Z])", function(flags, c)
      local v = values[c]
      if v == nil then
        return nil
      end
      return flags ~= "" and string.format("%" .. flags .. "s", v) or v
    end)
  )
end

--- Log entry lines for a note of `purpose` (see `log_heading`), or nil
--- when both the heading and the note are empty.
function M.log_entry(purpose, note, state, previous, time)
  local heading = M.log_heading(purpose, state, previous, time)
  if heading ~= "" then
    return M.log_lines("- " .. heading, note)
  end
  if not note or vim.trim(note) == "" then
    return nil
  end
  local lines = vim.split(vim.trim(note), "\n")
  local out = { "- " .. lines[1] }
  for i = 2, #lines do
    out[#out + 1] = "  " .. lines[i]
  end
  return out
end

--- Format a note body into log entry lines: first line + continuation.
function M.log_lines(header, note)
  local out = { header }
  if note and vim.trim(note) ~= "" then
    out[1] = header .. " \\\\"
    for _, l in ipairs(vim.split(note, "\n")) do
      out[#out + 1] = "  " .. l
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Subtrees
---------------------------------------------------------------------------

---@return integer? start, integer? end (1-based and inclusive)
function M.subtree_range(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return nil
  end
  return hl.line, hl.end_line
end

--- Change the level of every headline in `lines` by `delta`.
function M.shift_levels(lines, delta)
  local out = {}
  for i, l in ipairs(lines) do
    local stars = l:match("^(%*+) ")
    if stars then
      local n = math.max(1, #stars + delta)
      out[i] = string.rep("*", n) .. l:sub(#stars + 1)
    else
      out[i] = l
    end
  end
  return out
end

--- Normalize subtree lines so the first headline has `level` (only the
--- stars change).
function M.relevel(lines, level)
  local first = lines[1] and (lines[1]:match("^(%*+)") or "")
  if not first or first == "" then
    return lines
  end
  return M.shift_levels(lines, level - #first)
end

--- Normalize subtree lines so the first headline has `level`, as
--- org-paste-subtree does for refile and archive: each headline promoted
--- or demoted like org-promote / org-demote (tags realigned, inline tasks
--- left alone, the indentation fixed with `adapt_indentation`).
---@param lines string[]
---@param level integer
---@param todo_cfg? table the TODO keywords (default: the global ones)
function M.paste_relevel(lines, level, todo_cfg)
  local first = lines[1] and (lines[1]:match("^(%*+)") or "")
  if not first or first == "" or level == #first then
    return lines
  end
  require("org.structure")
  return require("org.structure.shared").relevel(lines, level - #first, todo_cfg)
end

return M
