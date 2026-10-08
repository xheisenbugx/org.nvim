---@mod org.capture.session Capture sessions: store, finalize, kill, refile
---
--- Part of org.capture, which loads it: storing the captured text,
--- clocking, hooks and events, unnarrowed captures, finalize (C-c C-c),
--- kill (C-c C-k), refile (C-c C-w) and jumping to the last capture.

local date = require("org.date")
local files = require("org.files")
local marks = require("org.marks")
local parser = require("org.parser")
local ui = require("org.ui")
local utils = require("org.utils")
local shared = require("org.capture.shared")

local M = require("org.capture")

local cleanup_target = shared.cleanup_target
local get_line = shared.get_line
local is_blank = shared.is_blank
local mark_pos = shared.mark_pos
local release = shared.release
local shape = shared.shape

---------------------------------------------------------------------------
-- Capture session
---------------------------------------------------------------------------

--- Link properties for the next capture, set by org-protocol and link
--- handlers instead of storing a link from the current buffer
--- (org-link-store-props / org-capture-link-is-already-stored):
--- `{ link?, description?, annotation?, initial?, keywords? }`.
M.link_store_props = nil

local function origin_context(opts)
  local props = M.link_store_props
  M.link_store_props = nil
  if props then
    return {
      keywords = props.keywords or {},
      link = props.link,
      link_desc = props.description,
      annotation = props.annotation or "",
      initial = opts.initial or props.initial or "",
    }
  end
  local ctx = { keywords = {} }
  local bufnr = vim.api.nvim_get_current_buf()
  ctx.origin_buf = bufnr
  ctx.origin_cursor = vim.api.nvim_win_get_cursor(0)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and vim.bo[bufnr].buftype == "" then
    ctx.origin_file = name
  end
  local ok, l = pcall(function()
    return require("org.links").link_to_location({ interactive = false })
  end)
  if ok and l then
    ctx.link = l.link
    ctx.link_desc = l.desc
    ctx.annotation = require("org.links").format(l.link, l.desc)
  end
  ctx.initial = opts.initial or ""
  return ctx
end

local function trim_blank(lines)
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

--- Call a template hook (:hook, :prepare-finalize, :before-finalize,
--- :after-finalize): a function or a list of functions, like
--- org-capture--run-template-functions. Errors are reported without
--- aborting the capture.
local function run_hook(fn, ...)
  if type(fn) == "table" then
    for _, f in ipairs(fn) do
      run_hook(f, ...)
    end
    return
  end
  if type(fn) ~= "function" then
    return
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    utils.error("Capture hook failed: " .. tostring(err))
  end
end

--- Fire a capture User autocmd (the global org-capture-*-finalize-hook),
--- after the template's own hook, like Emacs.
local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
end

local function first_headline_line(bufnr, start)
  local n = vim.api.nvim_buf_line_count(bufnr)
  for i = start, n do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if parser.headline_level(l) then
      return i
    end
  end
  return start
end

--- :clock-in: the capture clocks into the new entry from the start of the
--- capture (the running clock is stopped then). At the end the clock keeps
--- running with :clock-keep; otherwise it is clocked out and, with
--- :clock-resume, the interrupted task is clocked in again.
local function start_clock(tpl, ctx)
  if not tpl.clock_in then
    return
  end
  local clock = require("org.clock")
  ctx.clock_start = date.now()
  ctx.interrupted_clock = clock.current_task()
  if ctx.interrupted_clock then
    clock.clock_out({ quiet = true })
  end
end

local function resume_interrupted(tpl, ctx)
  if tpl.clock_resume and not tpl.clock_keep and ctx.interrupted_clock then
    require("org.clock").clock_in_task(ctx.interrupted_clock)
    utils.notify("Interrupted clock has been resumed")
  end
end

local function finish_clock(tpl, ctx, bufnr, line)
  local clock = require("org.clock")
  -- a non-entry capture clocks the entry it lands in
  local hl = files.get_buffer(bufnr):headline_at(line)
  if not hl then
    return
  end
  if tpl.clock_keep then
    clock.clock_in({ bufnr = bufnr, lnum = hl.line }, { at = ctx.clock_start, no_count = true })
  else
    clock.add_clock(bufnr, hl.line, ctx.clock_start, date.now())
    resume_interrupted(tpl, ctx)
  end
end

local stored, retarget

