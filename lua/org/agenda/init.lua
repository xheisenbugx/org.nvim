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

--- Open a view: `{ blocks = {...} }` or a single block `{ type = ... }`.
---@param spec table
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table }
function M.open(spec, opts)
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

function M.open_search(text, restrict)
  M.open({ type = "search", match = text }, { restrict = restrict })
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
  elseif key == "s" then
    local text = utils.input({ prompt = "Search (words, +word -word {regexp}): " })
    if not text or text == "" then
      return
    end
    M.open_search(text, restrict)
  elseif key == "#" then
    M.open_stuck(restrict)
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
    local rlabel = "Restrict to buffer / subtree  [none]"
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
      { key = "#", label = "List stuck projects", value = "#" },
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
  elseif key == "s" then
    if rest == "" then
      return M.dispatch("s")
    end
    return M.open_search(rest)
  elseif key == "#" then
    return M.open_stuck()
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
