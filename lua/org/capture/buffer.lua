---@mod org.capture.buffer The capture buffer and window
---
--- Part of org.capture, which loads it: opening the CAPTURE-<key>
--- buffer (or the target window of an unnarrowed capture), its
--- mappings and hint, and M.capture, which starts a capture.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local marks = require("org.marks")
local parser = require("org.parser")
local ui = require("org.ui")
local utils = require("org.utils")
local shared = require("org.capture.shared")

local M = require("org.capture")

local CURSOR = shared.CURSOR
local cleanup_target = shared.cleanup_target
local discard_target = shared.discard_target
local emit = shared.emit
local end_unnarrowed = shared.end_unnarrowed
local get_line = shared.get_line
local kill_target = shared.kill_target
local mark_pos = shared.mark_pos
local origin_context = shared.origin_context
local pick_date = shared.pick_date
local prompted_time = shared.prompted_time
local release = shared.release
local resume_interrupted = shared.resume_interrupted
local run_hook = shared.run_hook
local shape = shared.shape
local start_clock = shared.start_clock
local template_text = shared.template_text

---------------------------------------------------------------------------
-- Capture buffer and window
---------------------------------------------------------------------------

local function hint(unnarrowed)
  local maps = config.opts.mappings.capture or {}
  local function first(v)
    return config.lhs_list(v)[1] or "-"
  end
  return string
    .format(
      " Capture: finish %s  refile %s  abort %s%s",
      first(maps.finalize),
      first(maps.refile),
      first(maps.kill),
      unnarrowed and "" or "  (:w finishes)"
    )
    :gsub("%%", "%%%%")
end

--- Split the expanded text into lines, removing the cursor marker.
---@return string[] lines, integer[]|nil cursor (row, col)
local function split_cursor(text)
  local lines = vim.split(text, "\n", { plain = true })
  local cursor
  for i, l in ipairs(lines) do
    local c = l:find(CURSOR, 1, true)
    if c and not cursor then
      cursor = { i, c - 1 }
    end
    lines[i] = l:gsub(CURSOR, "")
  end
  return lines, cursor
end

--- Add the %^{PROP}p answers and the template's properties to an entry.
local function with_properties(lines, props)
  if #props == 0 or not parser.headline_level(lines[1] or "") then
    return lines
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  for _, p in ipairs(props) do
    edit.set_property(b, 1, p[1], p[2])
  end
  lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return lines
end

--- Call the mapping `m` (a maparg() dict) an unnarrowed capture replaced,
--- or the keys themselves when there was none.
local function call_mapping(m, lhs)
  if m and m.callback then
    local keys = m.callback()
    if m.expr == 1 and type(keys) == "string" then
      vim.api.nvim_feedkeys(vim.keycode(keys), m.noremap == 1 and "n" or "m", false)
    end
  elseif m and m.rhs and m.rhs ~= "" then
    vim.api.nvim_feedkeys(vim.keycode(m.rhs), m.noremap == 1 and "n" or "m", false)
  else
    vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
  end
end