-- A store filter sent the entry elsewhere: resolve the new target and
-- undo what resolving the template's target did (like an abort does).
function retarget(ctx, target)
  local loc, err = M.resolve_target(target, {})
  if not loc then
    utils.warn(tostring(err) .. "; the template's target is used")
    return
  end
  local old = ctx.loc
  ctx.loc = loc
  if old then
    cleanup_target(old)
    release(old)
    if old.new_buffer and old.bufnr ~= loc.bufnr and vim.api.nvim_buf_is_valid(old.bufnr) then
      if not vim.bo[old.bufnr].modified and vim.fn.bufwinid(old.bufnr) == -1 then
        pcall(vim.api.nvim_buf_delete, old.bufnr, {})
      end
    end
  end
end

--- Store the captured text at its target. Returns (bufnr, line), or nil
--- when the text could not be stored (the target is gone).
function M.store(tpl, lines, ctx)
  ctx = ctx or {}
  lines = trim_blank(vim.deepcopy(lines))
  if #lines > 0 then
    for name, filter in pairs(M.store_filters) do
      local ok, res, target = pcall(filter, tpl, lines, ctx)
      if not ok then
        utils.error("Capture filter " .. name .. " failed: " .. tostring(res))
      elseif type(res) == "table" then
        lines = res
        if type(target) == "table" and not ctx.here and not tpl.unnarrowed then
          retarget(ctx, target)
        end
      end
    end
  end
  local ttype = tpl.type or "entry"
  if #lines == 0 then
    if tpl.allow_empty and ctx.loc then
      -- nothing to insert, but the target (a new file's head) is kept
      local bufnr = ctx.loc.bufnr
      if not tpl.no_save then
        local saved, err = utils.save_buffer(bufnr)
        if not saved then
          utils.warn("Capture could not be saved: " .. tostring(err))
          return nil
        end
      end
      return stored(tpl, ctx, bufnr, mark_pos(ctx.loc) or 1)
    end
    utils.warn("Capture is empty, nothing stored")
    return nil
  end
  local loc = ctx.loc
  if not loc then
    local err
    loc, err = M.resolve_target(tpl, ctx)
    if not loc then
      utils.warn(err)
      return nil
    end
    ctx.loc = loc
  end
  lines = vim.split(shape(table.concat(lines, "\n"), ttype), "\n", { plain = true })
  local bufnr = loc.bufnr
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = vim.bo[bufnr].modified
  -- restoring the text after a failed save squashes the target's marks
  local snapshot = { loc.mark and loc.mark:save() }
  for _, change in ipairs(loc.changes or {}) do
    snapshot[#snapshot + 1] = change.mark and change.mark:save()
  end
  local ok, line = pcall(M.place, loc, tpl, lines)
  if not ok then
    utils.warn(tostring(line))
    return nil
  end
  if not line then
    utils.warn("Capture target is gone, the text is kept in the capture buffer")
    return nil
  end
  if ttype == "entry" then
    line = first_headline_line(bufnr, line)
  end
  -- the hooks may edit the target: follow the stored text
  local entry = marks.set(bufnr, line)
  run_hook(tpl.before_finalize, bufnr, line)
  emit("OrgCaptureBeforeFinalize", { bufnr = bufnr, line = line })
  line = entry and entry:lnum() or line
  marks.del(entry)
  if not tpl.no_save then
    local saved, err = utils.save_buffer(bufnr)
    if not saved then
      utils.restore_buffer(bufnr, before, modified)
      marks.restore(snapshot)
      utils.warn("Capture could not be saved; the text is kept in the capture buffer: " .. tostring(err))
      return nil
    end
  end
  return stored(tpl, ctx, bufnr, line)
end

--- The captured text is safely stored at (bufnr, line): remember the
--- position and finish the clock.
function stored(tpl, ctx, bufnr, line)
  release(ctx.loc)
  if ctx.clock_start then
    -- Clock state can be persisted outside this buffer, and may resume an
    -- interrupted task. Only finalize it once the captured text is safe.
    -- A clock line added to the enclosing entry moves a non-entry capture.
    local entry = marks.set(bufnr, line)
    local clocked, err = pcall(function()
      finish_clock(tpl, ctx, bufnr, line)
      if not tpl.no_save then
        assert(utils.save_buffer(bufnr))
      end
    end)
    line = entry and entry:lnum() or line
    marks.del(entry)
    if not clocked then
      utils.warn("Capture was stored, but its clock changes could not be finalized: " .. tostring(err))
    end
  end
  require("org.refile").remember(bufnr, line, "last_capture")
  return bufnr, line
end

--- Restore the target buffer's own mappings replaced by an unnarrowed
--- capture, and drop its marks.
local function end_unnarrowed(s)
  local bufnr = s.ctx.loc.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    for _, m in ipairs(s.maps or {}) do
      pcall(vim.keymap.del, "n", m.lhs, { buffer = bufnr })
      if m.prev then
        pcall(vim.fn.mapset, "n", false, m.prev)
      end
    end
  end)
  marks.del(s.region, s.change and s.change.mark)
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.wo[s.win].winbar = s.winbar or ""
  end
end

local function close_session(buf)
  local s = M.sessions[buf]
  M.sessions[buf] = nil
  if s and s.unnarrowed then
    end_unnarrowed(s)
  end
  if s and s.win and vim.api.nvim_win_is_valid(s.win) then
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, s.win, true)
    elseif s.origin_buf and vim.api.nvim_buf_is_valid(s.origin_buf) then
      vim.api.nvim_win_set_buf(s.win, s.origin_buf)
    end
  end
  if vim.api.nvim_buf_is_valid(buf) and not (s and s.unnarrowed) then
    vim.bo[buf].modified = false
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if s and s.origin_win and vim.api.nvim_win_is_valid(s.origin_win) then
    pcall(vim.api.nvim_set_current_win, s.origin_win)
  end
