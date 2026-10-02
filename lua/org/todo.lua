---@mod org.todo TODO state changes (org-todo)
---
--- Implements Emacs `org-todo` semantics: keyword cycling per sequence,
--- CLOSED timestamps, state-change logging (`!` / `@` flags, log_done,
--- #+STARTUP overrides), repeating tasks, TODO/checkbox dependencies and
--- clocking out when a task is done.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

--- The time a TODO state change records (org-current-effective-time):
--- with `yesterday`, 23:59 of the previous day, like Emacs
--- org-todo-yesterday (which binds org-use-effective-time and
--- org-extend-today-until); the last clock-out time of the subtree wins
--- with `use_last_clock_out_time_as_effective_time`.
---@param hl? org.Headline
---@param yesterday? boolean
---@return table time, table|nil today the day repeaters count from
local function change_time(hl, yesterday)
  if not yesterday then
    return date.effective_now(hl), nil
  end
  local now = date.now()
  local today = now:clone({ hour = vim.NIL, min = vim.NIL }):add(-1, "d")
  local t = config.opts.use_last_clock_out_time_as_effective_time and date.last_clock_out(hl)
  return t or today:clone({ hour = 23, min = 59 }), today
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

--- Format a state-change log entry header (Emacs style, from the `state`
--- entry of `log_note_headings`).
function M.state_log_header(new, old, ts)
  return "- " .. edit.log_heading("state", new or "", old or "", ts)
end

--- Log lines of a state change (nil when the heading and note are empty).
--- Without a previous keyword, `%S` is empty, like Emacs.
local function state_entry(new, old, note, time)
  local heading = edit.log_heading("state", new or "", old, time)
  if heading == "" and (not note or vim.trim(note) == "") then
    return nil
  end
  return edit.log_entry("state", note, new or "", old, time)
end

---------------------------------------------------------------------------
-- Remembered keyword sequence of a headline without keyword
---------------------------------------------------------------------------

local head_ns = vim.api.nvim_create_namespace("org.todo.head")
local heads = {}

--- Remember the keyword sequence of the headline at `lnum`, so that cycling
--- from the empty state returns to it (Emacs keeps it in the
--- `org-todo-head` text property).
local function remember_head(bufnr, lnum, head)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, head_ns, { lnum - 1, 0 }, { lnum - 1, -1 }, {})) do
    vim.api.nvim_buf_del_extmark(bufnr, head_ns, m[1])
  end
  if head then
    local id = vim.api.nvim_buf_set_extmark(bufnr, head_ns, lnum - 1, 0, {})
    heads[bufnr] = heads[bufnr] or {}
    heads[bufnr][id] = head
  end
end