--- The capture keys of an unnarrowed capture live in the target buffer:
--- they act in the capture window and call the buffer's own mappings in
--- other windows. `end_unnarrowed` restores those mappings.
local function map_unnarrowed(s)
  local bufnr = s.ctx.loc.bufnr
  local maps = config.opts.mappings.capture or {}
  local actions = {
    {
      maps.finalize,
      function()
        utils.run(M.finalize, bufnr, { jump = vim.v.count > 0 })
      end,
      "org: finalize capture (count: and jump to it)",
    },
    {
      maps.kill,
      function()
        M.kill(bufnr)
      end,
      "org: abort capture",
    },
    {
      maps.refile,
      function()
        utils.run(M.refile, bufnr)
      end,
      "org: refile capture",
    },
  }
  s.maps = {}
  local seen = {}
  vim.api.nvim_buf_call(bufnr, function()
    for _, a in ipairs(actions) do
      for _, lhs in ipairs(config.lhs_list(a[1])) do
        if not seen[lhs] then
          seen[lhs] = true
          local prev = vim.fn.maparg(lhs, "n", false, true)
          prev = not vim.tbl_isempty(prev) and prev or nil
          s.maps[#s.maps + 1] = { lhs = lhs, prev = prev and prev.buffer == 1 and prev or nil }
          vim.keymap.set("n", lhs, function()
            if M.sessions[bufnr] == s and vim.api.nvim_get_current_win() == s.win then
              a[2]()
            else
              call_mapping(prev, lhs)
            end
          end, { buffer = bufnr, desc = a[3] })
        end
      end
    end
  end)
end

local function start_insert(lines, cursor)
  if cursor and not vim.g.org_test then
    local len = #(lines[cursor[1]] or "")
    if cursor[2] >= len then
      vim.cmd("startinsert!")
    else
      vim.cmd("startinsert")
    end
  end
end

--- Start an unnarrowed capture (:unnarrowed): the text goes into the
--- target buffer right away, like Emacs, and the capture window shows the
--- whole target. Extmarks track the text and the lines its placement
--- changed, so abort restores exactly those.
local function open_unnarrowed(tpl, text, ctx)
  local loc = ctx.loc
  local bufnr = loc.bufnr
  local function fail(msg)
    cleanup_target(loc)
    release(loc)
    utils.warn(msg)
    if ctx.clock_start then
      resume_interrupted(vim.tbl_extend("force", tpl, { clock_keep = false }), ctx)
    end
  end
  if M.sessions[bufnr] then
    return fail("Another capture is editing this buffer; finish it first")
  end
  local lines = vim.split(text, "\n", { plain = true })
  if (tpl.type or "entry") == "entry" then
    lines = with_properties(lines, ctx.properties)
  end
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = vim.bo[bufnr].modified
  local ok, first = pcall(M.place, loc, tpl, lines)
  if not ok or not first then
    utils.restore_buffer(bufnr, before, modified)
    return fail(ok and "Capture target not found" or tostring(first))
  end
  -- the lines the placement changed: the common prefix and suffix are
  -- untouched (the span always covers the new text)
  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last = first + #lines - 1
  local p = 0
  while p < first - 1 and p < #before and before[p + 1] == after[p + 1] do
    p = p + 1
  end
  local q = 0
  while q < #after - last and q < #before - p and before[#before - q] == after[#after - q] do
    q = q + 1
  end
  -- whole lines, up to the start of the next one: text inserted inside
  -- (also by `O` on the first line or `o` on the last) belongs to the span,
  -- and the mark goes invalid only when all its lines are deleted
  local function span(s0, e0)
    return marks.range(bufnr, s0, e0, { grow_start = true, invalidate = true })
  end
  local s = {
    template = tpl,
    ctx = ctx,
    unnarrowed = true,
    change = { original = vim.list_slice(before, p + 1, #before - q), mark = span(p + 1, #after - q) },
    region = span(first, last),
    origin_buf = ctx.origin_buf or vim.api.nvim_get_current_buf(),
    origin_win = vim.api.nvim_get_current_win(),
  }
  local cursor
  for r = first, last do
    local c = (get_line(bufnr, r) or ""):find(CURSOR, 1, true)
    if c then
      vim.api.nvim_buf_set_text(bufnr, r - 1, c - 1, r - 1, c, {})
      cursor = { r, c - 1 }
      break
    end
  end
  M.sessions[bufnr] = s
  local win = ui.open_buffer_window(bufnr, (config.opts.capture or {}).window or "split", {
    title = "Capture: " .. (tpl.description or tpl.key or ""),
  })
  s.win = win
  s.winbar = vim.wo[win].winbar
  vim.wo[win].winbar = hint(true)
  map_unnarrowed(s)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- closing the window ends the capture; the text stays in the target
      if M.sessions[bufnr] == s then
        M.sessions[bufnr] = nil
        s.win = nil
        end_unnarrowed(s)
        release(loc)
        utils.notify("Capture window closed: the text stays in the target buffer")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if M.sessions[bufnr] == s then
        M.sessions[bufnr] = nil
      end
    end,
  })
  -- like org-fold-show-all in the capture buffer
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("silent! normal! zR")
  end)
  pcall(vim.api.nvim_win_set_cursor, win, cursor or { first, 0 })
  run_hook(tpl.hook, bufnr)
  start_insert(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), cursor)
  return bufnr, win
end

--- Open the capture buffer.
local function open_buffer(tpl, text, ctx)
  local buf = vim.api.nvim_create_buf(false, false)
  local name = "CAPTURE-" .. (tpl.key or "x")
  if vim.fn.bufexists(name) == 1 then
    name = name .. "-" .. buf
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local lines, cursor = split_cursor(text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, p in ipairs(ctx.properties or {}) do
    if parser.headline_level(lines[1] or "") then
      edit.set_property(buf, 1, p[1], p[2])
    end
  end
  vim.bo[buf].modified = false

  local session = {
    template = tpl,
    ctx = ctx,
    origin_buf = ctx.origin_buf or vim.api.nvim_get_current_buf(),
    origin_win = vim.api.nvim_get_current_win(),
  }
  M.sessions[buf] = session
  local win = ui.open_buffer_window(buf, (config.opts.capture or {}).window or "split", {
    title = "Capture: " .. (tpl.description or tpl.key or ""),
  })
  session.win = win
  vim.bo[buf].filetype = "org"
  vim.wo[win].winbar = hint()

  local maps = config.opts.mappings.capture or {}
  for _, lhs in ipairs(config.lhs_list(maps.finalize)) do
    vim.keymap.set({ "n" }, lhs, function()
      local jump = vim.v.count > 0
      utils.run(M.finalize, buf, { jump = jump })
    end, { buffer = buf, desc = "org: finalize capture (count: and jump to it)" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.kill)) do
    vim.keymap.set({ "n" }, lhs, function()
      M.kill(buf)
    end, { buffer = buf, desc = "org: abort capture" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.refile)) do
    vim.keymap.set({ "n" }, lhs, function()
      utils.run(M.refile, buf)
    end, { buffer = buf, desc = "org: refile capture" })
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      utils.run(M.finalize, buf, { jump = false })
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local s = M.sessions[buf]
      M.sessions[buf] = nil
      if s then
        release(s.ctx.loc)
      end
    end,
  })
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  run_hook(tpl.hook, buf)
  start_insert(lines, cursor)
  return buf, win
