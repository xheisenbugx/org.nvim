---@mod org.refile Refiling subtrees
---
--- Targets come from `refile.targets` (like org-refile-targets), a list of
--- specs:
---   { files = "agenda"|"current"|path(s)|function, max_level?, level?,
---     tag?, todo?, regexp? }
--- When it is empty, the targets are the level-1 headlines of the current
--- buffer (Emacs's default, org-refile-targets nil). Setting
--- `refile.max_level` / `refile.include_current_file` instead offers the
--- agenda files (plus the current file) up to that level.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

---@class org.RefileTarget
---@field filename string
---@field lnum integer|nil headline line; nil = file top level
---@field olp string[] outline path including the target itself
---@field level integer|nil
---@field label string label shown in the prompt
---@field path? string outline path label (used to complete in steps)

--- Files for a `refile.targets` spec: "agenda", "current", a path/glob or
--- a list of them, or a function returning paths (nil = current file).
local function spec_files(v, bufnr)
  if type(v) == "function" then
    v = v()
  end
  if v == nil or v == "current" then
    return utils.is_org(bufnr) and { files.get_buffer(bufnr) } or {}
  elseif v == "agenda" then
    return files.agenda_files()
  end
  local out = {}
  for _, p in ipairs(utils.glob_org_files(type(v) == "table" and v or { v })) do
    local f = files.get(p)
    if f then
      out[#out + 1] = f
    end
  end
  return out
end

--- Does `hl` satisfy a `refile.targets` spec?
local function spec_matches(spec, hl)
  if spec.level and hl.level ~= spec.level then
    return false
  end
  local max = spec.max_level or spec.maxlevel
  if max and hl.level > max then
    return false
  end
  if spec.tag and not vim.tbl_contains(hl.tags, spec.tag) then
    return false
  end
  if spec.todo and hl.todo ~= spec.todo then
    return false
  end
  if spec.regexp and vim.fn.match(hl.raw, spec.regexp) < 0 then
    return false
  end
  return true
end

--- (file, predicate) pairs describing where targets come from.
local function target_sources(specs, bufnr)
  local rcfg = config.opts.refile or {}
  specs = specs or rcfg.targets
  local sources = {}
  if (not specs or #specs == 0) and (rcfg.max_level or rcfg.include_current_file) then
    -- agenda files (plus the current file) up to `max_level`
    local max_level = rcfg.max_level or 3
    local list = files.agenda_files()
    if rcfg.include_current_file ~= false and utils.is_org(bufnr) then
      local cur = files.get_buffer(bufnr)
      local found = false
      for i, f in ipairs(list) do
        if f.filename and cur.filename and f.filename == cur.filename then
          list[i] = cur
          found = true
        end
      end
      if not found and cur.filename then
        table.insert(list, 1, cur)
      end
    end
    specs = { { files = list, max_level = max_level } }
  elseif not specs or #specs == 0 then
    -- org-refile-targets nil: the level-1 headlines of the current buffer
    specs = { { files = "current", level = 1 } }
  end
  for _, spec in ipairs(specs) do
    local list = spec.files
    if type(list) == "table" and list[1] and type(list[1]) == "table" then
      list = list -- already parsed files
    else
      list = spec_files(spec.files, bufnr)
    end
    for _, f in ipairs(list) do
      sources[#sources + 1] = {
        file = f,
        pred = function(hl)
          return spec_matches(spec, hl)
        end,
      }
    end
  end
  return sources
end

--- The outline path style (org-refile-use-outline-path): false | true |
--- "file" | "full-file-path" | "title" | "buffer-name".
local function outline_style()
  local style = (config.opts.refile or {}).use_outline_path
  if style == nil then
    return false
  end
  return style
end

--- Heading text of a target (links shown by their description).
local function heading_text(hl)
  local t = hl.title:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  t = t:gsub("%[%[([^%]]-)%]%]", "%1")
  return vim.trim(t)
end

--- The buffer whose headlines are "current": in the agenda, the buffer of
--- the item at the cursor (Emacs uses the marked entry's buffer).
local function default_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "orgagenda" then
    local ok, view = pcall(require, "org.agenda.view")
    local item = ok and view.item_at_cursor and view.item_at_cursor()
    local t = item and view.resolve_target(item)
    if t and t.bufnr then
      return t.bufnr
    end
  end
  return bufnr
end

--- All refile targets.
---@param opts? { exclude?: { filename: string, s: integer, e: integer }, targets?: table[], bufnr?: integer }
---@return org.RefileTarget[]
function M.targets(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or default_buffer()
  local rcfg = config.opts.refile or {}
  local style = outline_style()
  local verify = rcfg.verify
  local current = vim.api.nvim_buf_get_name(bufnr)
  current = current ~= "" and vim.fs.normalize(current) or nil
  local extra = style and "/" or ""
  local out = {}
  local seen = {}
  for _, src in ipairs(target_sources(opts.targets, bufnr)) do
    local f = src.file
    if f.filename then
      local fname = vim.fn.fnamemodify(f.filename, ":t")
      local base
      if style == "file" or style == "buffer-name" then
        base = fname
      elseif style == "full-file-path" then
        base = vim.uv.fs_realpath(f.filename) or f.filename
      elseif style == "title" then
        base = f.settings.title or fname
      end
      if base and not seen[f.filename] then
        out[#out + 1] = { filename = f.filename, olp = {}, label = base .. "/", path = base .. "/" }
      end
      seen[f.filename] = true
      local other = style ~= "file" and style ~= "full-file-path" and style ~= "title" and f.filename ~= current
      for _, hl in ipairs(f.headlines) do
        local excluded = opts.exclude
          and opts.exclude.filename == f.filename
          and hl.line >= opts.exclude.s
          and hl.line <= opts.exclude.e
        local key = f.filename .. ":" .. hl.line
        if not excluded and not seen[key] and src.pred(hl) and (not verify or verify(hl)) then
          seen[key] = true
          local olp = hl:outline_path()
          olp[#olp + 1] = hl:plain_title()
          local label
          if style then
            local parts = base and { base } or {}
            local h, chain = hl, {}
            while h do
              table.insert(chain, 1, (heading_text(h):gsub("%s*%[%d*%%%]", ""):gsub("%s*%[%d*/%d*%]", "")))
              h = h.parent
            end
            for _, p in ipairs(chain) do
              parts[#parts + 1] = (p:gsub("/", "\\/"))
            end
            label = table.concat(parts, "/")
          else
            label = heading_text(hl)
          end
          local path = label .. extra
          if other then
            label = path .. " (" .. fname .. ")"
          else
            label = path
          end
          out[#out + 1] = {
            filename = f.filename,
            lnum = hl.line,
            olp = olp,
            level = hl.level,
            label = label,
            path = path,
          }
        end
      end
    end
  end
  return out
end

--- Split an outline path label into its components ("a\/b" is one).
local function split_path(s)
  local parts, cur, i = {}, {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and s:sub(i + 1, i + 1) == "/" then
      cur[#cur + 1] = "\\/"
      i = i + 2
    elseif c == "/" then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  if #cur > 0 then
    parts[#parts + 1] = table.concat(cur)
  end
  return parts
end

--- Choose a target one outline level at a time
--- (org-outline-path-complete-in-steps).
local function pick_in_steps(targets, prompt)
  local by_path = {}
  for _, t in ipairs(targets) do
    by_path[t.path] = t
  end
  local prefix = {}
  while true do
    local choices, seen = {}, {}
    local here = #prefix > 0 and by_path[table.concat(prefix, "/") .. "/"] or nil
    if here then
      choices[#choices + 1] = { target = here, label = here.label .. "  (here)" }
    end
    for _, t in ipairs(targets) do
      local parts = split_path(t.path)
      local match = #parts > #prefix
      for i = 1, #prefix do
        if parts[i] ~= prefix[i] then
          match = false
          break
        end
      end
      if match then
        local nxt = parts[#prefix + 1]
        if not seen[nxt] then
          seen[nxt] = true
          local deeper = false
          for _, t2 in ipairs(targets) do
            local p2 = split_path(t2.path)
            if #p2 > #prefix + 1 then
              local same = true
              for i = 1, #prefix + 1 do
                if p2[i] ~= (i <= #prefix and prefix[i] or nxt) then
                  same = false
                  break
                end
              end
              if same then
                deeper = true
                break
              end
            end
          end
          local path = table.concat(vim.list_extend(vim.deepcopy(prefix), { nxt }), "/") .. "/"
          choices[#choices + 1] = { next = nxt, deeper = deeper, target = by_path[path], label = path }
        end
      end
    end
    if #choices == 0 then
      return here
    end
    local choice = utils.select(choices, {
      prompt = prompt,
      format_item = function(c)
        return c.label
      end,
      kind = "org_refile",
    })
    if not choice then
      return nil
    end
    if choice.next == nil or not choice.deeper then
      return choice.target
    end
    prefix[#prefix + 1] = choice.next
  end
end

--- Ask for a refile target (org-refile-get-location).
---@param opts? { prompt?: string, exclude?: table, targets?: table[], bufnr?: integer }
---@return org.RefileTarget|nil
function M.pick_target(opts)
  opts = opts or {}
  local targets = M.targets(opts)
  if #targets == 0 then
    utils.warn("No refile targets")
    return nil
  end
  local rcfg = config.opts.refile or {}
  local prompt = opts.prompt or "Refile to"
  local create = rcfg.allow_creating_parent_nodes
  if outline_style() and rcfg.outline_path_complete_in_steps ~= false and not create then
    return pick_in_steps(targets, prompt)
  end
  if create then
    local labels = vim.tbl_map(function(t)
      return t.label
    end, targets)
    local value = utils.input_complete(prompt .. ": ", function(cmdline)
      local out = {}
      for _, l in ipairs(labels) do
        if l:lower():find(cmdline:lower(), 1, true) then
          out[#out + 1] = l
        end
      end
      return out
    end)
    if not value or vim.trim(value) == "" then
      return nil
    end
    value = vim.trim(value)
    for _, t in ipairs(targets) do
      if t.label == value or t.path == value or t.path == value .. "/" then
        return t
      end
    end
    -- longest existing prefix + new nodes
    local best
    for _, t in ipairs(targets) do
      local l = t.path:gsub("/$", "")
      if value:sub(1, #l + 1) == l .. "/" and (not best or #t.path > #best.path) then
        best = t
      end
    end
    if not best then
      utils.warn("Invalid target location: " .. value)
      return nil
    end
    local rest = value:sub(#(best.path:gsub("/$", "")) + 2)
    local new_nodes = vim.split(rest, "/", { trimempty = true })
    if #new_nodes == 0 then
      return best
    end
    if create == "confirm" and not utils.confirm('Create new node "' .. table.concat(new_nodes, "/") .. '"?') then
      return nil
    end
    return M.create_nodes(best, new_nodes)
  end
  return utils.select(targets, {
    prompt = prompt,
    format_item = function(t)
      return t.label
    end,
    kind = "org_refile",
  })
end

--- Create headline(s) `names` under `parent` target; returns the new target.
function M.create_nodes(parent, names)
  local bufnr = utils.load_buffer(parent.filename)
  local file = files.get_buffer(bufnr)
  local level, at
  if parent.lnum then
    local hl = file:headline_at(parent.lnum)
    level = hl.level + 1
    at = hl.end_line
    while at > hl.line and vim.trim(file.lines[at] or "x") == "" do
      at = at - 1
    end
  else
    level = 1
    at = #file.lines
  end
  local lines = {}
  for i, name in ipairs(names) do
    lines[#lines + 1] = string.rep("*", level + i - 1) .. " " .. name
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  local olp = vim.deepcopy(parent.olp)
  vim.list_extend(olp, names)
  local path = parent.path .. table.concat(names, "/") .. "/"
  return {
    filename = parent.filename,
    lnum = at + #lines,
    olp = olp,
    level = level + #names - 1,
    label = path,
    path = path,
  }
end

--- Where a refiled subtree goes under `dest` (after line `at`) and its level.
local function insertion_point(file, dest)
  if dest.lnum then
    local hl = file:headline_at(dest.lnum)
    -- as the last child (after the subtree's blank lines), or the first
    return dest.prepend and hl.body_end or hl.end_line, hl.level + 1
  end
  if dest.prepend then
    return file.headlines[1] and file.preamble_end or #file.lines, 1
  end
  return #file.lines, 1
end

--- Insert `lines` (a subtree) under `dest`. Returns (bufnr, first line).
---@param lines string[]
---@param dest org.RefileTarget|{ filename?: string, bufnr?: integer, lnum?: integer, prepend?: boolean }
function M.insert_subtree(lines, dest)
  local bufnr = dest.bufnr or utils.load_buffer(dest.filename)
  local file = files.get_buffer(bufnr)
  local at, level = insertion_point(file, dest)
  local new = edit.relevel(vim.deepcopy(lines), level)
  if #file.lines == 1 and file.lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    at = 0
  else
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, new)
  end
  -- org-auto-align-tags
  pcall(require("org.tags").align, bufnr, at + 1)
  -- the moved IDs now live here
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    require("org.id").register_lines(new, vim.fs.normalize(name))
  end
  return bufnr, at + 1
end

--- The lines of the subtree at (bufnr, lnum), with its trailing blank
--- lines (org-copy-subtree), or of the region [s, e].
local function source_range(bufnr, lnum, range)
  if range then
    return range[1], range[2]
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  if not hl then
    error("org: nothing to refile here", 0)
  end
  return hl.line, hl.end_line
end

--- Move a subtree (or given lines, or the region `src.range`) to `dest`.
---@param src { bufnr?: integer, lnum?: integer, lines?: string[], range?: integer[] }
---@param dest org.RefileTarget
---@return integer bufnr, integer lnum of the moved headline
function M.move(src, dest)
  if src.lines then
    return M.insert_subtree(src.lines, dest)
  end
  local sbuf = src.bufnr or vim.api.nvim_get_current_buf()
  local s, e = source_range(sbuf, src.lnum or vim.api.nvim_win_get_cursor(0)[1], src.range)
  local lines = vim.api.nvim_buf_get_lines(sbuf, s - 1, e, false)
  local dbuf = dest.bufnr or utils.load_buffer(dest.filename)
  if dbuf == sbuf then
    if dest.lnum and dest.lnum >= s and dest.lnum <= e then
      error("Cannot refile to position inside the tree or region", 0)
    end
    local at = insertion_point(files.get_buffer(dbuf), dest)
    local b, l = M.insert_subtree(lines, { bufnr = dbuf, lnum = dest.lnum, prepend = dest.prepend })
    if at >= e then
      vim.api.nvim_buf_set_lines(sbuf, s - 1, e, false, {})
      return b, l - (e - s + 1)
    end
    vim.api.nvim_buf_set_lines(sbuf, s - 1 + #lines, e + #lines, false, {})
    return b, l
  end
  local b, l = M.insert_subtree(lines, { bufnr = dbuf, lnum = dest.lnum, prepend = dest.prepend })
  vim.api.nvim_buf_set_lines(sbuf, s - 1, e, false, {})
  return b, l
end

--- Save a buffer that is not shown in any window (hidden target files).
local function save_if_hidden(bufnr)
  if vim.fn.bufwinid(bufnr) == -1 then
    utils.save_buffer(bufnr)
  end
end

--- Where the last refile / capture went: { filename|bufnr, lnum, raw }.
M.last_stored = nil

--- Remember the headline at (bufnr, lnum) as the last stored location.
function M.remember(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local name = vim.api.nvim_buf_get_name(bufnr)
  M.last_stored = { bufnr = bufnr, filename = name ~= "" and name or nil, lnum = lnum, raw = line }
end

--- Log a refile note under the moved entry (org-log-refile).
local function log_refile(bufnr, lnum, mode)
  mode = mode or (config.opts.refile or {}).log
  if not mode then
    return
  end
  local note
  if mode == "note" then
    note = utils.input({ prompt = "Refile note: " })
    if note == nil then
      note = ""
    end
  end
  local ts = date.now():clone({ active = false }):to_string()
  edit.add_log_entry(bufnr, lnum, edit.log_lines("- Refiled on " .. ts, note))
end

local function with_note_order(dest)
  if dest.prepend == nil and (config.opts.refile or {}).reverse_note_order then
    return vim.tbl_extend("force", dest, { prepend = true })
  end
  return dest
end

--- The visual line range, when refiling a region.
local function visual_lines()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local s, _, e = utils.visual_range()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { s, e }
end

--- The running clock as a refile target (C-2 C-c C-w).
local function clock_target()
  local bufnr, lnum = require("org.capture").clock_location()
  if not bufnr then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return { filename = name, bufnr = bufnr, lnum = lnum, olp = {}, label = hl and hl:plain_title() or "running clock" }
end

--- Refile the subtree at target (org-refile). In Visual mode the selected
--- lines are refiled; they must start with a headline and form a sequence
--- of subtrees (with `refile.active_region_within_subtree`, the first line
--- is made a headline). A count works like Emacs's prefix argument: 4
--- (C-u) jumps to a target, 16 (C-u C-u) to the last refiled entry, 2
--- refiles under the running clock and 3 copies (org-refile-keep).
---@param target? org.Target
---@param opts? { dest?: org.RefileTarget, save?: boolean, copy?: boolean, targets?: table[], range?: integer[], count?: integer }
function M.refile(target, opts)
  opts = opts or {}
  local count = opts.count
  if count == nil then
    count = target == nil and vim.v.count or 0
  end
  if count == 4 then
    return M.goto()
  elseif count == 16 then
    return M.goto_last_stored()
  end
  local copy = opts.copy or count == 3
  local range = opts.range or (target == nil and visual_lines() or nil)
  local bufnr, file, hl
  if range then
    bufnr = vim.api.nvim_get_current_buf()
    file = files.get_buffer(bufnr)
    hl = file:headline_on(range[1])
    if not hl then
      if (config.opts.refile or {}).active_region_within_subtree then
        local line = vim.api.nvim_buf_get_lines(bufnr, range[1] - 1, range[1], false)[1]
        local parent = file:headline_at(range[1])
        local stars = string.rep("*", parent and parent.level + 1 or 1)
        vim.api.nvim_buf_set_lines(bufnr, range[1] - 1, range[1], false, { stars .. " " .. vim.trim(line) })
        file = files.get_buffer(bufnr)
        hl = file:headline_on(range[1])
      else
        utils.warn("The region is not a (sequence of) subtree(s)")
        return
      end
    end
    for _, h in ipairs(file.headlines) do
      if h.line > range[1] and h.line <= range[2] and h.level < hl.level then
        utils.warn("The region is not a (sequence of) subtree(s)")
        return
      end
    end
  else
    bufnr, file, hl = edit.resolve_headline(target)
    if not hl then
      return
    end
  end
  local verb = copy and "Refile (and keep)" or "Refile"
  if opts.copy then
    verb = "Copy"
  end
  local dest = opts.dest
  if not dest and count == 2 then
    dest = clock_target()
  end
  local s, e = hl.line, range and range[2] or hl.end_line
  dest = dest
    or M.pick_target({
      prompt = range and (verb .. " region to") or (verb .. ' subtree "' .. heading_text(hl) .. '" to'),
      exclude = { filename = file.filename, s = s, e = e },
      targets = opts.targets,
      bufnr = bufnr,
    })
  if not dest then
    return
  end
  dest = with_note_order(dest)
  local title = hl:plain_title()
  local ok, dbuf, dline
  if copy then
    local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    ok, dbuf, dline = pcall(M.insert_subtree, lines, dest)
  else
    ok, dbuf, dline = pcall(M.move, { bufnr = bufnr, lnum = hl.line, range = range and { s, e } }, dest)
  end
  if not ok then
    utils.error(tostring(dbuf))
    return
  end
  if range then
    -- every refiled headline gets a time stamp, never a note
    if (config.opts.refile or {}).log then
      local n = e - s + 1
      for lnum = dline + n - 1, dline, -1 do
        local h = files.get_buffer(dbuf):headline_on(lnum)
        if h then
          log_refile(dbuf, lnum, "time")
        end
      end
    end
  else
    log_refile(dbuf, dline)
  end
  M.remember(dbuf, dline)
  if dbuf ~= bufnr then
    save_if_hidden(dbuf)
  end
  if opts.save then
    utils.save_buffer(bufnr)
  end
  local where = (dest.path or dest.label):gsub("/$", "")
  utils.notify((opts.copy and "Copied" or "Refiled") .. ' "' .. title .. '" to ' .. where)
  return dbuf, dline
end

--- Copy the subtree at target to another location (org-refile-copy).
---@param target? org.Target
---@param opts? { dest?: org.RefileTarget }
function M.refile_copy(target, opts)
  return M.refile(target, vim.tbl_extend("force", opts or {}, { copy = true }))
end

--- Jump to a refile target (C-u C-c C-w).
function M.goto()
  local dest = M.pick_target({ prompt = "Goto" })
  if not dest then
    return
  end
  vim.cmd("normal! m'")
  local lnum = dest.lnum
  if not lnum then
    local reversed = (config.opts.refile or {}).reverse_note_order
    lnum = reversed and 1 or math.max(1, #(files.get(dest.filename) or { lines = {} }).lines)
  end
  utils.open_file(dest.filename, lnum)
end

--- Jump to the location of the last refile or capture
--- (org-refile-goto-last-stored, C-u C-u C-c C-w).
function M.goto_last_stored()
  local l = M.last_stored
  if not l then
    utils.warn("No refile or capture location stored yet")
    return
  end
  local bufnr = l.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = l.filename and utils.load_buffer(l.filename) or nil
  end
  if not bufnr then
    utils.warn("The last stored location is gone")
    return
  end
  local lnum = l.lnum
  if vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] ~= l.raw then
    for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line == l.raw then
        lnum = i
        break
      end
    end
  end
  vim.cmd("normal! m'")
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
  else
    vim.api.nvim_set_current_buf(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

return M
