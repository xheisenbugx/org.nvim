---@mod org.todo TODO state changes (org-todo)
---
--- Implements Emacs `org-todo` semantics: keyword cycling per sequence,
--- CLOSED timestamps, state-change logging (`!` / `@` flags, log_done,
--- #+STARTUP overrides), repeating tasks, TODO/checkbox dependencies and
--- clocking out when a task is done.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local utils = require("org.utils")

local M = {}

local function now_inactive()
  return date.now():clone({ active = false })
end

local LOGGING_WORDS = {
  logdone = { "done", "time" },
  lognotedone = { "done", "note" },
  nologdone = { "done", false },
  logrepeat = { "repeat", "time" },
  lognoterepeat = { "repeat", "note" },
  nologrepeat = { "repeat", false },
}

--- Per-entry logging from the (inherited) LOGGING property, like Emacs
--- `org-local-logging`: `:LOGGING: nil`, `:LOGGING: lognotedone logrepeat`,
--- `:LOGGING: WAIT(@) DONE(!)`. When the property is set, logging of done
--- and repeat and the keyword flags all start from "off".
---@param hl? org.Headline
---@return { done: string|false, ["repeat"]: string|false, states: table<string, org.TodoKeyword> }|nil
function M.local_logging(hl)
  local value = hl and hl:get_property("LOGGING", true)
  if not value then
    return nil
  end
  local out = { done = false, ["repeat"] = false, states = {} }
  local todo_cfg = hl.file.settings.todo
  for w in value:gmatch("%S+") do
    local spec = LOGGING_WORDS[w]
    if spec then
      out[spec[1]] = spec[2]
    else
      local kw = require("org.todo_keywords").parse_token(w)
      if todo_cfg:is_keyword(kw.name) and (kw.log_enter or kw.log_leave) then
        out.states[kw.name] = kw
      end
    end
  end
  return out
end

--- Effective logging setting, honouring #+STARTUP overrides and, when a
--- headline is given, its LOGGING property.
---@param file org.File
---@param kind "done"|"repeat"|"reschedule"|"redeadline"|"clock_out"
---@param hl? org.Headline
function M.log_setting(file, kind, hl)
  local cfg = config.opts
  local startup = file and file.settings.startup or {}
  local value = ({
    done = cfg.log_done,
    ["repeat"] = cfg.log_repeat,
    reschedule = cfg.log_reschedule,
    redeadline = cfg.log_redeadline,
    clock_out = cfg.log_note_clock_out and "note" or false,
  })[kind]
  local word = kind == "clock_out" and "clock-out" or kind
  if startup["log" .. word] then
    value = "time"
  end
  if startup["lognote" .. word] then
    value = "note"
  end
  if startup["nolog" .. word] or (kind == "clock_out" and startup["nolognote" .. word]) then
    value = false
  end
  local loc = (kind == "done" or kind == "repeat") and M.local_logging(hl)
  if loc then
    value = loc[kind]
  end
  if value == true then
    value = "time"
  end
  return value or false
end

--- Format a state-change log entry header (Emacs style).
function M.state_log_header(new, old, ts)
  local function q(s)
    return '"' .. (s or "") .. '"'
  end
  return string.format("- State %-12s from %-12s %s", q(new), q(old), (ts or now_inactive()):to_string())
end

local function truthy_prop(v)
  return v ~= nil and v ~= "" and v:lower() ~= "nil"
end

local function previous_sibling_blocking(hl)
  local parent = hl.parent
  if parent and truthy_prop(parent.properties.ORDERED) then
    for _, sib in ipairs(parent.children) do
      if sib == hl then
        break
      end
      if sib:is_todo() or sib:has_undone_children() then
        return sib
      end
    end
  end
end

--- Reason the headline cannot be marked done, or nil
--- (org-block-todo-from-children-or-siblings-or-parent).
---@param hl org.Headline
function M.blocked_reason(hl)
  local cfg = config.opts
  if hl.properties.NOBLOCKING then
    return nil
  end
  if cfg.enforce_todo_dependencies then
    if hl:has_undone_children() then
      return "has unfinished child tasks"
    end
    local sib = previous_sibling_blocking(hl)
    if sib then
      return "previous sibling (ORDERED) is not done: " .. sib:plain_title()
    end
    -- an ancestor TODO that is itself blocked by ORDERED siblings
    local p = hl.parent
    while p and p:is_todo() do
      sib = previous_sibling_blocking(p)
      if sib then
        return "ancestor is blocked by ORDERED sibling: " .. sib:plain_title()
      end
      p = p.parent
    end
  end
  if cfg.enforce_todo_checkbox_dependencies then
    local lines = hl.file.lines
    for i = hl.line + 1, hl.body_end do
      local l = lines[i]
      if l:match("^%s*[-+*]%s+%[ %]") or l:match("^%s*%d+[.)]%s+%[ %]") or l:match("^%s+%*%s+%[ %]") then
        return "has unchecked checkboxes"
      end
    end
  end
  return nil
end

local function has_repeater(ts)
  return ts and ts.repeater and ts.repeater.value > 0
end

local function entry_repeats(hl)
  if has_repeater(hl.planning.scheduled) or has_repeater(hl.planning.deadline) then
    return true
  end
  for _, t in ipairs(hl.timestamps) do
    if has_repeater(t.date) then
      return true
    end
  end
  return false
end

--- Is the running clock on this headline?
local function clocked_here(bufnr, lnum)
  local ok, clock = pcall(require, "org.clock")
  if not ok or not clock.is_clocked_headline then
    return false, nil
  end
  return clock.is_clocked_headline(bufnr, lnum), clock
end

local function update_parent_statistics(bufnr, hl)
  if not hl.parent then
    return
  end
  local ok, lists = pcall(require, "org.lists")
  if ok and type(lists.update_statistics_for) == "function" then
    pcall(lists.update_statistics_for, bufnr, hl.parent.line)
  end
end

--- Shift every repeating timestamp of the entry (org-auto-repeat-maybe).
local function shift_repeaters(bufnr, hl, now)
  -- plain timestamps in the body / title: replace text in place (right to left)
  local by_line = {}
  for _, t in ipairs(hl.timestamps) do
    if has_repeater(t.date) then
      by_line[t.line] = by_line[t.line] or {}
      table.insert(by_line[t.line], t)
    end
  end
  for lnum, list in pairs(by_line) do
    table.sort(list, function(a, b)
      return a.start_col > b.start_col
    end)
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    for _, t in ipairs(list) do
      local nxt = date.apply_repeater(t.date, now)
      line = line:sub(1, t.start_col - 1) .. nxt:to_string() .. line:sub(t.end_col + 1)
    end
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
  end
  for _, kind in ipairs({ "deadline", "scheduled" }) do
    local ts = hl.planning[kind]
    if has_repeater(ts) then
      edit.set_planning(bufnr, hl.line, kind, date.apply_repeater(ts, now))
    elseif kind == "scheduled" and ts and not ts.repeater then
      -- a SCHEDULED date without repeater is no longer relevant
      edit.set_planning(bufnr, hl.line, kind, nil)
    end
  end
end

--- State a repeating entry returns to (org-auto-repeat-maybe): the
--- REPEAT_TO_STATE property, a string `todo_repeat_to_state`, the previous
--- state when `todo_repeat_to_state` is true, else the first keyword of the
--- previous state's sequence.
local function repeat_to_state(hl, todo_cfg, old)
  local rts = config.opts.todo_repeat_to_state
  local to = hl:get_property("REPEAT_TO_STATE")
  if not (to and todo_cfg:is_keyword(to)) then
    to = nil
    if type(rts) == "string" and todo_cfg:is_keyword(rts) then
      to = rts
    elseif rts and todo_cfg:is_keyword(old) then
      to = old
    end
  end
  if to then
    return to
  end
  local kw = todo_cfg:get(old)
  local seq = kw and todo_cfg.sequences[kw.seq]
  return seq and seq[1].name or nil
end

--- Apply `todo_state_tags_triggers` for `state` (org-todo-trigger-tag-changes).
local function trigger_tags(bufnr, lnum, todo_cfg, state)
  local triggers = config.opts.todo_state_tags_triggers
  if type(triggers) ~= "table" or vim.tbl_isempty(triggers) then
    return
  end
  local changes = {}
  local function collect(key)
    local spec = key and triggers[key]
    if type(spec) == "table" then
      local names = vim.tbl_keys(spec)
      table.sort(names)
      for _, tag in ipairs(names) do
        changes[#changes + 1] = { tag, spec[tag] and true or false }
      end
    end
  end
  collect(state or "")
  if todo_cfg:is_todo(state) then
    collect("todo")
  elseif todo_cfg:is_done(state) then
    collect("done")
  end
  if #changes == 0 then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local p = require("org.parser").parse_headline_line(line, todo_cfg)
  if not p then
    return
  end
  local tags = vim.deepcopy(p.tags or {})
  for _, c in ipairs(changes) do
    local idx
    for i, t in ipairs(tags) do
      if t == c[1] then
        idx = i
      end
    end
    if c[2] and not idx then
      tags[#tags + 1] = c[1]
    elseif not c[2] and idx then
      table.remove(tags, idx)
    end
  end
  edit.update_headline(bufnr, lnum, { tags = tags })
end

---@class org.TodoChangeResult
---@field old string|nil
---@field new string|nil final keyword in the buffer
---@field done_keyword? string keyword that triggered a repeat
---@field repeated? boolean
---@field bufnr integer
---@field lnum integer

--- Change the TODO state of a headline with full org semantics.
---@param target? org.Target
---@param new string|nil new keyword (nil clears)
---@param opts? { note?: string, force?: boolean, no_log?: boolean }
---@return org.TodoChangeResult|nil
function M.change_state(target, new, opts)
  opts = opts or {}
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local cfg = config.opts
  local todo_cfg = file.settings.todo
  local lnum = hl.line
  local old = hl.todo
  if new == "" then
    new = nil
  end
  if old == new then
    return { old = old, new = new, bufnr = bufnr, lnum = lnum }
  end
  if new and not todo_cfg:is_keyword(new) then
    utils.warn("Unknown TODO keyword: " .. new)
    return nil
  end
  local old_done = todo_cfg:is_done(old)
  local new_done = todo_cfg:is_done(new)
  local becomes_done = new_done and not old_done

  if becomes_done and not opts.force then
    local reason = M.blocked_reason(hl)
    if reason then
      utils.warn(string.format("TODO state change blocked: %s", reason))
      return nil
    end
  end

  -- keyword flags, or the LOGGING property's keyword specs when it is set
  local loc = M.local_logging(hl)
  local new_kw, old_kw = todo_cfg:get(new), todo_cfg:get(old)
  if loc then
    new_kw, old_kw = loc.states[new or ""], loc.states[old or ""]
  end
  local state_log = (new_kw and new_kw.log_enter) or (old_kw and old_kw.log_leave) or false
  if opts.no_log then
    state_log = false
  end
  local log_done = opts.no_log and false or M.log_setting(file, "done", hl)
  local now = date.now()
  local result = { old = old, new = new, bufnr = bufnr, lnum = lnum }

  if becomes_done and entry_repeats(hl) then
    -- repeating task: shift dates, return to a TODO state
    local log_repeat = opts.no_log and false or M.log_setting(file, "repeat", hl)
    local rep_log = log_repeat
    if state_log then
      rep_log = (state_log == "note" or log_repeat == "note") and "note" or "time"
    end
    local note = opts.note
    if rep_log == "note" and note == nil then
      note = utils.input({ prompt = "Note for state change to " .. new .. ": " })
    end
    local final = repeat_to_state(hl, todo_cfg, old)
    local has_clock = #hl.clocks > 0
    shift_repeaters(bufnr, hl, now)
    trigger_tags(bufnr, lnum, todo_cfg, new)
    edit.update_headline(bufnr, lnum, { todo = final or false })
    if hl.planning.closed then
      edit.set_planning(bufnr, lnum, "closed", nil)
    end
    trigger_tags(bufnr, lnum, todo_cfg, final)
    if log_repeat or has_clock then
      edit.set_property(bufnr, lnum, "LAST_REPEAT", now_inactive():to_string())
    end
    if rep_log then
      edit.add_log_entry(bufnr, lnum, edit.log_lines(M.state_log_header(new, old, now_inactive()), note))
    end
    result.new = final
    result.done_keyword = new
    result.repeated = true
  else
    local note = opts.note
    local wants_note = state_log == "note" or (becomes_done and log_done == "note")
    if wants_note and note == nil then
      note = utils.input({ prompt = "Note for state change to " .. (new or "none") .. ": " })
    end
    edit.update_headline(bufnr, lnum, { todo = new or false })
    if becomes_done and log_done then
      edit.set_planning(bufnr, lnum, "closed", now_inactive())
    elseif not new_done and hl.planning.closed then
      edit.set_planning(bufnr, lnum, "closed", nil)
    end
    trigger_tags(bufnr, lnum, todo_cfg, new)
    if state_log then
      edit.add_log_entry(bufnr, lnum, edit.log_lines(M.state_log_header(new, old, now_inactive()), note))
    elseif becomes_done and log_done == "note" then
      edit.add_log_entry(bufnr, lnum, edit.log_lines("- CLOSING NOTE " .. now_inactive():to_string(), note))
    end
  end

  -- org-clock-out-if-current: `out_when_done` is true or a list of states
  local out_when = (cfg.clock or {}).out_when_done
  local clock_out
  if type(out_when) == "table" then
    clock_out = vim.tbl_contains(out_when, new)
  else
    clock_out = out_when ~= false and new_done
  end
  if clock_out then
    local here, clock = clocked_here(bufnr, lnum)
    if here and clock then
      pcall(clock.clock_out, { switch_to_state = false, note = false })
    end
  end
  update_parent_statistics(bufnr, hl)
  return result
end

local function cycle(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local nxt = file.settings.todo:cycle(hl.todo, dir)
  return M.change_state({ bufnr = bufnr, lnum = hl.line }, nxt)
end

function M.cycle_next(target)
  return cycle(target, 1)
end

function M.cycle_prev(target)
  return cycle(target, -1)
end

--- Switch to the next keyword sequence (C-S-right in Emacs).
function M.next_sequence(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  return M.change_state({ bufnr = bufnr, lnum = hl.line }, file.settings.todo:next_sequence(hl.todo, dir or 1))
end

--- Pick a keyword (fast selection when keys are defined).
function M.select(target)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local todo_cfg = file.settings.todo
  local choice
  if todo_cfg.has_fast_keys then
    local items = {}
    for si, seq in ipairs(todo_cfg.sequences) do
      if #todo_cfg.sequences > 1 then
        items[#items + 1] = { heading = true, label = "Sequence " .. si }
      end
      for _, kw in ipairs(seq) do
        if kw.key then
          items[#items + 1] =
            { key = kw.key, label = kw.name .. (kw.name == hl.todo and "  (current)" or ""), value = kw.name }
        end
      end
    end
    items[#items + 1] = { key = " ", label = "(clear keyword)", value = "" }
    choice = require("org.ui").menu({ title = "TODO state", items = items })
  else
    local names = todo_cfg:names()
    names[#names + 1] = "(none)"
    choice = utils.select(names, { prompt = "TODO state" })
    if choice == "(none)" then
      choice = ""
    end
  end
  if choice == nil then
    return nil
  end
  return M.change_state({ bufnr = bufnr, lnum = hl.line }, choice ~= "" and choice or nil)
end

--- Emacs `C-c C-t` (org-todo with org-use-fast-todo-selection = auto):
--- fast selection when keywords define keys, otherwise cycle to the next
--- state. A count N switches to the Nth keyword (org-todo with a numeric
--- prefix).
function M.select_or_cycle(target)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local n = target == nil and vim.v.count or 0
  local names = file.settings.todo:names()
  if n > 0 and names[n] then
    return M.change_state({ bufnr = bufnr, lnum = hl.line }, names[n])
  end
  if file.settings.todo.has_fast_keys then
    return M.select(target)
  end
  return M.cycle_next(target)
end

--- Add a note to the entry (org-add-note).
function M.add_note(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local note = utils.input({ prompt = "Note: " })
  if not note or vim.trim(note) == "" then
    return nil
  end
  edit.add_log_entry(bufnr, hl.line, edit.log_lines("- Note taken on " .. now_inactive():to_string(), note))
  return true
end

return M