end

--- Start a capture.
---@param tpl_or_key string|table template key or template table
--- `opts.answers` answers the template's `%^` prompts, by label or by
--- position; with `opts.noninteractive` the other prompts take their
--- default and a `time_prompt` date is now.
---@param opts? { initial?: string, date?: table, here?: boolean, date_prompt?: boolean, answers?: table<string|integer, any>, noninteractive?: boolean }
---@return integer|nil buf the capture buffer (or the target buffer with immediate_finish)
---@return integer|nil # the capture window, or the line of the stored entry
---@return string|nil # with immediate_finish, the file of the stored entry (its buffer may be gone: kill_buffer)
function M.capture(tpl_or_key, opts)
  opts = opts or {}
  local tpl = tpl_or_key
  if type(tpl_or_key) == "string" then
    tpl = M.get_template(tpl_or_key)
    if not tpl then
      utils.warn("No capture template for key: " .. tpl_or_key)
      return
    end
  end
  local ctx = origin_context(opts)
  ctx.date = opts.date
  ctx.here = opts.here
  ctx.answers = opts.answers
  ctx.noninteractive = opts.noninteractive
  if opts.noninteractive and tpl.time_prompt and not ctx.date then
    -- nobody to ask: the capture date is now
    ctx.date = date.now()
  end
  if (tpl.time_prompt or (opts.date_prompt and tpl.datetree)) and not ctx.date then
    ctx.date = pick_date(tpl.time_prompt and "Capture date" or "Date for tree entry", false, date.today())
    if not ctx.date then
      return
    end
    ctx.time = prompted_time(ctx.date)
  end
  -- the target is resolved (and headlines / date tree nodes created)
  -- before the template is expanded, like Emacs
  local loc, err = M.resolve_target(tpl, ctx)
  if not loc then
    utils.warn(err)
    return
  end
  ctx.loc = loc
  ctx.target_file = files.get_buffer(loc.bufnr)
  local line = mark_pos(loc)
  ctx.target_hl = line and ctx.target_file:headline_at(line) or nil
  local ttype = tpl.type or "entry"
  local ok, expanded = pcall(M.expand, template_text(tpl, ctx), ctx)
  if not ok then
    -- a cancelled prompt (or a failing template) leaves no trace
    discard_target(loc)
    if tostring(expanded):find("org_abort", 1, true) then
      return
    end
    error(expanded, 0)
  end
  expanded = shape(expanded, ttype)
  if tpl.properties and ttype == "entry" then
    for k, v in pairs(tpl.properties) do
      ctx.properties[#ctx.properties + 1] = { k, v }
    end
  end
  start_clock(tpl, ctx)
  if tpl.immediate_finish then
    local lines = vim.split((expanded:gsub(CURSOR, "")), "\n", { plain = true })
    if ttype == "entry" then
      lines = with_properties(lines, ctx.properties)
    end
    -- Emacs finalizes immediate captures too: no capture buffer here
    emit("OrgCapturePrepareFinalize", { immediate = true })
    local dbuf, dline = M.store(tpl, lines, ctx)
    local dfile
    if dbuf then
      dfile = vim.api.nvim_buf_get_name(dbuf)
      utils.notify("Captured to " .. utils.abbreviate(dfile))
      kill_target(tpl, loc)
      if tpl.jump_to_captured then
        M.goto_last_stored()
      end
      run_hook(tpl.after_finalize, dbuf, dline)
      emit("OrgCaptureAfterFinalize", { bufnr = dbuf, line = dline })
    else
      -- nothing stored and no capture buffer to keep it: undo the target
      -- headlines and restart an interrupted clock, like an abort
      discard_target(ctx.loc)
      if ctx.clock_start then
        resume_interrupted(vim.tbl_extend("force", tpl, { clock_keep = false }), ctx)
      end
    end
    return dbuf, dline, dfile ~= "" and dfile or nil
  end
  if tpl.unnarrowed then
    return open_unnarrowed(tpl, expanded, ctx)
  end
  return open_buffer(tpl, expanded, ctx)
end