end

--- With :kill-buffer, unload a target buffer that the capture loaded.
local function kill_target(tpl, loc)
  if tpl.kill_buffer and loc and loc.new_buffer and vim.api.nvim_buf_is_valid(loc.bufnr) then
    if vim.fn.bufwinid(loc.bufnr) == -1 then
      if utils.save_buffer_or_warn(loc.bufnr) then
        pcall(vim.api.nvim_buf_delete, loc.bufnr, {})
      end
    end
  end
end

---------------------------------------------------------------------------
-- Unnarrowed captures (:unnarrowed)
---------------------------------------------------------------------------

--- Rows (1-based, inclusive) holding an unnarrowed capture's text, or nil
--- when that text was deleted.
local function unnarrowed_region(s)
  return s.region:rows()
end

--- Finalize an unnarrowed capture: its text is already in the target, so
--- only the finishing steps of `M.store` remain. The capture stays open
--- when the text is empty or the target can't be saved.
---@return integer|nil bufnr, integer|nil line
local function store_unnarrowed(s)
  local tpl, ctx = s.template, s.ctx
  local bufnr = ctx.loc.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    utils.warn("Capture target buffer is gone")
    return nil
  end
  local first, last = unnarrowed_region(s)
  local lines = first and vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false) or {}
  if #trim_blank(lines) == 0 and not tpl.allow_empty then
    utils.warn("Capture is empty, nothing stored")
    return nil
  end
  first = first or vim.api.nvim_buf_line_count(bufnr)
  last = last or first
  local line = first
  while line < last and is_blank(get_line(bufnr, line)) do
    line = line + 1
  end
  local ttype = tpl.type or "entry"
  if ttype == "entry" then
    line = first_headline_line(bufnr, line)
  elseif ttype == "table-line" then
    pcall(require("org.table").align_at, bufnr, line)
  end
  pcall(require("org.lists").update_statistics_for, bufnr, line)
  local entry = marks.set(bufnr, line)
  run_hook(tpl.before_finalize, bufnr, line)
  emit("OrgCaptureBeforeFinalize", { bufnr = bufnr, line = line })
  line = entry and entry:lnum() or line
  marks.del(entry)
  if not tpl.no_save then
    local saved, err = utils.save_buffer(bufnr)
    if not saved then
      utils.warn("Capture could not be saved; the capture stays open: " .. tostring(err))
      return nil
    end
  end
  return stored(tpl, ctx, bufnr, line)
end

--- Abort an unnarrowed capture: the lines its placement changed (the
--- text, as edited since, and the blank lines around it) get their
--- original text back. Edits elsewhere in the target are kept.
local function remove_unnarrowed(s)
  local bufnr = s.ctx.loc.bufnr
  local c = s.change
  if not (c and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local first, last = c.mark:rows()
  if first then
    vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, c.original)
  end
end

