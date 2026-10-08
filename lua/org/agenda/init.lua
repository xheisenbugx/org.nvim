---@mod org.agenda Agenda dispatcher and views
---
--- Views are lists of blocks:
---   { type = "agenda", span = "week", start_day = "-3d" }
---   { type = "todo", keywords = { "TODO", "NEXT" } }     (or match = "TODO|NEXT")
---   { type = "tags", match = "+work-boss" }
---   { type = "tags_todo", match = "+work" }
---   { type = "search", match = "foo +bar" }
---   { type = "stuck" }
--- Every block accepts `header`, `files`, `skip = function(headline)`,
--- `filter = function(item)`, `sorting` and the `todo_ignore_*` / `skip_*` agenda options.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local function view_mod()
  require("org.agenda.highlights").setup()
  return require("org.agenda.view")
end

local TYPE_ALIASES = {
  ["tags-todo"] = "tags_todo",
  alltodo = "todo",
  ["stuck-projects"] = "stuck",
  stuck_projects = "stuck",
  ["tags-tree"] = "tags_tree",
  ["todo-tree"] = "todo_tree",
  ["occur-tree"] = "occur_tree",
}

--- Custom command types that build a sparse tree in the current org
--- buffer instead of an agenda view.
local SPARSE_TYPES = { tags_tree = true, todo_tree = true, occur_tree = true }
M.SPARSE_TYPES = SPARSE_TYPES

--- Emacs option names (`org_agenda_<name>`) whose plugin block key differs.
local OPTION_ALIASES = {
  org_agenda_overriding_header = "header",
  org_agenda_skip_function = "skip",
  org_agenda_sorting_strategy = "sorting",
  org_agenda_files = "files",
  org_stuck_projects = "stuck_projects",
  org_deadline_warning_days = "deadline_warning_days",
  org_scheduled_delay_days = "scheduled_delay_days",
  org_agenda_tag_filter_preset = "tag_filter_preset",
  org_agenda_category_filter_preset = "category_filter_preset",
  org_agenda_regexp_filter_preset = "regexp_filter_preset",
  org_agenda_effort_filter_preset = "effort_filter_preset",
  org_overriding_columns_format = "overriding_columns_format",
}

--- Add the plugin names of the Emacs-style option names in `out`
--- (org_agenda_span -> span, ...), unless `out` sets them too.
local function alias_options(out)
  for k, v in pairs(vim.deepcopy(out)) do
    if type(k) == "string" then
      local key = OPTION_ALIASES[k] or k:match("^org_agenda_(.+)$")
      if key and out[key] == nil then
        out[key] = v
      end
    end
  end
  return out
end