local function recall_head(bufnr, lnum)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, head_ns, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
  local m = marks[#marks]
  return m and heads[bufnr] and heads[bufnr][m[1]] or nil
end

--- Fire a User autocmd with `data`.
local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
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
--- `todo_blockers` functions receive `change` ({ type = "todo-state-change",
--- from, to, bufnr, lnum }) and block by returning false (org-blocker-hook).
---@param hl org.Headline
---@param change? table
function M.blocked_reason(hl, change)
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
    -- an unchecked or partial checkbox outside blocks, after an optional
    -- counter cookie (org-block-todo-from-checkboxes)
    local lines = hl.file.lines
    local in_block = false
    for i = hl.line + 1, hl.body_end do
      local l = lines[i]
      if in_block then
        if l:match("^%s*#%+[eE][nN][dD]_") then
          in_block = false
        end
      elseif l:match("^%s*#%+[bB][eE][gG][iI][nN]_") then
        in_block = true
      else
        local rest = l:match("^%s*[-+]%s+(.*)$") or l:match("^%s+%*%s+(.*)$") or l:match("^%s*%d+[.)]%s+(.*)$")
        if rest then
          rest = rest:gsub("^%[@[^%]]*%]%s*", "")
          if rest:match("^%[[ %-]%]") then
            return "contained checkboxes"
          end
        end
      end
    end
  end
  return M.custom_blocked(hl, change)
end

--- Reason from the `todo_blockers` functions (org-blocker-hook), or nil.
---@param hl org.Headline
---@param change? table
function M.custom_blocked(hl, change)
  change = change or { type = "todo-state-change", from = hl.todo, to = "done", lnum = hl.line }
  for _, fn in ipairs(config.opts.todo_blockers or {}) do
    local ok, res = pcall(fn, change)
    if ok and res == false then
      return "a blocker function"
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

--- The state a change to `new` from `old` really goes to: the first
--- string returned by a `todo_get_default_hooks` function
--- (org-todo-get-default-hook), else `new`. "" means no keyword.
---@param new string|nil
---@param old string|nil
---@return string|nil
function M.default_state(new, old)
  for _, fn in ipairs(config.opts.todo_get_default_hooks or {}) do
    local ok, res = pcall(fn, new, old)
    if ok and type(res) == "string" then
      return res
    end
  end
  return new
end

--- The ancestors of `hl` whose TODO cookie org-update-parent-todo-statistics
--- updates: the parent, or with recursive statistics every ancestor up to
--- the one setting COOKIE_DATA (all of them when
--- `hierarchical_todo_statistics` is false, up to the one setting
--- COOKIE_DATA when there is one); one counting checkboxes stops the walk.
local function statistics_ancestors(hl)
  local parent = hl.parent
  if not parent then
    return {}
  end
  local recursive = config.opts.hierarchical_todo_statistics == false
  local limit = 0
  local h = parent
  while h do
    local data = h.properties.COOKIE_DATA
    if data then
      -- the inherited COOKIE_DATA bounds the walk (`lim` in
      -- org-update-parent-todo-statistics)
      recursive = recursive or data:lower():find("recursive") ~= nil
      limit = h.line
      break
    end
    h = h.parent
  end
  local out = {}
  h = parent
  while h and h.line >= limit do
    if (h.properties.COOKIE_DATA or ""):lower():find("checkbox") then
      break
    end
    out[#out + 1] = h.line
    if not recursive then
      break
    end
    h = h.parent
  end
  return out
end

--- Run the statistics hooks after the TODO state of `hl` changed:
--- `after_todo_statistics_hooks` (org-after-todo-statistics-hook) with the
--- numbers of done and not-done children for every ancestor with a
--- statistics cookie, then `todo_statistics_hooks`
--- (org-todo-statistics-hook), even when there is no cookie.
---@param bufnr integer
---@param hl org.Headline
function M.run_statistics_hooks(bufnr, hl)
  local cfg = config.opts
  local after = cfg.after_todo_statistics_hooks or {}
  local lnum = hl.line
  if #after > 0 then
    for _, l in ipairs(statistics_ancestors(hl)) do
      local file = files.get_buffer(bufnr)
      local cur = file:headline_on(l)
      if cur and (cur.raw:find("%[%d*%%%]") or cur.raw:find("%[%d*/%d*%]")) then
        local done, total = require("org.lists").todo_counts(file, cur)
        for _, fn in ipairs(after) do
          local ok, err = pcall(fn, done, total - done, { bufnr = bufnr, lnum = cur.line })
          if not ok then
            utils.warn("after_todo_statistics_hooks: " .. tostring(err))
          end
        end
      end
    end
  end
  for _, fn in ipairs(cfg.todo_statistics_hooks or {}) do
    local ok, err = pcall(fn, { bufnr = bufnr, lnum = lnum })
    if not ok then
      utils.warn("todo_statistics_hooks: " .. tostring(err))
    end
  end
end

local function update_parent_statistics(bufnr, hl)
  -- a parent counting checkboxes is left alone (org-update-parent-todo-statistics)
  if hl.parent and not (hl.parent.properties.COOKIE_DATA or ""):lower():find("checkbox") then
    local ok, lists = pcall(require, "org.lists")
    if ok and type(lists.update_statistics_for) == "function" then
      pcall(lists.update_statistics_for, bufnr, hl.parent.line)
    end
  end
  local file = files.get_buffer(bufnr)
  M.run_statistics_hooks(bufnr, file:headline_on(hl.line) or hl)
end

--- Shift every repeating timestamp of the entry (org-auto-repeat-maybe).
local function shift_repeaters(bufnr, hl, now, today)
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
      local nxt = date.apply_repeater(t.date, now, today)
      line = line:sub(1, t.start_col - 1) .. nxt:to_string() .. line:sub(t.end_col + 1)
    end
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line })
  end
  for _, kind in ipairs({ "deadline", "scheduled" }) do
    local ts = hl.planning[kind]
    if has_repeater(ts) then
      edit.set_planning(bufnr, hl.line, kind, date.apply_repeater(ts, now, today))
    elseif kind == "scheduled" and ts and not ts.repeater then
      -- a SCHEDULED date without repeater is no longer relevant
      edit.set_planning(bufnr, hl.line, kind, nil)
    end
  end
