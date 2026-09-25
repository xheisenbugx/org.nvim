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
--- `sorting` and the `todo_ignore_*` / `skip_*` agenda options.

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
  ["todo-tree"] = "todo",
  alltodo = "todo",
  ["stuck-projects"] = "stuck",
  stuck_projects = "stuck",
  ["tags-tree"] = "tags",
}

--- Normalize a block spec (accepts Emacs-style option names).
function M.normalize_block(b)
  local out = vim.deepcopy(b)
  out.type = TYPE_ALIASES[out.type] or out.type or "agenda"
  out.header = out.header or out.org_agenda_overriding_header
  out.span = out.span or out.org_agenda_span
  out.start_day = out.start_day or out.org_agenda_start_day
  out.files = out.files or out.org_agenda_files
  out.skip = b.skip or b.org_agenda_skip_function
  out.sorting = out.sorting or out.org_agenda_sorting_strategy
  if out.type == "todo" and not out.keywords and out.match and out.match ~= "" then
    out.keywords = vim.split(out.match, "[|%s]+", { trimempty = true })
  end
  return out
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

local function has_timestamp(hl)
  return hl.planning.scheduled ~= nil or hl.planning.deadline ~= nil or #hl.timestamps > 0
end

local function condition_holds(hl, cond, subtree)
  local c, arg = cond[1], cond[2]
  if c == "scheduled" or c == "notscheduled" then
    return (hl.planning.scheduled ~= nil) == (c == "scheduled")
  elseif c == "deadline" or c == "notdeadline" then
    return (hl.planning.deadline ~= nil) == (c == "deadline")
  elseif c == "timestamp" or c == "nottimestamp" then
    return has_timestamp(hl) == (c == "timestamp")
  elseif c == "regexp" or c == "notregexp" then
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
  elseif c == "todo" then
    return todo_matches(hl, arg)
  elseif c == "nottodo" then
    return not todo_matches(hl, arg)
  end
  error("unknown skip condition: " .. tostring(c))
end

--- A `skip` function skipping entries for which any condition holds:
--- "scheduled", "notscheduled", "deadline", "notdeadline", "timestamp",
--- "nottimestamp", "regexp" RE, "notregexp" RE, "todo" KWS, "nottodo" KWS
--- (KWS: a list of keywords, or "todo", "done" or "any").
---   skip = require("org.agenda").skip_entry_if("scheduled", "deadline")
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

--- Like `skip_entry_if`, but skips the whole subtree of an entry for which
--- a condition holds ("regexp" searches the whole subtree).
function M.skip_subtree_if(...)
  local conds = parse_conditions(...)
  return function(hl)
    local h = hl
    while h do
      for _, c in ipairs(conds) do
        if condition_holds(h, c, true) then
          return true
        end
      end
      h = h.parent
    end
    return false
  end
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
  local name = vim.fn.fnamemodify(file.filename or "buffer", ":t")
  utils.notify(hl and ('Agenda restricted to subtree "' .. hl:plain_title() .. '"') or ("Agenda restricted to " .. name))
  return true
end

--- Remove the restriction lock (C-c C-x >).
function M.remove_restriction_lock()
  if not M.lock then
    utils.notify("No agenda restriction lock")
    return
  end
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
    return vim.uv.fs_realpath(p) or vim.fs.normalize(p)
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
  for _, f in ipairs(require("org.files").agenda_files()) do
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

--- Open a view: `{ blocks = {...} }` or a single block `{ type = ... }`.
---@param spec table
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table }
function M.open(spec, opts)
  opts = opts or {}
  if not opts.restrict and M.lock then
    opts = vim.tbl_extend("force", opts, { restrict = M.lock_restriction() })
  end
  local blocks
  if spec.blocks or spec.types then
    blocks = spec.blocks or spec.types
  else
    blocks = { spec }
  end
  local view = { title = spec.description or spec.title, blocks = {} }
  for _, b in ipairs(blocks) do
    view.blocks[#view.blocks + 1] = M.normalize_block(b)
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

local function open_custom(key, restrict)
  local cmd = (config.opts.agenda.custom_commands or {})[key]
  if type(cmd) ~= "table" or not (cmd.types or cmd.blocks or cmd.type) then
    utils.error("No agenda custom command for key: " .. key)
    return
  end
  local spec = cmd
  if cmd.type then
    spec = { description = cmd.description, blocks = { cmd } }
  end
  M.open(spec, { restrict = restrict })
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
    M.open({ description = "Agenda and all TODOs", blocks = { { type = "agenda" }, { type = "todo" } } }, {
      restrict = restrict,
    })
  elseif key == "/" then
    local re = utils.input({ prompt = "Occur in agenda files (regexp): " })
    if re and re ~= "" then
      M.occur(re)
    end
  end
end

--- The agenda dispatcher (C-c a).
function M.prompt()
  local restrict = nil
  local buf = vim.api.nvim_get_current_buf()
  local is_org = utils.is_org(buf)
  local cur_hl
  if is_org then
    cur_hl = require("org.files").get_buffer(buf):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  end
  local custom = config.opts.agenda.custom_commands or {}
  while true do
    local rlabel = "Restrict to buffer / subtree  [" .. (M.lock and "lock" or "none") .. "]"
    if restrict then
      rlabel = restrict.range and "Restrict to buffer / subtree  [subtree]" or "Restrict to buffer / subtree  [buffer]"
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
    }
    local items = {}
    for _, it in ipairs(builtin) do
      if not custom[it.key] then
        items[#items + 1] = it
      end
    end
    if is_org then
      items[#items + 1] = { key = "<", label = rlabel, value = "__restrict" }
    end
    local entries = {}
    for key, cmd in pairs(custom) do
      if type(cmd) == "string" then
        entries[#entries + 1] = { key = key, label = cmd }
      elseif type(cmd) == "table" and not (cmd.types or cmd.blocks or cmd.type) then
        entries[#entries + 1] = { key = key, label = cmd.description or key }
      elseif type(cmd) == "table" then
        entries[#entries + 1] = { key = key, label = cmd.description or key, value = { custom = key } }
      end
    end
    if #entries > 0 then
      items[#items + 1] = { heading = true, label = "" }
      items[#items + 1] = { heading = true, label = "Custom commands" }
      vim.list_extend(items, require("org.ui").tree_from_keys(entries))
    end
    local choice = require("org.ui").menu({ title = "Org Agenda", items = items })
    if choice == nil then
      return
    end
    if choice == "__restrict" then
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

--- `:Org agenda [args]`
function M.command(args)
  args = vim.trim(args or "")
  if args == "" then
    return M.prompt()
  end
  local key, rest = args:match("^(%S+)%s*(.*)$")
  local custom = config.opts.agenda.custom_commands or {}
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
  elseif key == "#" or key == "n" then
    return M.dispatch(key)
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