--- Normalize a block spec (accepts Emacs-style option names). `settings`
--- (the options of a composite command, Emacs's third element) apply to
--- the block unless it sets the same option itself.
---@param b table
---@param settings? table
function M.normalize_block(b, settings)
  local out = vim.deepcopy(settings or {})
  for k, v in pairs(b) do
    out[k] = type(v) == "table" and vim.deepcopy(v) or v
  end
  -- Emacs-style names: org_agenda_span -> span, ...
  alias_options(out)
  out.type = TYPE_ALIASES[out.type] or out.type or "agenda"
  -- functions are not deep-copied reliably; take them from the sources
  out.skip = b.skip or b.org_agenda_skip_function or (settings or {}).skip or (settings or {}).org_agenda_skip_function
  if out.type == "todo" and not out.keywords and out.match and out.match ~= "" then
    out.keywords = vim.split(out.match, "[|%s]+", { trimempty = true })
  end
  return out
end

--- The `settings` of a custom command (Emacs's options list).
local function command_settings(cmd)
  return cmd.settings or cmd.options
end

--- Run a sparse-tree custom command (tags-tree, todo-tree, occur-tree)
--- in the current org buffer.
---@param block table normalized block
function M.sparse_command(block)
  local buf = vim.api.nvim_get_current_buf()
  if not utils.is_org(buf) then
    local ft = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or "fundamental"
    utils.error("Cannot execute Org agenda command on buffer in " .. ft .. " mode")
    return nil
  end
  local sparse = require("org.agenda.sparse")
  local match = block.match or ""
  if block.type == "tags_tree" then
    return sparse.match(match, block.todo_only)
  elseif block.type == "todo_tree" then
    if match == "" then
      return sparse.headlines(function(hl)
        return hl:is_todo()
      end, "TODO")
    end
    return sparse.headlines(function(hl)
      return hl.raw:match("^%*+%s+" .. vim.pesc(match) .. "%f[^%w_]") ~= nil
    end, match)
  else
    local search = require("org.agenda.search")
    local ok, re = pcall(search.emacs_regexp, match)
    return sparse.regexp(ok and re or match)
  end
end

---------------------------------------------------------------------------
-- Skip functions (org-agenda-skip-entry-if / org-agenda-skip-subtree-if)
---------------------------------------------------------------------------

local ARG_CONDITIONS = { regexp = true, notregexp = true, todo = true, nottodo = true }

local function parse_conditions(...)
  local args = { ... }
  local conds = {}
  local i = 1
  while i <= #args do
    local c = args[i]
    if ARG_CONDITIONS[c] then
      conds[#conds + 1] = { c, args[i + 1] }
      i = i + 2
    else
      conds[#conds + 1] = { c }
      i = i + 1
    end
  end
  return conds
end

local function todo_matches(hl, spec)
  if spec == "todo" then
    return hl:is_todo()
  elseif spec == "done" then
    return hl:is_done()
  elseif spec == "any" then
    return hl.todo ~= nil
  end
  spec = type(spec) == "string" and { spec } or spec or {}
  return hl.todo ~= nil and vim.tbl_contains(spec, hl.todo)
end

-- org-scheduled-time-regexp / org-deadline-time-regexp / org-ts-regexp
-- only match active timestamps
local function has_scheduled(hl)
  local s = hl.planning.scheduled
  return s ~= nil and s.active == true
end

local function has_deadline(hl)
  local d = hl.planning.deadline
  return d ~= nil and d.active == true
end

local function has_timestamp(hl)
  return has_scheduled(hl) or has_deadline(hl) or #hl.timestamps > 0
end

--- The headline, and with `subtree` every headline below it: like
--- org-agenda-skip-if, a subtree condition searches the whole subtree.
local function scope(hl, subtree)
  if not subtree then
    return { hl }
  end
  local out = { hl }
  local hls = hl.file.headlines
  local i = (hl.index or 0) + 1
  while hls[i] and hls[i].line <= hl.end_line do
    out[#out + 1] = hls[i]
    i = i + 1
  end
  return out
end

local function any_in(hls, pred, arg)
  for _, h in ipairs(hls) do
    if pred(h, arg) then
      return true
    end
  end
  return false
end

local function condition_holds(hl, cond, subtree)
  local c, arg = cond[1], cond[2]
  if c == "regexp" or c == "notregexp" then
    local ok, re = pcall(vim.regex, arg or "")
    if not ok then
      return false
    end
    local last = subtree and hl.end_line or hl.body_end
    local found = false
    for i = hl.line, last do
      if re:match_str(hl.file.lines[i] or "") then
        found = true
        break
      end
    end
    return found == (c == "regexp")
  end
  local hls = scope(hl, subtree)
  if c == "scheduled" or c == "notscheduled" then
    return any_in(hls, has_scheduled) == (c == "scheduled")
  elseif c == "deadline" or c == "notdeadline" then
    return any_in(hls, has_deadline) == (c == "deadline")
  elseif c == "timestamp" or c == "nottimestamp" then
    return any_in(hls, has_timestamp) == (c == "timestamp")
  elseif c == "todo" then
    return any_in(hls, todo_matches, arg)
  elseif c == "nottodo" then
    return not any_in(hls, todo_matches, arg)
  end
  error("unknown skip condition: " .. tostring(c))
end

--- A `skip` function skipping entries for which any condition holds:
--- "scheduled", "notscheduled", "deadline", "notdeadline", "timestamp",
--- "nottimestamp", "regexp" RE, "notregexp" RE, "todo" KWS, "nottodo" KWS
--- (KWS: a list of keywords, or "todo", "done" or "any").
---
--- ```lua
--- skip = require("org.agenda").skip_entry_if("scheduled", "deadline")
--- skip = require("org.agenda").skip_entry_if("todo", { "WAITING" }, "regexp", "@home")
--- ```
---@param ... string|string[] conditions, each followed by its argument where it takes one
---@return fun(hl: org.Headline): boolean skip predicate for a block's `skip` option
function M.skip_entry_if(...)
  local conds = parse_conditions(...)
  return function(hl)
    for _, c in ipairs(conds) do
      if condition_holds(hl, c, false) then
        return true
      end
    end
    return false
  end
end

--- Like `skip_entry_if`, but every condition looks at the whole subtree,
--- and when one holds the entry is skipped with its subtree
--- (org-agenda-skip-subtree-if). As in Emacs, it is asked about the
--- entries the view matches (TODO entries in a TODO list, matching ones in
--- a tags view, ...), so a heading the view would not list never hides
--- what is below it.
---
--- ```lua
--- skip = require("org.agenda").skip_subtree_if("regexp", ":someday:")
--- ```
---@param ... string|string[] conditions, as for `skip_entry_if`
---@return fun(hl: org.Headline): boolean skip predicate for a block's `skip` option
function M.skip_subtree_if(...)
  local conds = parse_conditions(...)
  local function skip(hl)
    for _, c in ipairs(conds) do
      if condition_holds(hl, c, true) then
        return true
      end
    end
    return false
  end
  require("org.agenda.items").subtree_skips[skip] = true
  return skip
end

---------------------------------------------------------------------------
-- Restriction lock (org-agenda-set-restriction-lock)
---------------------------------------------------------------------------

--- `{ bufnr, filename, line?, raw? }`: agenda commands are restricted to
--- this file, or to the subtree of the headline `raw` near `line`.
M.lock = nil

--- The restriction described by the lock, with the subtree range
--- recomputed from the current buffer contents.
function M.lock_restriction()
  local l = M.lock
  if not l then
    return nil
  end
  if not (l.bufnr and vim.api.nvim_buf_is_valid(l.bufnr)) then
    return l.filename and { filename = l.filename } or nil
  end
  local r = { bufnr = l.bufnr, filename = l.filename }
  if l.raw then
    local file = require("org.files").get_buffer(l.bufnr)
    local hl = file:headline_at(l.line)
    if not (hl and hl.raw == l.raw) then
      hl = file:find_headline(function(h)
        return h.raw == l.raw
      end)
    end
    if not hl then
      utils.warn("The restriction lock's subtree is gone; lock removed")
      M.lock = nil
      return nil
    end
    r.range = { hl.line, hl.end_line }
  end
  return r
end

--- Lock the agenda to the current subtree, or to the file when not under
--- a headline or with `whole_file` (C-c C-x <).
---@param target? { bufnr?: integer, lnum?: integer, whole_file?: boolean }
function M.set_restriction_lock(target)
  target = target or {}
  local bufnr = target.bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_org(bufnr) then
    utils.warn("Not in an org buffer")
    return false
  end
  local file = require("org.files").get_buffer(bufnr)
  local lnum = target.lnum
  if not lnum then
    lnum = bufnr == vim.api.nvim_get_current_buf() and vim.api.nvim_win_get_cursor(0)[1] or 1
  end
  local hl = not target.whole_file and file:headline_at(lnum) or nil
  if not target.whole_file and vim.v.count > 0 then
    hl = nil
  end
  M.lock = { bufnr = bufnr, filename = file.filename, line = hl and hl.line, raw = hl and hl.raw }
  M.highlight_lock(bufnr, hl)
  local name = vim.fn.fnamemodify(file.filename or "buffer", ":t")
  utils.notify(
    hl and ('Agenda restricted to subtree "' .. hl:plain_title() .. '"') or ("Agenda restricted to " .. name)
  )
  return true
end

local ns_lock = vim.api.nvim_create_namespace("org.agenda.lock")

--- Highlight the locked subtree, or only its headline without
--- `agenda.restriction_lock_highlight_subtree`, with
--- OrgAgendaRestrictionLock (org-agenda-restriction-lock-overlay); nil
--- `hl` (a file lock) only clears the highlight.
function M.highlight_lock(bufnr, hl)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_clear_namespace(b, ns_lock, 0, -1)
    end
  end
  if not (hl and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_set_hl(0, "OrgAgendaRestrictionLock", { link = "Visual", default = true })
  local last = config.opts.agenda.restriction_lock_highlight_subtree ~= false and hl.end_line or hl.line
  local last_text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_lock, hl.line - 1, 0, {
    end_row = last - 1,
    end_col = #last_text,
    hl_group = "OrgAgendaRestrictionLock",
    hl_eol = true,
    priority = 50,
  })
end

--- Remove the restriction lock (C-c C-x >).
function M.remove_restriction_lock()
  if not M.lock then
    utils.notify("No agenda restriction lock")
    return
  end
  M.highlight_lock(nil, nil)
  M.lock = nil
  utils.notify("Agenda restriction lock removed")
end

---------------------------------------------------------------------------
-- Agenda files
---------------------------------------------------------------------------

--- Visit the agenda file after the current one (org-cycle-agenda-files).
function M.cycle_files()
  local paths = require("org.files").agenda_file_paths()
  if #paths == 0 then
    utils.warn("No agenda files")
    return
  end
  local function real(p)
    return utils.realpath(p) or vim.fs.normalize(p)
  end
  local name = vim.api.nvim_buf_get_name(0)
  local cur = name ~= "" and real(name) or nil
  local next_path = paths[1]
  for i, p in ipairs(paths) do
    if real(p) == cur then
      next_path = paths[i % #paths + 1]
      break
    end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(next_path))
end

--- Search a regexp in all agenda files and show the matches in the
--- quickfix list (org-occur-in-agenda-files).
---@param pattern string Vim regexp
---@return integer number of matches
function M.occur(pattern)
  local ok, re = pcall(vim.regex, pattern)
  if not ok then
    utils.error("Invalid regexp: " .. pattern)
    return 0
  end
  local qf = {}
  -- with agenda.text_search_extra_files (org-agenda-multi-occur-extra-files)
  local list = require("org.files").agenda_files()
  list = view_mod().add_extra_files(list, config.opts.agenda.text_search_extra_files)
  for _, f in ipairs(list) do
    for i, line in ipairs(f.lines) do
      local s = re:match_str(line)
      if s then
        qf[#qf + 1] = { filename = f.filename, lnum = i, col = s + 1, text = line }
      end
    end
  end
  vim.fn.setqflist({}, " ", { title = "Occur in agenda files: " .. pattern, items = qf })
  if #qf == 0 then
    utils.notify("No match for " .. pattern)
  else
    vim.cmd("copen")
  end
  return #qf
end

--- Ask about agenda files that do not exist (org-check-agenda-file):
--- [R]emove from the list (for this session) or [A]bort. With
--- `agenda.skip_unavailable_files` they are skipped silently. Globs and
--- directories are never missing. Returns false on abort.
function M.check_agenda_files()
  local cfg = config.opts
  if cfg.agenda.skip_unavailable_files then
    return true
  end
  local list = cfg.agenda_files
  if type(list) ~= "table" then
    return true
  end
  local files = require("org.files")
  for i = #list, 1, -1 do
    local p = list[i]
    if type(p) == "string" and not p:find("[%*%?%[]") then
      local path = vim.fs.normalize(utils.expand(p))
      if not vim.uv.fs_stat(path) then
        local ch = utils.getchar(
          string.format("Non-existent agenda file %s.  [R]emove from list or [A]bort?", utils.abbreviate(path))
        )
        if ch and ch:lower() == "r" then
          -- org-remove-file: the new list is saved (org-store-new-agenda-file-list)
          table.remove(list, i)
          files.store_agenda_file_list(list)
          utils.notify("Removed from Org Agenda list: " .. utils.abbreviate(path))
        else
          utils.error("Abort")
          return false
        end
      end
    end
  end
  return true
end

--- Open a view: `{ blocks = {...} }` or a single block `{ type = ... }`.
--- A view with `blocks`/`types` is a composite (block) agenda; its
--- `settings` apply to every block. Sparse-tree types (tags_tree,
--- todo_tree, occur_tree) act on the current org buffer instead.
---@param spec table
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table }
function M.open(spec, opts)
  opts = opts or {}
  if not opts.restrict and M.lock then
    opts = vim.tbl_extend("force", opts, { restrict = M.lock_restriction() })
  end
  local blocks
  local multi = false
  if spec.blocks or spec.types then
    blocks = spec.blocks or spec.types
    multi = true
  else
    blocks = { spec }
  end
  local settings = command_settings(spec)
  local view = { title = spec.description or spec.title, blocks = {}, multi = multi, key = spec.key }
  -- the command's settings, for what Emacs reads once per agenda
  -- (org-agenda-finalize, org-agenda-mode) under the command's let-bound
  -- options: the column view, the start_with_* modes, dim_blocked_tasks
  view.settings = settings and alias_options(vim.deepcopy(settings)) or nil
  for _, b in ipairs(blocks) do
    local nb = M.normalize_block(b, multi and settings or nil)
    if not multi and settings then
      nb = M.normalize_block(nb, settings)
    end
    nb.settings, nb.options = nil, nil
    if SPARSE_TYPES[nb.type] then
      if multi then
        utils.error("Sparse tree commands cannot be part of a block agenda")
        return
      end
      return M.sparse_command(nb)
    end
    view.blocks[#view.blocks + 1] = nb
  end
  if not opts.restrict and not M.check_agenda_files() then
    return
  end
  view_mod().open(view, opts)
end

--- Date agenda.
---@param opts? { span?: string|integer, anchor?: integer, restrict?: table }
function M.open_agenda(opts)
  opts = opts or {}
  M.open({ type = "agenda" }, { span = opts.span, anchor = opts.anchor, restrict = opts.restrict })
end

--- Day agenda for `d` (a date object or day number).
function M.open_day(d)
  local days = type(d) == "number" and d or d:days()
  M.open_agenda({ span = "day", anchor = days })
end

function M.open_todo(keywords, restrict)
  M.open({ type = "todo", keywords = keywords }, { restrict = restrict })
end

function M.open_tags(match, todo_only, restrict)
  local pred, err = require("org.agenda.search").try_compile(match)
  if not pred then
    utils.error("Invalid match: " .. tostring(err))
    return
  end
  M.open({ type = todo_only and "tags_todo" or "tags", match = match }, { restrict = restrict })
end

---@param todo_only? boolean only TODO entries (C-c a S)
function M.open_search(text, restrict, todo_only)
  M.open({ type = "search", match = text, todo_only = todo_only or nil }, { restrict = restrict })
end

function M.open_stuck(restrict)
  M.open({ type = "stuck" }, { restrict = restrict })
end

local function all_tags()
  local set = {}
  for _, f in ipairs(require("org.files").agenda_files()) do
    for _, t in ipairs(f.settings.filetags) do
      set[t] = true
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        set[t] = true
      end
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- Prompt for a match string with tag completion.
local function ask_match(prompt)
  return utils.input_complete(prompt, function()
    local list = all_tags()
    local props = { "LEVEL", "TODO", "PRIORITY", "CATEGORY", "SCHEDULED", "DEADLINE", "CLOSED", "Effort" }
    vim.list_extend(list, props)
    return list
  end)
end

---------------------------------------------------------------------------
-- Custom command contexts (org-agenda-custom-commands-contexts)
---------------------------------------------------------------------------

local function rx_match(str, re)
  return str ~= nil and str ~= "" and vim.fn.match(str, re) >= 0
end

--- Does a context rule hold in the current buffer
--- (org-contextualize-validate-key)?
local function rule_ok(rule)
  if type(rule) == "function" then
    return rule() and true or false
  elseif type(rule) ~= "table" then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local file = (name ~= "" and vim.bo[bufnr].buftype == "") and name or nil
  local mode = vim.bo[bufnr].filetype
  local bname = name ~= "" and vim.fn.fnamemodify(name, ":t") or ""
  return (rule.in_file and file and rx_match(file, rule.in_file))
    or (rule.in_mode and rx_match(mode, rule.in_mode))
    or (rule.in_buffer and rx_match(bname, rule.in_buffer))
    or (rule.not_in_file and file and not rx_match(file, rule.not_in_file))
    or (rule.not_in_mode and not rx_match(mode, rule.not_in_mode))
    or (rule.not_in_buffer and not rx_match(bname, rule.not_in_buffer))
    or false
end

--- The custom commands offered in the current buffer: `custom_commands`
--- filtered and remapped by `agenda.custom_commands_contexts`
--- (org-contextualize-keys). A rule list `{ key, rules }` keeps `key`
--- only where a rule holds; `{ key, other, rules }` runs the command of
--- `other` under `key` there (and hides `other`).
---@return table<string, table|string>
function M.custom_commands()
  local cmds = config.opts.agenda.custom_commands or {}
  local contexts = {}
  for _, c in ipairs(config.opts.agenda.custom_commands_contexts or {}) do
    local key, repl, rules = c[1], c[2], c[3]
    if type(repl) ~= "string" or repl == "" then
      rules, repl = type(repl) == "string" and c[3] or c[2], key
    end
    if type(rules) == "function" or (type(rules) == "table" and not vim.islist(rules)) then
      rules = { rules }
    end
    contexts[#contexts + 1] = { key = key, repl = repl, rules = rules or {} }
  end
  if #contexts == 0 then
    return cmds
  end
  local out, hidden = {}, {}
  for key, cmd in pairs(cmds) do
    local mine = vim.tbl_filter(function(c)
      return c.key == key
    end, contexts)
    if #mine == 0 then
      out[key] = cmd
    else
      local valid, repl = false, nil
      for _, c in ipairs(mine) do
        for _, r in ipairs(c.rules) do
          if rule_ok(r) then
            valid = true
            if c.repl ~= c.key then
              repl = c.repl
            end
          end
        end
      end
      if valid and not repl then
        out[key] = cmd
      elseif valid then
        if cmds[repl] == nil then
          error(string.format("Undefined key `%s' as contextual replacement for `%s'", repl, key), 0)
        end
        out[key] = cmds[repl]
        hidden[repl] = true
      end
    end
  end
  for k in pairs(hidden) do
    out[k] = nil
  end
  return out
end

local function open_custom(key, restrict)
  local cmd = M.custom_commands()[key]
  if type(cmd) ~= "table" or not (cmd.types or cmd.blocks or cmd.type) then
    utils.error("No agenda custom command for key: " .. key)
    return
  end
  if cmd.type then
    -- a single block: not a composite agenda
    local block = vim.tbl_extend("force", {}, cmd)
    block.settings, block.options = nil, nil
    local s = command_settings(cmd)
    local nb = M.normalize_block(block, s)
    nb.description = cmd.description
    nb.key = key
    nb.settings = s
    M.open(nb, { restrict = restrict })
    return
  end
  M.open(vim.tbl_extend("force", cmd, { key = key }), { restrict = restrict })
end
M.open_custom = open_custom

--- Toggle sticky agenda buffers (the `*` dispatcher key).
function M.toggle_sticky()
  local acfg = config.opts.agenda
  -- org-toggle-sticky-agenda kills the agenda buffers first
  view_mod().kill_all_agenda_buffers()
  acfg.sticky = not acfg.sticky
  utils.notify("Sticky agenda buffers are now " .. (acfg.sticky and "on" or "off"))
  return acfg.sticky
end

--- Dispatch a dispatcher key.
function M.dispatch(key, restrict)
  if type(key) == "table" and key.custom then
    return open_custom(key.custom, restrict)
  end
  if key == "a" then
    M.open_agenda({ restrict = restrict })
  elseif key == "t" then
    M.open_todo(nil, restrict)
  elseif key == "T" then
    local names = require("org.agenda.view").todo_names()
    local kw = utils.input_complete("TODO keyword(s) (KW|KW2): ", names)
    if not kw or kw == "" then
      return
    end
    M.open_todo(vim.split(kw, "[|%s]+", { trimempty = true }), restrict)
  elseif key == "m" or key == "M" then
    local match = ask_match(key == "m" and "Match: " or "Match (TODO only): ")
    if not match then
      return
    end
    M.open_tags(match, key == "M", restrict)
  elseif key == "s" or key == "S" then
    local text = utils.input({ prompt = "Search (words, +word -word {regexp}): " })
    if not text or text == "" then
      return
    end
    M.open_search(text, restrict, key == "S")
  elseif key == "#" then
    M.open_stuck(restrict)
  elseif key == "n" then
    M.open({ key = "n", description = "Agenda and all TODOs", blocks = { { type = "agenda" }, { type = "todo" } } }, {
      restrict = restrict,
    })
  elseif key == "/" then
    local re = utils.input({ prompt = "Occur in agenda files (regexp): " })
    if re and re ~= "" then
      M.occur(re)
    end
  elseif key == "e" then
    return require("org.agenda.export").store_views()
  elseif key == "?" then
    -- the FLAGGED entries of MobileOrg
    return require("org.mobile").flagged_agenda()
  elseif key == "*" then
    return M.toggle_sticky()
  elseif key == ">" then
    if M.lock then
      M.remove_restriction_lock()
    end
  end
end

local DEFAULT_DESCRIPTIONS = {
  agenda = "Agenda for current week or day",
  todo = "List of all TODO entries",
  search = "Word search",
  stuck = "List of stuck projects",
  tags = "Tags query",
  tags_todo = "Tags (TODO)",
  tags_tree = "Tags tree",
  todo_tree = "TODO kwd tree",
  occur_tree = "Occur tree",
}

--- The dispatcher line of a custom command: its description (or one for
--- its type) and, with `agenda.menu_show_matcher`, ": MATCH"
--- (org-agenda-get-restriction-and-command).
function M.menu_label(cmd)
  local label = cmd.description
  if not (label and label:match("%S")) then
    local t = cmd.type and (TYPE_ALIASES[cmd.type] or cmd.type)
    if t == "todo" and cmd.match and cmd.match ~= "" then
      label = "TODO keyword"
    else
      label = t and DEFAULT_DESCRIPTIONS[t] or "???"
    end
  end
  local match = cmd.type and cmd.match
  if config.opts.agenda.menu_show_matcher ~= false and type(match) == "string" and match:match("%S") then
    label = label .. ": " .. match
  end
  return label
end

--- The agenda dispatcher (C-c a): a menu of the built-in views and
--- `agenda.custom_commands`. Must run inside a coroutine; call
--- `require("org").agenda()` from mappings instead.
function M.prompt()
  local restrict = nil
  local buf = vim.api.nvim_get_current_buf()
  local is_org = utils.is_org(buf)
  local cur_hl
  if is_org then
    cur_hl = require("org.files").get_buffer(buf):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  end
  local custom = M.custom_commands()
  while true do
    local rstate = M.lock and "lock" or "none"
    if restrict then
      rstate = restrict.range and "subtree" or "buffer"
    end
    local builtin = {
      { key = "a", label = "Agenda for current week or day", value = "a" },
      { key = "t", label = "List of all TODO entries", value = "t" },
      { key = "T", label = "Entries with special TODO keyword", value = "T" },
      { key = "m", label = "Match a TAGS/PROP/TODO query", value = "m" },
      { key = "M", label = "Like m, but only TODO entries", value = "M" },
      { key = "s", label = "Search for keywords", value = "s" },
      { key = "S", label = "Like s, but only TODO entries", value = "S" },
      { key = "n", label = "Agenda and all TODOs", value = "n" },
      { key = "#", label = "List stuck projects", value = "#" },
      { key = "/", label = "Multi-occur in agenda files", value = "/" },
      { key = "e", label = "Export agenda views", value = "e" },
      { key = "?", label = "Find :FLAGGED: entries", value = "?" },
      { heading = true, label = "Options" },
      {
        key = "*",
        label = "Sticky agenda views",
        state = config.opts.agenda.sticky and "on" or "off",
        value = "__sticky",
      },
    }
    local items = {}
    for _, it in ipairs(builtin) do
      if not custom[it.key] then
        items[#items + 1] = it
      end
    end
    if is_org then
      items[#items + 1] = { key = "<", label = "Restrict to buffer / subtree", state = rstate, value = "__restrict" }
    end
    if restrict or M.lock then
      items[#items + 1] = { key = ">", label = "Remove restriction", value = "__unrestrict" }
    end
    local entries = {}
    for key, cmd in pairs(custom) do
      if type(cmd) == "string" then
        entries[#entries + 1] = { key = key, label = cmd }
      elseif type(cmd) == "table" and not (cmd.types or cmd.blocks or cmd.type) then
        entries[#entries + 1] = { key = key, label = cmd.description or key }
      elseif type(cmd) == "table" then
        entries[#entries + 1] = { key = key, label = M.menu_label(cmd), value = { custom = key } }
      end
    end
    if #entries > 0 then
      items[#items + 1] = { heading = true, label = "" }
      items[#items + 1] = { heading = true, label = "Custom commands" }
      local tree = require("org.ui").tree_from_keys(entries)
      if config.opts.agenda.menu_two_columns then
        -- org-agenda-menu-two-columns: the first half on the left
        local n1 = math.ceil(#tree / 2)
        for i = 1, n1 do
          items[#items + 1] = tree[i]
          if tree[i + n1] then
            items[#items + 1] = vim.tbl_extend("force", tree[i + n1], { column = 2 })
          end
        end
      else
        vim.list_extend(items, tree)
      end
    end
    local choice = require("org.ui").menu({ title = "Org Agenda", items = items })
    if choice == nil then
      return
    end
    if choice == "__sticky" then
      M.toggle_sticky()
    elseif choice == "__unrestrict" then
      -- like Emacs: drop both the `<` restriction and the lock, stay in the menu
      restrict = nil
      if M.lock then
        M.remove_restriction_lock()
      end
    elseif choice == "__restrict" then
      if not restrict then
        restrict = { bufnr = buf, filename = require("org.files").get_buffer(buf).filename }
      elseif not restrict.range and cur_hl then
        restrict = { bufnr = buf, filename = restrict.filename, range = { cur_hl.line, cur_hl.end_line } }
      else
        restrict = nil
      end
    else
      if type(choice) == "table" and choice.value == nil and not choice.custom then
        return
      end
      return M.dispatch(choice, restrict)
    end
  end
end

--- `:Org agenda [args]`: open a view by key. `args` is a built-in key with
--- optional arguments (`"a"`, `"t [KW|KW]"`, `"T KW"`, `"m MATCH"`,
--- `"M MATCH"`, `"s TEXT"`, `"S TEXT"`, `"n"`, `"#"`, `"/ REGEXP"`, `"*"`,
--- `">"`, `"e"` = store the agenda views, `"export FILE"` = write the
--- current agenda to FILE), a span
--- (`"day"`, `"week"`, `"fortnight"`, `"month"`, `"year"`, a number of days),
--- a key of `agenda.custom_commands`, or a date understood by
--- `org.date.read_date`. Empty opens the dispatcher. Must run inside a
--- coroutine; `require("org").agenda(args)` handles that.
---@param args? string
function M.command(args)
  args = vim.trim(args or "")
  if args == "" then
    return M.prompt()
  end
  local key, rest = args:match("^(%S+)%s*(.*)$")
  local custom = M.custom_commands()
  if custom[key] and type(custom[key]) == "table" then
    return open_custom(key)
  end
  if key == "day" or key == "week" or key == "fortnight" or key == "month" or key == "year" then
    return M.open_agenda({ span = key })
  elseif tonumber(key) then
    return M.open_agenda({ span = tonumber(key) })
  elseif key == "a" then
    return M.open_agenda({})
  elseif key == "t" then
    return M.open_todo(rest ~= "" and vim.split(rest, "[|%s]+", { trimempty = true }) or nil)
  elseif key == "T" then
    if rest == "" then
      return M.dispatch("T")
    end
    return M.open_todo(vim.split(rest, "[|%s]+", { trimempty = true }))
  elseif key == "m" or key == "M" then
    if rest == "" then
      return M.dispatch(key)
    end
    return M.open_tags(rest, key == "M")
  elseif key == "s" or key == "S" then
    if rest == "" then
      return M.dispatch(key)
    end
    return M.open_search(rest, nil, key == "S")
  elseif key == "#" or key == "n" or key == "*" or key == ">" or key == "?" then
    return M.dispatch(key)
  elseif key == "e" or key == "export" then
    if rest ~= "" then
      return require("org.agenda.export").write(rest)
    end
    return require("org.agenda.export").store_views()
  elseif key == "/" then
    if rest == "" then
      return M.dispatch("/")
    end
    return M.occur(rest)
  end
  -- a date?
  local d = date.read_date(args)
  if d then
    return M.open_day(d)
  end
  utils.error("Unknown agenda command: " .. args)
end

function M.search_command(args)
  return M.command("s " .. (args or ""))
end

function M.tags_command(args)
  return M.command("m " .. (args or ""))
end

function M.todo_command(args)
  return M.command("t " .. (args or ""))
end

return M