end

--- State a repeating entry returns to (org-auto-repeat-maybe): the
--- REPEAT_TO_STATE property, a string `todo_repeat_to_state`, the previous
--- state when `todo_repeat_to_state` is true, else the previous state in a
--- type sequence (`#+TYP_TODO`) and the first keyword of the previous
--- state's sequence otherwise.
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
  if kw and kw.seq_type == "type" then
    return old
  end
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

---@class org.TodoChangeOpts
---@field note? string note text (no prompt)
---@field force? boolean ignore blocking (C-u C-u C-u C-c C-t)
---@field no_log? boolean no logging at all
---@field force_note? boolean always ask for a note (C-u C-c C-t)
---@field inhibit_note? boolean record times instead of notes (C-0 C-c C-t)
---@field nextset? boolean a keyword set switch: nothing is logged
---@field inhibit_logging? boolean no CLOSED or state logging, but a repeat is still logged (org-inhibit-logging t)
---@field yesterday? boolean record the change as 23:59 of yesterday (org-todo-yesterday)

--- Change the TODO state of a headline with full org semantics.
---@param target? org.Target
---@param new string|nil new keyword (nil clears)
---@param opts? org.TodoChangeOpts
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
  new = M.default_state(new, old)
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
  local now_eff, today = change_time(hl, opts.yesterday)
  local now_inactive = now_eff:clone({ active = false })
  local old_done = todo_cfg:is_done(old)
  local new_done = todo_cfg:is_done(new)
  local becomes_done = new_done and not old_done

  local change = { type = "todo-state-change", from = old, to = new, bufnr = bufnr, lnum = lnum }
  if not opts.force and not hl.properties.NOBLOCKING then
    local reason
    if becomes_done then
      reason = M.blocked_reason(hl, change)
    else
      reason = M.custom_blocked(hl, change)
    end
    if reason then
      utils.warn(string.format("TODO state change from %s to %s blocked (by %s)", old or "", new or "", reason))
      return nil
    end
  end

  -- keyword flags, or the LOGGING property's keyword specs when it is set
  local loc = M.local_logging(hl)
  local new_kw, old_kw = todo_cfg:get(new), todo_cfg:get(old)
  if loc then
    new_kw, old_kw = loc.states[new or ""], loc.states[old or ""]
  end
  -- Emacs only looks at logging (and CLOSED) when some logging is set up
  local log_done = M.log_setting(file, "done", hl)
  local logging_active
  if opts.force_note then
    logging_active = true
  elseif opts.no_log or opts.nextset or opts.inhibit_logging then
    logging_active = false
  else
    local any_states
    if loc then
      any_states = next(loc.states) ~= nil
    else
      any_states = todo_cfg.has_log_flags
    end
    logging_active = any_states or log_done ~= false
  end
  local state_log = false
  if logging_active then
    state_log = (opts.force_note and "note") or (new_kw and new_kw.log_enter) or (old_kw and old_kw.log_leave) or false
    if state_log == "note" and opts.inhibit_note then
      state_log = "time"
    end
  else
    log_done = false
  end
  if opts.inhibit_note and log_done == "note" then
    log_done = "time"
  end
  local result = { old = old, new = new, bufnr = bufnr, lnum = lnum }

  if becomes_done and entry_repeats(hl) then
    -- repeating task: shift dates, return to a TODO state
    local log_repeat = (opts.no_log or opts.nextset) and false or M.log_setting(file, "repeat", hl)
    if opts.inhibit_note and log_repeat == "note" then
      log_repeat = "time"
    end
    -- the record org-todo already set up wins (org-log-setup): a state
    -- log, or the closing note of `log_done = "note"`
    local rep_log, purpose = log_repeat, "state"
    if state_log then
      rep_log = (state_log == "note" or log_repeat == "note") and "note" or "time"
    elseif log_done == "note" then
      rep_log, purpose = "note", "done"
    end
    local note = opts.note
    if rep_log == "note" and note == nil then
      note = utils.input_note({
        prompt = "Note for state change to " .. new .. ": ",
        purpose = edit.note_purpose(purpose, new, old),
      })
      -- a cancelled note (C-c C-k) logs nothing (org-note-abort)
      rep_log = note ~= nil and rep_log
    end
    local final = repeat_to_state(hl, todo_cfg, old)
    local has_clock = #hl.clocks > 0
    shift_repeaters(bufnr, hl, date.now(), today)
    trigger_tags(bufnr, lnum, todo_cfg, new)
    edit.update_headline(bufnr, lnum, { todo = final or false })
    if hl.planning.closed then
      edit.set_planning(bufnr, lnum, "closed", nil)
    end
    trigger_tags(bufnr, lnum, todo_cfg, final)
    if log_repeat or has_clock then
      edit.set_property(bufnr, lnum, "LAST_REPEAT", now_inactive:to_string())
    end
    if rep_log == "note" and purpose == "done" then
      edit.add_log_entry(bufnr, lnum, edit.log_entry("done", note, new, old, now_eff))
    elseif rep_log then
      edit.add_log_entry(bufnr, lnum, state_entry(new, old, note, now_eff))
    end
    result.new = final
    result.done_keyword = new
    result.repeated = true
  else
    local note = opts.note
    -- a closing note only when the state itself logs nothing (a `!` flag
    -- records the state change with its time, without a note)
    local wants_note = (new ~= nil and state_log == "note") or (becomes_done and log_done == "note" and not state_log)
    local aborted = false
    if wants_note and note == nil then
      note = utils.input_note({
        prompt = "Note for state change to " .. (new or "none") .. ": ",
        purpose = edit.note_purpose((new ~= nil and state_log) and "state" or "done", new, old),
      })
      -- a cancelled note (C-c C-k) logs nothing (org-note-abort)
      aborted = note == nil
    end
    edit.update_headline(bufnr, lnum, { todo = new or false })
    if logging_active then
      if becomes_done and log_done then
        -- org-log-done-with-time: `false` records the date only
        local closed = now_inactive
        if cfg.log_done_with_time == false then
          closed = closed:clone({ hour = vim.NIL, min = vim.NIL })
        end
        edit.set_planning(bufnr, lnum, "closed", closed)
      elseif
        hl.planning.closed
        and ((new == nil and not cfg.closed_keep_when_no_todo) or (todo_cfg:is_todo(new) and not todo_cfg:is_todo(old)))
      then
        edit.set_planning(bufnr, lnum, "closed", nil)
      end
    end
    trigger_tags(bufnr, lnum, todo_cfg, new)
    if new and state_log and not aborted then
      edit.add_log_entry(bufnr, lnum, state_entry(new, old, note, now_eff))
    elseif becomes_done and log_done == "note" and not aborted then
      edit.add_log_entry(bufnr, lnum, edit.log_entry("done", note, new, old, now_eff))
    end
  end
  -- the sequence a keyword-less headline returns to (org-todo-head)
  remember_head(bufnr, lnum, todo_cfg:sequence_head(old) or todo_cfg:sequence_head(new))

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
  if cfg.provide_todo_statistics ~= false then
    update_parent_statistics(bufnr, hl)
  end
  -- org-after-todo-state-change-hook / org-trigger-hook / org-todo-repeat-hook
  local data = {
    bufnr = bufnr,
    lnum = lnum,
    from = old,
    to = result.new,
    state = new,
    done = new_done,
    repeated = result.repeated or false,
  }
  if result.repeated then
    emit("OrgTodoRepeat", data)
  end
  emit("OrgTodoStateChange", data)
  return result
