---@mod org.extensions.quickadd Todoist-style quick add
---
--- Enable with `extensions = { quickadd = {} }` (see `:h org-extensions-quickadd`).
---
--- ```lua
--- local qa = require("org.extensions.quickadd")
--- qa.parse("Call Bob fri 3pm #work !A ~30m @Inbox due mon")
--- qa.add("Call Bob fri 3pm #work") -- adds the entry, returns bufnr, lnum
--- ```

local parse_mod = require("org.extensions.quickadd.parse")
local utils = require("org.utils")

local M = {}

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "stable"

M.defaults = {
  --- File entries go to when the line has no @target (or it matches
  --- nothing); nil = `default_notes_file`. Relative to `org_directory`.
  file = nil,
  --- Headline in `file` that entries go under (created when missing); nil
  --- adds them at the top level.
  headline = nil,
  --- Keyword of new entries; false for none. `*NEXT` in the line
  --- overrides it, `*-` removes it.
  keyword = "TODO",
  --- Where a date without `due` goes: "scheduled" or "deadline".
  date_kind = "scheduled",
  --- Files @targets are looked up in: "agenda" (the agenda files and the
  --- default file) or a list of files and globs.
  targets = "agenda",
  --- Show the parsed entry in a float below the prompt while typing.
  preview = true,
  --- Add an inactive `:CREATED:` timestamp property to new entries.
  created = false,
  --- Jump to the new entry after adding it.
  jump = false,
}

local function opts()
  return require("org.extensions").opts("quickadd") or M.defaults
end

--- Parse a quick-add line (see `org.extensions.quickadd.parse`).
---@param text string
---@param now? table org.date
---@param o? table parser options
---@return org.QuickaddItem
function M.parse(text, now, o)
  return parse_mod.parse(text, now, o)
end

---------------------------------------------------------------------------
-- Entry lines
---------------------------------------------------------------------------