--- Finish the capture in buffer `buf` (default: current). With a count
--- (C-u C-c C-c) or `jump_to_captured`, jump to the stored entry.
---@param buf? integer
---@param opts? { refile?: boolean, jump?: boolean }
function M.finalize(buf, opts)
  opts = opts or {}
  local jump = opts.jump
  if jump == nil then
    jump = vim.v.count > 0
  end
  buf = buf or vim.api.nvim_get_current_buf()
  local s = M.sessions[buf]
  if not s then
    utils.warn("Not a capture buffer")
    return
  end
  local tpl = s.template
  if opts.refile and (tpl.type or "entry") ~= "entry" then
    utils.warn("Refiling from a capture buffer makes only sense for `entry'-type templates")
    return
  end
  vim.cmd("stopinsert")
  run_hook(tpl.prepare_finalize, buf)
  emit("OrgCapturePrepareFinalize", { buf = buf })
  local dbuf, dline
  if s.unnarrowed then
    dbuf, dline = store_unnarrowed(s)
  else
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- store first: the capture buffer stays open when that fails
    dbuf, dline = M.store(tpl, lines, s.ctx)
  end
  if not dbuf then
    return
  end
  close_session(buf)
  if opts.refile then
    local refile = require("org.refile")
    local rbuf, rline = refile.refile({ bufnr = dbuf, lnum = dline }, { targets = tpl.refile_targets })
    if rbuf then
      dbuf, dline = rbuf, rline
      -- the last capture is where it was refiled to (org-capture-is-refiling
      -- moves org-capture-last-stored-marker and its bookmark)
      refile.remember(rbuf, rline, "last_capture", "last_capture_marker")
    end
  else
    utils.notify("Captured to " .. utils.abbreviate(vim.api.nvim_buf_get_name(dbuf)))
  end
  kill_target(tpl, s.ctx.loc)
  if (tpl.jump_to_captured or jump) and dbuf then
    M.goto_last_stored()
  end
  run_hook(tpl.after_finalize, dbuf, dline)
  emit("OrgCaptureAfterFinalize", { bufnr = dbuf, line = dline })
  return dbuf, dline
end

--- Jump to the location of the last capture
--- (org-capture-goto-last-stored, C-u C-u C-c c).
function M.goto_last_stored()
  return require("org.refile").goto_last_stored("last_capture")
end

--- Choose a template and jump to its target location, creating missing
--- headlines like a capture would (org-capture-goto-target, C-u C-c c).
---@param key? string template key (prompted when nil)
function M.goto_target(key)
  if not key then
    local items = M.menu_items()
    key = ui.menu({ title = "Go to capture target", items = items })
    if type(key) ~= "string" then
      return
    end
  end
  local tpl = M.get_template(key)
  if not tpl then
    utils.warn("No capture template for key: " .. key)
    return
  end
  local loc, err = M.resolve_target(tpl, { date = date.today() })
  if not loc then
    utils.warn(err)
    return
  end
  local line = mark_pos(loc) or 1
  release(loc)
  vim.cmd("normal! m'")
  local name = vim.api.nvim_buf_get_name(loc.bufnr)
  utils.open_file(name, line)
  return loc.bufnr, line
end

--- Undo what resolving a capture target created (headlines, date tree
--- nodes) and unload a target buffer the capture loaded.
local function discard_target(loc)
  cleanup_target(loc)
  release(loc)
  if loc and loc.new_buffer and vim.api.nvim_buf_is_valid(loc.bufnr) and not vim.bo[loc.bufnr].modified then
    if vim.fn.bufwinid(loc.bufnr) == -1 then
      pcall(vim.api.nvim_buf_delete, loc.bufnr, {})
    end
  end
end

--- Abort the capture.
function M.kill(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.sessions[buf] then
    return
  end
  vim.cmd("stopinsert")
  local s = M.sessions[buf]
  -- org-capture-kill finalizes with org-note-abort: the prepare and
  -- after hooks run, the before hook does not
  emit("OrgCapturePrepareFinalize", { buf = buf, aborted = true })
  if s.unnarrowed then
    remove_unnarrowed(s)
  end
  close_session(buf)
  local loc = s.ctx.loc
  discard_target(loc)
  utils.notify("Capture aborted")
  run_hook(s.template.on_abort, loc and loc.bufnr)
  if s.ctx.clock_start then
    -- nothing was clocked; :clock-resume restarts the interrupted clock
    resume_interrupted(vim.tbl_extend("force", s.template, { clock_keep = false }), s.ctx)
  end
  emit("OrgCaptureAfterFinalize", { aborted = true })
end

--- Finalize, then refile the captured entry (org-capture-refile). The
--- template's `refile_targets` replace `refile.targets`.
function M.refile(buf)
  return M.finalize(buf, { refile = true })
end

-- Shared with the parts loaded after this one
shared.origin_context = origin_context
shared.run_hook = run_hook
shared.emit = emit
shared.start_clock = start_clock
shared.resume_interrupted = resume_interrupted
shared.end_unnarrowed = end_unnarrowed
shared.kill_target = kill_target
shared.discard_target = discard_target