end

--- Run `fn(target)` on the headline at the cursor or, in Visual mode, on
--- every headline of the selection (org-loop-over-headlines-in-active-region).
local function for_targets(target, fn)
  if target == nil then
    local targets = edit.region_headlines()
    if targets then
      local last
      for _, t in ipairs(targets) do
        local l = t.lnum()
        if l then
          last = fn({ bufnr = t.bufnr, lnum = l })
        end
      end
      return last
    end
  end
  return fn(target)
end
M.for_targets = for_targets

--- <S-Right>/<S-Left>: walk every keyword of every set (org-todo 'right).
--- With `treat_S_cursor_todo_selection_as_state_change` false, the change
--- is neither logged nor blocked (org-inhibit-logging, org-inhibit-blocking).
local function shift(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local nxt = file.settings.todo:shift(hl.todo, dir)
  local opts
  if config.opts.treat_S_cursor_todo_selection_as_state_change == false then
    opts = { inhibit_logging = true, force = true }
  end
  return M.change_state({ bufnr = bufnr, lnum = hl.line }, nxt, opts)
end

function M.cycle_next(target)
  return shift(target, 1)
end

function M.cycle_prev(target)
  return shift(target, -1)
end

--- Switch to the next keyword sequence (C-S-right in Emacs). Nothing is
--- logged, like Emacs.
function M.next_sequence(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local todo_cfg = file.settings.todo
  local nxt = todo_cfg:next_sequence(hl.todo, dir or 1, not hl.todo and recall_head(bufnr, hl.line) or nil)
  local res = M.change_state({ bufnr = bufnr, lnum = hl.line }, nxt, { nextset = true })
  local kw = res and todo_cfg:get(nxt)
  if kw then
    local names = vim.tbl_map(function(k)
      return k.name
    end, todo_cfg.sequences[kw.seq])
    utils.notify(string.format("Keyword-Set %d/%d: %s", kw.seq, #todo_cfg.sequences, table.concat(names, " ")))
  end
  return res
end

--- Pick a keyword with the fast-selection menu (keys) or a list.
---@return string|nil keyword ("" for none), nil when cancelled
local function pick_keyword(todo_cfg, current)
  if todo_cfg.has_fast_keys then
    local items = {}
    for si, seq in ipairs(todo_cfg.sequences) do
      if #todo_cfg.sequences > 1 then
        items[#items + 1] = { heading = true, label = "Sequence " .. si }
      end
      for _, kw in ipairs(seq) do
        if kw.key then
          items[#items + 1] =
            { key = kw.key, label = kw.name .. (kw.name == current and "  (current)" or ""), value = kw.name }
        end
      end
    end
    items[#items + 1] = { key = " ", label = "(clear keyword)", value = "" }
    return require("org.ui").menu({ title = "TODO state", items = items })
  end
  local names = todo_cfg:names()
  names[#names + 1] = "(none)"
  local choice = utils.select(names, { prompt = "TODO state" })
  if choice == "(none)" then
    choice = ""
  end
  return choice
end

--- Pick a keyword (fast selection when keys are defined).
function M.select(target, opts)
  return for_targets(target, function(t)
    local bufnr, file, hl = edit.resolve_headline(t)
    if not bufnr then
      return nil
    end
    local choice = pick_keyword(file.settings.todo, hl.todo)
    if choice == nil then
      return nil
    end
    return M.change_state({ bufnr = bufnr, lnum = hl.line }, choice ~= "" and choice or nil, opts)
  end)
end

--- The last `C-c C-t`: buffer, headline, changedtick and (at the cursor)
--- cursor position right after it. A new one with all of them unchanged
--- is a repetition (Emacs `(eq this-command last-command)`).
local last_todo

local function todo_repeated(bufnr, lnum, at_cursor)
  local l = last_todo
  return l ~= nil
    and l.bufnr == bufnr
    and l.lnum == lnum
    and vim.api.nvim_buf_is_valid(bufnr)
    and l.tick == vim.api.nvim_buf_get_changedtick(bufnr)
    and (not at_cursor or vim.deep_equal(l.cursor, vim.api.nvim_win_get_cursor(0)))
end

local function todo_record(bufnr, lnum, at_cursor)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    last_todo = nil
    return
  end
  last_todo = {
    bufnr = bufnr,
    lnum = lnum,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    cursor = at_cursor and vim.api.nvim_win_get_cursor(0) or nil,
  }
end

--- The state change of one `C-c C-t`; `repeated` when it follows another.
local function todo_step(target, arg, opts, repeated)
  opts = vim.deepcopy(opts or {})
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local tgt = { bufnr = bufnr, lnum = hl.line }
  local todo_cfg = file.settings.todo
  if arg == 4 then
    opts.force_note = true
  elseif arg == 16 then
    return M.next_sequence(tgt, 1)
  elseif arg == 64 then
    opts.force = true
  elseif arg and arg > 0 then
    local names = todo_cfg:names()
    if names[arg] then
      return M.change_state(tgt, names[arg], opts)
    end
    return nil
  end
  if todo_cfg.has_fast_keys and config.opts.use_fast_todo_selection ~= false then
    return M.select(tgt, opts)
  end
  local nxt = todo_cfg:cycle(hl.todo, 1, not hl.todo and recall_head(bufnr, hl.line) or nil, repeated)
  return M.change_state(tgt, nxt, opts)
end

--- One `C-c C-t` on a headline; `arg` is the Emacs prefix argument.
local function todo_command(target, arg, opts)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local lnum = hl.line
  local repeated = todo_repeated(bufnr, lnum, target == nil)
  local res = todo_step(target, arg, opts, repeated)
  todo_record(bufnr, lnum, target == nil)
  return res
end

--- Emacs `C-c C-t` (org-todo with org-use-fast-todo-selection = auto):
--- fast selection when keywords define keys, otherwise cycle to the next
--- state (from no keyword: the sequence the headline was last in). A count
--- is the prefix argument: 4 (C-u) forces a note, 16 (C-u C-u) switches to
--- the next keyword set, 64 (C-u C-u C-u) ignores blocking, any other N
--- picks the Nth keyword. In Visual mode, every headline of the selection
--- changes.
---@param target? org.Target
---@param arg? integer prefix argument (default: `vim.v.count` when interactive)
---@param opts? org.TodoChangeOpts
function M.select_or_cycle(target, arg, opts)
  if arg == nil and target == nil and vim.v.count > 0 then
    arg = vim.v.count
  end
  return for_targets(target, function(t)
    return todo_command(t, arg, opts)
  end)
end

--- org-todo-yesterday: like `select_or_cycle` (C-c C-t, with the same
--- prefix argument), but the change is recorded as 23:59 of yesterday
--- (CLOSED, log notes, LAST_REPEAT) and `.+`/`++` repeaters count from
--- yesterday. The agenda's org-agenda-todo-yesterday uses it too.
---@param target? org.Target
---@param arg? integer prefix argument, as for `select_or_cycle`
---@param opts? org.TodoChangeOpts
function M.todo_yesterday(target, arg, opts)
  opts = vim.tbl_extend("force", opts or {}, { yesterday = true })
  return M.select_or_cycle(target, arg, opts)
end

--- `C-0 C-c C-t`: change the state without taking a note (notes become
--- timestamps).
function M.todo_without_note(target)
  return M.select_or_cycle(target, nil, { inhibit_note = true })
end

--- Set every repeater of the entry to 0 (org-cancel-repeaters).
function M.cancel_repeaters(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.body_end, false)
  local changed = false
  for i, line in ipairs(lines) do
    local new = line:gsub("([<%[]%d%d%d%d%-%d%d?%-%d%d?[^<>%[%]\n]-)([>%]])", function(body, close)
      return (body:gsub("(%s[%.%+]?%+)(%d+)([hdwmy])", "%10%3")) .. close
    end)
    if new ~= line then
      lines[i] = new
      changed = true
    end
  end
  if changed then
    vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.body_end, false, lines)
  end
  return changed
end

--- `C-- 1 C-c C-t`: cancel the entry's repeaters (org-cancel-repeaters),
--- then change the state, so that a repeating task can be marked done for
--- good.
function M.todo_cancel_repeaters(target)
  return for_targets(target, function(t)
    local bufnr, _, hl = edit.resolve_headline(t)
    if not bufnr then
      return nil
    end
    M.cancel_repeaters({ bufnr = bufnr, lnum = hl.line })
    return todo_command({ bufnr = bufnr, lnum = hl.line }, nil)
  end)
end

--- Add a note to the entry (org-add-note).
function M.add_note(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local time = date.effective_now(hl)
  local note = utils.input_note({ prompt = "Note: ", purpose = edit.note_purpose("note") })
  if not note or vim.trim(note) == "" then
    return nil
  end
  edit.add_log_entry(bufnr, hl.line, edit.log_entry("note", note, nil, nil, time))
  return true
end

return M