--- The lines of an entry at `level` for a parsed item.
---@param item org.QuickaddItem
---@param level? integer (default 1)
---@param now? table org.date for :CREATED:
---@return string[]
function M.lines(item, level, now)
  local edit = require("org.edit")
  level = level or 1
  local indent = edit.body_indent(level)
  local out = {
    edit.build_headline({
      level = level,
      todo = item.todo,
      priority = item.priority,
      title = item.title ~= "" and item.title or nil,
      tags = require("org.tags").sort(vim.deepcopy(item.tags)),
    }),
  }
  local planning = {}
  if item.planning.deadline then
    planning[#planning + 1] = "DEADLINE: " .. item.planning.deadline
  end
  if item.planning.scheduled then
    planning[#planning + 1] = "SCHEDULED: " .. item.planning.scheduled
  end
  if #planning > 0 then
    out[#out + 1] = indent .. table.concat(planning, " ")
  end
  local props = {}
  if item.effort then
    local name = require("org.config").opts.effort_property or "Effort"
    props[#props + 1] = { name, require("org.date").format_duration(item.effort) }
  end
  if opts().created then
    local d = now or require("org.date").now()
    props[#props + 1] = { "CREATED", d:clone({ active = false }):to_string() }
  end
  if #props > 0 then
    out[#out + 1] = indent .. ":PROPERTIES:"
    for _, p in ipairs(props) do
      out[#out + 1] = edit.property_line(indent, p[1], p[2])
    end
    out[#out + 1] = indent .. ":END:"
  end
  return out
end

---------------------------------------------------------------------------
-- Targets
---------------------------------------------------------------------------

local function default_file()
  local f = opts().file
  if f == nil or f == "" then
    f = require("org.config").opts.default_notes_file
  end
  local path = utils.expand(f)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = utils.expand(require("org.config").opts.org_directory) .. "/" .. path
  end
  return vim.fs.normalize(path)
end
M.default_file = default_file

-- the target files, computed at most every TARGETS_TTL ms: the preview asks
-- for them on every keystroke and globbing the agenda files is not free
local TARGETS_TTL = 2000
local targets_memo

local function target_files()
  local now = vim.uv.now()
  local config = require("org.config").opts
  if
    targets_memo
    and now - targets_memo.at < TARGETS_TTL
    and targets_memo.opts == opts()
    and targets_memo.agenda == config.agenda_files
  then
    return targets_memo.paths
  end
  local t = opts().targets
  local paths
  if t == "agenda" or t == nil then
    paths = require("org.files").agenda_file_paths()
  else
    paths = utils.glob_org_files(type(t) == "table" and t or { t })
  end
  local out, seen = {}, {}
  for _, p in ipairs(vim.list_extend(vim.deepcopy(paths), { default_file() })) do
    p = vim.fs.normalize(p)
    if not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  targets_memo = { at = now, paths = out, opts = opts(), agenda = config.agenda_files }
  return out
end

-- best match of `query` in `list` (strings; `lower`, when given, holds
-- them lower-cased): the first exact, else prefix, else substring match,
-- then the best fuzzy one; returns the index
local function best_match(list, query, lower)
  local q = query:lower()
  local prefix, sub
  for i, s in ipairs(list) do
    local l = lower and lower[i] or s:lower()
    if l == q then
      return i
    elseif not prefix and l:sub(1, #q) == q then
      prefix = i
    elseif not sub and not prefix and l:find(q, 1, true) then
      sub = i
    end
  end
  if prefix or sub then
    return prefix or sub
  end
  local ok, res = pcall(vim.fn.matchfuzzypos, list, query)
  if ok and res[1][1] then
    for i, s in ipairs(list) do
      if s == res[1][1] then
        return i
      end
    end
  end
end

local function file_label(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

---------------------------------------------------------------------------
-- The heading index: per file, the headlines and their labels, kept until
-- the buffer changes (changedtick) or the file does (mtime and size)
---------------------------------------------------------------------------

local index = {}
-- the last lookup: { key, query, by_path, result }
local last_lookup

-- loaded buffers by normalized and real path
local function loaded_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        out[vim.fs.normalize(name)] = b
        local real = utils.realpath(name)
        if real then
          out[real] = b
        end
      end
    end
  end
  return out
end

local function file_index(p, bufs)
  local b = bufs[p] or bufs[utils.realpath(p) or ""]
  local key
  if b then
    key = "b" .. b .. ":" .. vim.api.nvim_buf_get_changedtick(b)
  else
    local st = vim.uv.fs_stat(p)
    if not st or st.type ~= "file" then
      index[p] = nil
      return nil
    end
    key = st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size
  end
  local c = index[p]
  if c and c.key == key then
    return c
  end
  local files = require("org.files")
  local ok, f = pcall(function()
    return b and files.get_buffer(b) or files.get(p)
  end)
  c = { key = key, hls = ok and f and f.headlines or {} }
  index[p] = c
  return c
end

-- labels of a file's headlines, titles or outline paths, and the same
-- lower-cased
local function labels(c, by_path)
  local field = by_path and "paths" or "titles"
  if not c[field] then
    local out, low = {}, {}
    for i, hl in ipairs(c.hls) do
      local label = by_path and table.concat(vim.list_extend(hl:outline_path(), { hl:plain_title() }), "/")
        or hl:plain_title()
      out[i], low[i] = label, label:lower()
    end
    c[field], c[field .. "_lower"] = out, low
  end
  return c[field], c[field .. "_lower"]
end

--- Forget the heading index (it is rebuilt as needed).
function M.clear_index()
  index, last_lookup, targets_memo = {}, nil, nil
end

--- Headlines of `paths` matching `query` best: `Heading` or an outline
--- path `Parent/Child`.
local function find_heading(paths, query)
  local bufs = loaded_buffers()
  local by_path = query:find("/", 1, true) ~= nil
  local list, low, hls, keys = {}, {}, {}, {}
  local cs = {}
  for _, p in ipairs(paths) do
    local c = file_index(p, bufs)
    if c then
      keys[#keys + 1] = p .. "=" .. c.key
      cs[#cs + 1] = { p, c }
    end
  end
  local key = table.concat(keys, "\n") .. (by_path and "\n/" or "")
  if last_lookup and last_lookup.key == key and last_lookup.query == query then
    return last_lookup.result
  end
  for _, pc in ipairs(cs) do
    local ls, ll = labels(pc[2], by_path)
    for i, hl in ipairs(pc[2].hls) do
      local n = #list + 1
      list[n], low[n] = ls[i], ll[i]
      hls[n] = { path = pc[1], hl = hl }
    end
  end
  local i = best_match(list, query, low)
  local result = i and hls[i] or nil
  last_lookup = { key = key, query = query, result = result }
  return result
end

--- Completion of `@target` words: the headings of the target files.
---@param arglead string the word being completed, `@...`
---@return string[]
function M.complete_target(arglead)
  local q = arglead:gsub("^@", "")
  local by_path = q:find("/", 1, true) ~= nil
  local bufs = loaded_buffers()
  local out, seen = {}, {}
  for _, p in ipairs(target_files()) do
    local c = file_index(p, bufs)
    for _, l in ipairs(c and labels(c, by_path) or {}) do
      local word = "@" .. (l:find("%s") and ('"' .. l .. '"') or l)
      if not seen[word] then
        seen[word] = true
        out[#out + 1] = word
      end
    end
  end
  return out
end

--- Where an entry with `target` goes: { filename, lnum?, label, missing? }.
--- Without a target (or when it matches nothing) this is `file` /
--- `headline`; `missing` then names what was not found.
---@param target? { file?: string, heading?: string, raw: string }
---@return { filename: string, lnum?: integer, label: string, missing?: string }
function M.resolve_target(target)
  local function fallback(missing)
    local fname = default_file()
    local headline = opts().headline
    local loc = { filename = fname, label = file_label(fname), missing = missing }
    if headline then
      loc.label = loc.label .. "/" .. headline
      loc.headline = headline
    end
    return loc
  end
  if not target then
    return fallback()
  end
  local paths = target_files()
  local file_paths = paths
  if target.file then
    local names = vim.tbl_map(file_label, paths)
    local i = best_match(names, target.file)
    if not i then
      -- a file of org_directory not in the agenda
      local p = utils.expand(target.file)
      if not p:match("%.org$") then
        p = p .. ".org"
      end
      if not utils.is_absolute(p) then
        p = utils.expand(require("org.config").opts.org_directory) .. "/" .. p
      end
      if vim.fn.filereadable(p) == 0 then
        -- no such file: `@Parent/Child`, an outline path
        local m = target.heading and find_heading(paths, target.raw)
        if m then
          return {
            filename = m.path,
            lnum = m.hl.line,
            label = file_label(m.path) .. "/" .. m.hl:plain_title(),
          }
        end
        return fallback(target.raw)
      end
      file_paths = { vim.fs.normalize(p) }
    else
      file_paths = { paths[i] }
    end
    if not target.heading then
      return { filename = file_paths[1], label = file_label(file_paths[1]) }
    end
  end
  local m = find_heading(file_paths, target.heading)
  if not m then
    if target.file then
      return {
        filename = file_paths[1],
        label = file_label(file_paths[1]) .. "/" .. target.heading,
        headline = target.heading,
      }
    end
    return fallback(target.raw)
  end
  return {
    filename = m.path,
    lnum = m.hl.line,
    label = file_label(m.path) .. "/" .. m.hl:plain_title(),
  }
end

---------------------------------------------------------------------------
-- Adding
---------------------------------------------------------------------------

--- Parse `text` and add the entry at its target, saving the file.
--- Returns the buffer and line of the new headline, or nil.
---@param text string
---@param now? table org.date
---@return integer|nil bufnr, integer|nil lnum
function M.add_text(text, now)
  if vim.trim(text or "") == "" then
    return nil
  end
  local item = M.parse(text, now)
  if item.title == "" then
    utils.warn("Quick add: the entry has no title")
    return nil
  end
  local loc = M.resolve_target(item.target)
  vim.fn.mkdir(vim.fn.fnamemodify(loc.filename, ":h"), "p")
  local bufnr = utils.load_buffer(loc.filename)
  local refile = require("org.refile")
  local files = require("org.files")
  local lnum = loc.lnum
  if not lnum and loc.headline then
    local hl = files.get_buffer(bufnr):find_by_title(loc.headline)
    local blines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if hl then
      lnum = hl.line
    elseif #blines == 1 and blines[1] == "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "* " .. loc.headline })
      lnum = 1
    else
      local t = refile.create_nodes({ filename = loc.filename, olp = {}, path = "" }, { loc.headline })
      lnum = t.lnum
    end
  end
  local b, l = refile.insert_subtree(M.lines(item, 1, now), { bufnr = bufnr, lnum = lnum })
  local saved, err = utils.save_buffer(b)
  if not saved then
    utils.warn("Quick add: " .. loc.filename .. " could not be saved: " .. tostring(err))
  end
  local msg = "Added to " .. loc.label .. ": " .. item.title
  if loc.missing then
    msg = msg .. " (no match for @" .. loc.missing .. ")"
  end
  utils.notify(msg)
  if opts().jump then
    local win = vim.fn.bufwinid(b)
    if win == -1 then
      vim.cmd("buffer " .. b)
      win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { l, 0 })
  end
  return b, l
end

---------------------------------------------------------------------------
-- Prompt with a live preview
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("org_quickadd")

--- Preview lines ({ text, hl } chunks per line) of a parsed line.
---@param text string
---@return table[][]
function M.preview_lines(text)
  local ok, item = pcall(M.parse, text)
  if not ok then
    return { { { tostring(item), "ErrorMsg" } } }
  end
  local rows = {}
  local head = {}
  if item.todo then
    head[#head + 1] = { item.todo .. " ", "OrgTODO" }
  end
  if item.priority then
    head[#head + 1] = { "[#" .. item.priority .. "] ", "OrgPriority" }
  end
  head[#head + 1] = { item.title ~= "" and item.title or "(no title)", item.title ~= "" and "Title" or "Comment" }
  if #item.tags > 0 then
    head[#head + 1] = { "  :" .. table.concat(item.tags, ":") .. ":", "OrgTag" }
  end
  rows[#rows + 1] = head
  if item.planning.scheduled then
    rows[#rows + 1] = { { "SCHEDULED: ", "OrgSpecialKeyword" }, { item.planning.scheduled, "OrgDate" } }
  end
  if item.planning.deadline then
    rows[#rows + 1] = { { "DEADLINE:  ", "OrgSpecialKeyword" }, { item.planning.deadline, "OrgDate" } }
  end
  if item.effort then
    rows[#rows + 1] = {
      { "Effort:     ", "OrgSpecialKeyword" },
      { require("org.date").format_duration(item.effort), "Number" },
    }
  end
  local loc_ok, loc = pcall(M.resolve_target, item.target)
  if loc_ok then
    local chunks = { { "→ ", "Comment" }, { loc.label, "Directory" } }
    if loc.missing then
      chunks[#chunks + 1] = { "  (no match for @" .. loc.missing .. ")", "WarningMsg" }
    end
    rows[#rows + 1] = chunks
  end
  return rows
end

--- Ask for a quick-add line in a one-line float, with the parsed entry
--- previewed below it. Calls `cb(text)` (nil when cancelled).
---@param default? string
---@param cb fun(text: string|nil)
function M.open_prompt(default, cb)
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.6)), vim.o.columns - 4)
  local row = math.floor(vim.o.lines * 0.25)
  local col = math.floor((vim.o.columns - width) / 2)
  local border = require("org.config").opts.win_border or "rounded"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default or "" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = border,
    title = " Quick add ",
    title_pos = "left",
    footer = " #tag !A ~30m @target due fri every week ",
    footer_pos = "right",
    zindex = 70,
  })
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  local pwin
  local done = false
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_valid(pbuf) then
      return
    end
    local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    local rows = vim.trim(text) == "" and { { { "Type an entry…", "Comment" } } } or M.preview_lines(text)
    local lines = {}
    for i, chunks in ipairs(rows) do
      lines[i] = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, chunks))
    end
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
    for i, chunks in ipairs(rows) do
      local c0 = 0
      for _, c in ipairs(chunks) do
        vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, c0, { end_col = c0 + #c[1], hl_group = c[2] })
        c0 = c0 + #c[1]
      end
    end
    local cfg = {
      relative = "editor",
      row = row + 3,
      col = col,
      width = width,
      height = math.max(#lines, 1),
      style = "minimal",
      border = border,
      focusable = false,
      zindex = 69,
    }
    if pwin and vim.api.nvim_win_is_valid(pwin) then
      vim.api.nvim_win_set_config(pwin, cfg)
    else
      pwin = vim.api.nvim_open_win(pbuf, false, cfg)
    end
  end
  local function finish(value)
    if done then
      return
    end
    done = true
    vim.cmd("stopinsert")
    for _, w in ipairs({ win, pwin }) do
      if w and vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    cb(value)
  end
  if opts().preview ~= false then
    render()
    local failed = false
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
      buffer = buf,
      callback = function()
        -- an error in the preview is shown once, not on every key
        local ok, err = pcall(render)
        if not ok and not failed then
          failed = true
          utils.error("Quick add preview: " .. tostring(err))
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
  local function submit()
    finish(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end
  vim.keymap.set({ "i", "n" }, "<CR>", submit, { buffer = buf })
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    finish(nil)
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function()
    finish(nil)
  end, { buffer = buf })
  vim.cmd("startinsert!")
  return buf, win
end

--- Ask for a line: the preview float with a UI, else `vim.ui.input`.
---@param default? string
---@return string|nil
function M.ask(default)
  if #vim.api.nvim_list_uis() == 0 then
    return utils.input({ prompt = "Quick add: ", default = default })
  end
  return utils.await(function(cb)
    M.open_prompt(default, cb)
  end)
end

--- Action `quickadd`: ask for a line and add the entry.
function M.add(text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    text = M.ask()
  end
  if not text or vim.trim(text) == "" then
    return
  end
  return M.add_text(text)
end

--- `:Org quickadd [text]`: add `text`, or ask for it. The text is taken
--- as typed (quotes, backslashes and spaces kept), not word by word.
function M.command(args, cmd)
  if type(cmd) == "table" and type(cmd.args) == "string" then
    local raw = cmd.args:match("^%s*%S+%s(.*)$")
    if raw then
      args = raw
    end
  end
  return M.add(args)
end

---------------------------------------------------------------------------
-- Capture templates with `quickadd = true`
---------------------------------------------------------------------------

-- The capture target (a template-like table for org.capture) of a
-- quick-add `@target`, or nil to keep the template's own target.
local function capture_target(target)
  local ok, loc = pcall(M.resolve_target, target)
  if not ok then
    return nil
  end
  if loc.missing then
    utils.warn("Quick add: no match for @" .. loc.missing .. ", captured to the template's target")
    return nil
  end
  if loc.lnum then
    local bufnr = utils.load_buffer(loc.filename)
    return {
      location = function()
        return bufnr, loc.lnum, 0
      end,
    }
  elseif loc.headline then
    return { target = loc.filename, headline = loc.headline }
  end
  return { target = loc.filename }
end

--- Capture store filter: parse the first headline of an entry captured
--- with a `quickadd = true` template. An `@target` in it sends the entry
--- there instead of the template's target.
---@param tpl table
---@param lines string[]
---@return string[]|nil lines, table|nil target
function M.capture_filter(tpl, lines)
  if not tpl.quickadd or (tpl.type or "entry") ~= "entry" then
    return nil
  end
  local parser = require("org.parser")
  local edit = require("org.edit")
  local file = parser.parse(lines)
  local hl = file.headlines[1]
  if not hl or hl.line ~= 1 then
    return nil
  end
  local keywords = vim.tbl_map(function(k)
    return k.name
  end, require("org.todo_keywords").global().keywords)
  local item = M.parse(hl.title, nil, { keyword = hl.todo or false, keywords = keywords })
  local tags = vim.deepcopy(hl.tags)
  for _, t in ipairs(item.tags) do
    if not vim.tbl_contains(tags, t) then
      tags[#tags + 1] = t
    end
  end
  local out = {
    edit.build_headline({
      level = hl.level,
      todo = item.todo,
      priority = item.priority or hl.priority,
      commented = hl.commented,
      title = item.title,
      tags = require("org.tags").sort(tags),
    }),
  }
  local indent = edit.body_indent(hl.level)
  -- the template's own planning, completed by the parsed dates
  local planning = {}
  if hl.planning_line then
    local l = lines[hl.planning_line]
    indent = l:match("^(%s*)")
    for kw, ts in l:gmatch("(%u+):%s*([<%[][^>%]]*[>%]])") do
      planning[kw] = ts
    end
  end
  planning.DEADLINE = item.planning.deadline or planning.DEADLINE
  planning.SCHEDULED = item.planning.scheduled or planning.SCHEDULED
  local parts = {}
  for _, kw in ipairs({ "CLOSED", "DEADLINE", "SCHEDULED" }) do
    if planning[kw] then
      parts[#parts + 1] = kw .. ": " .. planning[kw]
    end
  end
  if #parts > 0 then
    out[#out + 1] = indent .. table.concat(parts, " ")
  end
  local rest = (hl.planning_line or hl.line) + 1
  if item.effort then
    local name = require("org.config").opts.effort_property or "Effort"
    local prop = edit.property_line(indent, name, require("org.date").format_duration(item.effort))
    if hl.properties_range then
      for i = rest, hl.properties_range[2] - 1 do
        out[#out + 1] = lines[i]
      end
      out[#out + 1] = prop
      rest = hl.properties_range[2]
    else
      vim.list_extend(out, { indent .. ":PROPERTIES:", prop, indent .. ":END:" })
    end
  end
  for i = rest, #lines do
    out[#out + 1] = lines[i]
  end
  return out, item.target and capture_target(item.target) or nil
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

M.actions = {
  quickadd = { "org.extensions.quickadd", "add", desc = "Quick add an entry (Todoist-style line)", global = true },
}

--- Completion of `:Org quickadd` words: `@` headings of the target files,
--- `#` tags of the agenda files, `*` TODO keywords.
---@param arglead string
---@return string[]
function M.complete(arglead)
  if arglead:sub(1, 1) == "@" then
    return M.complete_target(arglead)
  elseif arglead:sub(1, 1) == "#" then
    local seen, out = {}, {}
    local bufs = loaded_buffers()
    for _, p in ipairs(target_files()) do
      local c = file_index(p, bufs)
      for _, hl in ipairs(c and c.hls or {}) do
        for _, t in ipairs(hl.tags or {}) do
          if not seen[t] then
            seen[t] = true
            out[#out + 1] = "#" .. t
          end
        end
      end
    end
    table.sort(out)
    return out
  elseif arglead:sub(1, 1) == "*" then
    local out = { "*-" }
    for _, k in ipairs(require("org.todo_keywords").global().keywords) do
      out[#out + 1] = "*" .. k.name
    end
    return out
  end
  return {}
end

M.commands = {
  quickadd = {
    "org.extensions.quickadd",
    "command",
    desc = "Quick add: :Org quickadd Call Bob fri 3pm #work !A ~30m @Inbox",
    complete = function(arglead)
      return M.complete(arglead)
    end,
  },
}

M.mappings = {
  global = { quickadd = "<prefix>q" },
}

function M.setup()
  M.clear_index()
  require("org.lazy").on_load("org.capture", "quickadd", function(capture)
    capture.store_filters.quickadd = M.capture_filter
  end)
end

function M.teardown()
  M.clear_index()
  require("org.lazy").if_loaded("org.capture", "quickadd", function(capture)
    capture.store_filters.quickadd = nil
  end)
end

function M.health(h, o)
  h.info("quick add: entries without @target go to " .. default_file())
  local ok, err = pcall(M.parse, "Check fri 3pm #tag !A ~30m due mon every week")
  if ok then
    h.ok("quick add parser")
  else
    h.error("quick add parser: " .. tostring(err))
  end
  if o and o.date_kind ~= "scheduled" and o.date_kind ~= "deadline" then
    h.warn('quick add: date_kind should be "scheduled" or "deadline"')
  end
end

return M
