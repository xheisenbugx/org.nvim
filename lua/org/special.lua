---@mod org.special Edit a region of an org buffer in a separate buffer
---
--- Used by `edit_special` (src blocks, tables formulas) and narrowing.
--- The source range is tracked with extmarks, so edits elsewhere in the
--- source buffer while the special buffer is open are safe. `:w` in the
--- special buffer writes back (`:w!` overrides a source content conflict);
--- the configured `save_exit` / `abort`
--- mappings leave it.

local config = require("org.config")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.special")

---@class org.SpecialOpts
---@field source_buf integer
---@field start_line integer first line of the edited region (1-based)
---@field end_line integer last line (inclusive); may be start_line-1 for an empty region
---@field lines string[] initial content of the edit buffer
---@field filetype? string
---@field name? string buffer name suffix
---@field to_source? fun(lines: string[]): string[] transform before writing back
---@field on_close? fun()
---@field window? string
---@field start_col? integer edit an object: 0-based byte column of its start on `start_line`
---@field end_col? integer 0-based byte column after its end on `end_line`
---@field exact_filetype? boolean `filetype` is a filetype, not an extension
---@field narrow? boolean a narrowed subtree or element: no edit-buffer message, reuse or auto-save
---@field init? fun(buf: integer) called in the new edit buffer
---@field kind? string
---@field switches? string

--- Open edit buffers by edit buffer number: { src, mark, win, close,
--- discard, narrow }.
---@type table<integer, table>
M.edits = {}

--- Range of an extmark of `ns` in `src`: row, col, end_row, end_col.
local function mark_range(src, mark)
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, src, ns, mark, { details = true })
  if not ok or not pos[1] or not pos[3] or pos[3].invalid then
    return nil
  end
  return pos[1], pos[2], pos[3].end_row, pos[3].end_col
end

--- The open edit buffer of exactly this region of `src` (org-src--edit-buffer).
local function edit_buffer_for(src, row, col, end_row, end_col)
  for ebuf, e in pairs(M.edits) do
    if e.src == src and not e.narrow and vim.api.nvim_buf_is_valid(ebuf) then
      local r, c, er, ec = mark_range(src, e.mark)
      if r == row and c == col and er == end_row and ec == end_col then
        return ebuf
      end
    end
  end
end

--- The winbar text of edit buffers (org-edit-src-persistent-message).
function M.persistent_message()
  local maps = config.opts.mappings.edit_src or {}
  local exit = config.lhs_list(maps.save_exit)[1]
  local abort = config.lhs_list(maps.abort)[1]
  if not exit or not abort then
    return nil
  end
  return string.format("Edit, then exit with ‘%s’ or abort with ‘%s’", exit, abort)
end

local function set_message(win)
  if config.opts.edit_src_persistent_message == false or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local msg = M.persistent_message()
  if msg then
    vim.api.nvim_set_option_value("winbar", (msg:gsub("%%", "%%%%")), { scope = "local", win = win })
  end
end

--- Show edit buffer `ebuf` again: focus its window, or open one
--- (org-src-switch-to-buffer).
function M.switch_to(ebuf)
  local e = M.edits[ebuf]
  if not e or not vim.api.nvim_buf_is_valid(ebuf) then
    return false
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == ebuf then
      vim.api.nvim_set_current_win(w)
      e.win = w
      return ebuf
    end
  end
  e.win = ui.open_buffer_window(ebuf, e.window or config.opts.win_split_mode, { title = e.name })
  if not e.narrow then
    set_message(e.win)
  end
  return ebuf
end

--- Go back to the edit buffer of the region at the cursor
--- (org-edit-src-continue).
function M.continue_at_point()
  local src = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  for ebuf, e in pairs(M.edits) do
    if e.src == src and vim.api.nvim_buf_is_valid(ebuf) then
      local r, c, er, ec = mark_range(src, e.mark)
      if r then
        local inside
        if ec == 0 and er > r and c == 0 then
          -- lines r .. er - 1
          inside = row >= r and row < er
        else
          inside = (row > r or (row == r and col >= c)) and (row < er or (row == er and col <= ec))
        end
        if inside then
          return M.switch_to(ebuf)
        end
      end
    end
  end
  utils.error("No sub-editing buffer for area at point")
end

--- Name of the auto-save file of an edit buffer (org-edit-src-turn-on-auto-save):
--- org-src-XXXXXX-%Y-%d-%m.txt in the directory of the source buffer.
local function auto_save_file(src)
  local name = vim.api.nvim_buf_get_name(src)
  local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local rand = {}
  for i = 1, 6 do
    local k = math.random(1, #chars)
    rand[i] = chars:sub(k, k)
  end
  return dir .. "/org-src-" .. table.concat(rand) .. os.date("-%Y-%d-%m") .. ".txt"
end

---@param opts org.SpecialOpts
function M.open(opts)
  local src = opts.source_buf
  local object = opts.start_col ~= nil
  local row0 = opts.start_line - 1
  local col0 = opts.start_col or 0
  local erow0 = object and (opts.end_line - 1) or math.max(opts.end_line, opts.start_line - 1)
  local ecol0 = opts.end_col or 0
  if not opts.narrow then
    local old = edit_buffer_for(src, row0, col0, erow0, ecol0)
    if old then
      -- org-src-ask-before-returning-to-edit-buffer
      if
        config.opts.src_ask_before_returning_to_edit_buffer == false
        or utils.confirm("Return to existing edit buffer ([n] will revert changes)? ")
      then
        M.switch_to(old)
        return old, M.edits[old] and M.edits[old].win
      end
      M.edits[old].discard()
    end
  end
  -- Track identity as well as position. Two point marks can collapse onto
  -- unrelated text when the source region is deleted.
  local mark, original
  local function anchor(row, col, end_row, end_col)
    if mark then
      pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
    end
    local empty = row == end_row and col == end_col
    mark = vim.api.nvim_buf_set_extmark(src, ns, row, col, {
      end_row = end_row,
      end_col = end_col,
      right_gravity = not empty,
      end_right_gravity = empty,
      invalidate = true,
    })
    original = object and vim.api.nvim_buf_get_text(src, row, col, end_row, end_col, {})
      or vim.api.nvim_buf_get_lines(src, row, end_row, false)
  end
  anchor(row0, col0, erow0, ecol0)

  local buf = vim.api.nvim_create_buf(false, false)
  local base = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":t")
  pcall(vim.api.nvim_buf_set_name, buf, string.format("org-special://%s/%s#%d", base, opts.name or "edit", buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  if opts.filetype and opts.filetype ~= "" then
    local ft = opts.exact_filetype and opts.filetype
      or vim.filetype.match({ filename = "x." .. opts.filetype })
      or opts.filetype
    vim.bo[buf].filetype = ft
  end

  local state = { src = src, narrow = opts.narrow, window = opts.window, name = opts.name }
  M.edits[buf] = state

  local function write_back(force)
    if not vim.api.nvim_buf_is_valid(src) or not vim.api.nvim_buf_is_loaded(src) then
      return false, "Source buffer no longer exists; edit buffer kept open"
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(src, ns, mark, { details = true })
    local detail = pos[3]
    -- Neovim 0.11 doesn't invalidate a mark over whole lines when they
    -- are deleted: it collapses
    local collapsed = detail
      and pos[1] == detail.end_row
      and pos[2] == detail.end_col
      and not vim.deep_equal(original, object and { "" } or {})
    if not detail or detail.invalid or collapsed then
      return false, "Source region was deleted or replaced; edit buffer kept open"
    end
    local current = object and vim.api.nvim_buf_get_text(src, pos[1], pos[2], detail.end_row, detail.end_col, {})
      or vim.api.nvim_buf_get_lines(src, pos[1], detail.end_row, false)
    if not force and not vim.deep_equal(current, original) then
      return false, "Source region changed; use :write! to overwrite it with this edit buffer"
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if opts.to_source then
      lines = opts.to_source(lines)
      if lines == nil then
        return false, "Cannot convert edits for the source; edit buffer kept open"
      end
    end
    if object then
      vim.api.nvim_buf_set_text(src, pos[1], pos[2], detail.end_row, detail.end_col, lines)
      local erow = pos[1] + math.max(#lines - 1, 0)
      local ecol = (#lines <= 1 and pos[2] or 0) + #(lines[#lines] or "")
      anchor(pos[1], pos[2], erow, ecol)
    else
      vim.api.nvim_buf_set_lines(src, pos[1], detail.end_row, false, lines)
      anchor(pos[1], 0, pos[1] + #lines, 0)
    end
    state.mark = mark
    vim.bo[buf].modified = false
    return true
  end
  state.mark = mark
  state.write_back = write_back

  local closed = false
  local function cleanup()
    if closed then
      return
    end
    closed = true
    M.edits[buf] = nil
    if state.timer then
      state.timer:stop()
      state.timer:close()
      state.timer = nil
    end
    if vim.api.nvim_buf_is_valid(src) then
      pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  local win = ui.open_buffer_window(buf, opts.window or config.opts.win_split_mode, { title = opts.name })
  state.win = win
  local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))
  local saved_winbar = vim.wo[win].winbar
  if not opts.narrow then
    set_message(win)
  end

  local function close()
    cleanup()
    local w = state.win
    if w and vim.api.nvim_win_is_valid(w) then
      if not opts.narrow and vim.api.nvim_win_get_buf(w) == buf then
        pcall(vim.api.nvim_set_option_value, "winbar", saved_winbar, { scope = "local", win = w })
      end
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(w, true)
      else
        vim.api.nvim_set_current_buf(src)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end
  state.close = close
  --- Close without writing back (org-edit-src-abort).
  state.discard = function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
    end
    close()
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local saved, err = write_back(vim.v.cmdbang == 1)
      if not saved then
        -- The buffer stays modified, so :wq/:wq!/:x refuse to close it.
        utils.error(err)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = cleanup,
  })

  if not opts.narrow then
    -- org-edit-src-auto-save-idle-delay: write back after a pause
    local delay = tonumber(config.opts.edit_src_auto_save_idle_delay) or 0
    if delay > 0 then
      state.timer = vim.uv.new_timer()
      vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
          if closed or not state.timer then
            return true
          end
          state.timer:stop()
          state.timer:start(
            math.floor(delay * 1000),
            0,
            vim.schedule_wrap(function()
              if closed or not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
                return
              end
              local saved, err = write_back()
              if not saved then
                utils.error(err)
              end
            end)
          )
        end,
      })
    end
    -- org-edit-src-turn-on-auto-save: save the contents to a file (like
    -- Emacs auto-save-mode) when idle ('updatetime', like swap files)
    if config.opts.edit_src_turn_on_auto_save then
      state.auto_save_file = auto_save_file(src)
      local saved_tick
      vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        buffer = buf,
        callback = function()
          local tick = vim.api.nvim_buf_get_changedtick(buf)
          if vim.bo[buf].modified and tick ~= saved_tick then
            saved_tick = tick
            vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), state.auto_save_file)
          end
        end,
      })
    end
  end

  local maps = config.opts.mappings.edit_src or {}
  for _, lhs in ipairs(config.lhs_list(maps.save_exit)) do
    vim.keymap.set("n", lhs, function()
      if vim.bo[buf].modified then
        local saved, err = write_back()
        if not saved then
          utils.error(err)
          return
        end
      end
      close()
    end, { buffer = buf, desc = "org: save and exit edit buffer" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.abort)) do
    vim.keymap.set("n", lhs, function()
      vim.bo[buf].modified = false
      close()
    end, { buffer = buf, desc = "org: abort edit buffer" })
  end
  vim.b[buf].org_special = true
  vim.b[buf].org_special_source = src
  vim.b[buf].org_special_kind = opts.kind
  vim.b[buf].org_special_switches = opts.switches
  if opts.init then
    vim.api.nvim_buf_call(buf, function()
      opts.init(buf)
    end)
  end
  return buf, win
end

---------------------------------------------------------------------------
-- Escaping (org-escape-code-in-region / org-unescape-code-in-region)
---------------------------------------------------------------------------

--- Lines of the Visual selection (the last one in Normal mode).
local function region_lines()
  local srow, _, erow = utils.visual_range()
  if srow == 0 or erow == 0 then
    local l = vim.api.nvim_win_get_cursor(0)[1]
    return l, l
  end
  return srow, erow
end

--- Escape lines starting with `*`, `#+`, `,*` or `,#+` by adding a comma
--- (org-escape-code-in-string).
function M.escape_lines(lines)
  local out = {}
  for i, l in ipairs(lines) do
    local ind, rest = l:match("^([ \t]*)(,*[*].*)$")
    if not ind then
      ind, rest = l:match("^([ \t]*)(,*#%+.*)$")
    end
    out[i] = ind and (ind .. "," .. rest) or l
  end
  return out
end

--- Remove the last comma before `*` or `#+` of lines starting with `,*`,
--- `,#+`, `,,*`, ... (org-unescape-code-in-string).
function M.unescape_lines(lines)
  local out = {}
  for i, l in ipairs(lines) do
    local pre, rest = l:match("^([ \t]*,*),([*].*)$")
    if not pre then
      pre, rest = l:match("^([ \t]*,*),(#%+.*)$")
    end
    out[i] = pre and (pre .. rest) or l
  end
  return out
end

local function on_region(fn)
  local s, e = region_lines()
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  local new = fn(lines)
  if not vim.deep_equal(new, lines) then
    vim.api.nvim_buf_set_lines(0, s - 1, e, false, new)
  end
  if vim.fn.mode():match("^[vV\22]") then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

--- Escape the lines of the selection (org-escape-code-in-region).
function M.escape_code_in_region()
  on_region(M.escape_lines)
end

--- Unescape the lines of the selection (org-unescape-code-in-region).
function M.unescape_code_in_region()
  on_region(M.unescape_lines)
end

local EXPORT_FT = { html = "html", latex = "tex", tex = "tex", md = "markdown", markdown = "markdown", ascii = "text" }

--- LaTeX fragment of `line` covering byte column `col` (1-based):
--- `$x$`, `$$x$$`, `\(x\)`, `\[x\]`. Returns the 1-based start and end of
--- its contents (between the delimiters), or nil.
local function latex_fragment_at(line, col)
  local pats = {
    { "\\%(", "\\%)" },
    { "\\%[", "\\%]" },
    { "%$%$", "%$%$" },
  }
  for _, p in ipairs(pats) do
    local init = 1
    while true do
      local s, os_ = line:find(p[1], init)
      if not s then
        break
      end
      local cs, e = line:find(p[2], os_ + 1)
      if not cs then
        break
      end
      if col >= s and col <= e then
        return os_ + 1, cs - 1
      end
      init = e + 1
    end
  end
  -- $x$: no space after the opening / before the closing dollar
  local init = 1
  while true do
    local s = line:find("%$", init)
    if not s then
      break
    end
    local e = line:find("%$", s + 1)
    if not e then
      break
    end
    local inner = line:sub(s + 1, e - 1)
    if
      inner ~= ""
      and not inner:match("^%s")
      and not inner:match("%s$")
      and line:sub(s - 1, s - 1) ~= "$"
      and line:sub(e + 1, e + 1) ~= "$"
      and col >= s
      and col <= e
    then
      return s + 1, e - 1
    end
    init = e + 1
  end
end

--- C-c ' on an object or line that is not a block (org-edit-special):
--- inline src block, footnote reference, LaTeX fragment, INCLUDE /
--- SETUPFILE / BIBLIOGRAPHY keyword, planning line, timestamp or link.
--- Returns true when something was done.
function M.edit_object(bufnr, lnum, col)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  -- keywords that name a file: visit it
  local key, value = line:match("^%s*#%+(%w+):%s*(.-)%s*$")
  if key then
    key = key:upper()
    if key == "INCLUDE" or key == "SETUPFILE" or key == "BIBLIOGRAPHY" then
      if value == "" then
        utils.error("No file to edit")
        return true
      end
      local f = value:match('^"(.-)"') or value:match("^(%S+)")
      if f:match("^%a[%w+.-]*://") then
        utils.error("Files located with a URL cannot be edited")
        return true
      end
      f = f:gsub("::.*$", "")
      local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
      utils.open_file(utils.expand(f, dir))
      return true
    end
  end
  -- planning line: org-deadline and/or org-schedule
  if line:match("^%s*SCHEDULED:") or line:match("^%s*DEADLINE:") or line:match("^%s*CLOSED:") then
    local ts = require("org.timestamps")
    local done = false
    if line:find("DEADLINE:", 1, true) then
      ts.deadline()
      done = true
    end
    if line:find("SCHEDULED:", 1, true) then
      ts.schedule()
      done = true
    end
    if done then
      return true
    end
  end
  local babel = require("org.babel")
  -- inline src block: edit its body (kept on one line)
  local ib = babel.inline_at(line, col)
  if ib and not ib.call then
    local open = line:find("{", ib.s, true)
    M.open({
      source_buf = bufnr,
      start_line = lnum,
      end_line = lnum,
      start_col = open,
      end_col = ib.e - 1,
      lines = { ib.body },
      filetype = require("org.babel.langs").filetype(ib.lang),
      exact_filetype = true,
      name = "inline-" .. ib.lang,
      kind = "inline-src",
      to_source = function(new)
        local text = table.concat(new, "\n"):gsub("\n[ \t]*", " ")
        return { vim.trim(text) }
      end,
    })
    return true
  end
  -- footnote reference: edit its definition
  local fn = require("org.footnotes").at_point(bufnr, lnum, col)
  if fn and (fn.kind == "reference" or fn.kind == "inline") then
    if not fn.label then
      utils.error("Cannot edit remotely anonymous footnotes")
      return true
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local function inline_def(l, row)
      local s = l:find("[fn:" .. fn.label .. ":", 1, true)
      if not s then
        return nil
      end
      local depth, e = 0, nil
      for i = s, #l do
        local c = l:sub(i, i)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
          if depth == 0 then
            e = i
            break
          end
        end
      end
      if e then
        return { row = row, s = s + 5 + #fn.label, e = e }
      end
    end
    local target
    if fn.kind == "inline" then
      target = inline_def(line, lnum)
    else
      for _, d in ipairs(require("org.footnotes").collect_definitions(lines)) do
        if d.label == fn.label then
          target = { def = d }
        end
      end
      if not target then
        for i, l in ipairs(lines) do
          local t = inline_def(l, i)
          if t then
            target = t
            break
          end
        end
      end
    end
    if not target then
      utils.error("No definition for footnote " .. fn.label)
      return true
    end
    if target.def then
      local d = target.def
      local first = lines[d.start]
      local prefix = first:match("^%[fn:[^%]]+%]%s?") or ""
      local content = { first:sub(#prefix + 1) }
      vim.list_extend(content, vim.list_slice(lines, d.start + 1, d.stop))
      M.open({
        source_buf = bufnr,
        start_line = d.start,
        end_line = d.stop,
        start_col = #prefix,
        end_col = #lines[d.stop],
        lines = content,
        filetype = "org",
        name = "footnote-" .. fn.label,
        kind = "footnote",
      })
    else
      local l = lines[target.row]
      M.open({
        source_buf = bufnr,
        start_line = target.row,
        end_line = target.row,
        start_col = target.s - 1,
        end_col = target.e - 1,
        lines = vim.split(l:sub(target.s, target.e - 1), "\n", { plain = true }),
        filetype = "org",
        name = "footnote-" .. fn.label,
        kind = "footnote",
        to_source = function(new)
          local text = table.concat(new, "\n")
          if text:find("\n[ \t]*\n") then
            utils.error("Inline definitions cannot contain blank lines")
            return nil
          end
          return { (text:gsub("\n", " ")) }
        end,
      })
    end
    return true
  end
  -- LaTeX fragment
  local fs, fe = latex_fragment_at(line, col)
  if fs then
    local in_table = line:match("^%s*|") ~= nil
    M.open({
      source_buf = bufnr,
      start_line = lnum,
      end_line = lnum,
      start_col = fs - 1,
      end_col = fe,
      lines = { line:sub(fs, fe) },
      filetype = "tex",
      name = "latex-fragment",
      kind = "latex-fragment",
      to_source = function(new)
        local text = table.concat(new, "\n"):gsub("\n[ \t]*\n", "\n")
        if in_table then
          text = text:gsub("\n", " ")
        end
        return vim.split(text, "\n", { plain = true })
      end,
    })
    return true
  end
  -- timestamp: org-timestamp / org-timestamp-inactive
  local ts = require("org.date").at_col(line, col)
  if ts then
    local t = require("org.timestamps")
    if ts.date and ts.date.active == false then
      t.insert_inactive()
    else
      t.insert_active()
    end
    return true
  end
  -- link: visit it (ffap)
  local links = require("org.links")
  if links.link_at_cursor and links.link_at_cursor() then
    links.open_at_point()
    return true
  end
  return false
end

--- Edit the element at the cursor in a separate buffer (org-edit-special
--- for elements other than src blocks and tables): example, export and
--- comment blocks, LaTeX environments and fixed-width (`: `) areas.
--- Returns false when there is nothing to edit.
function M.edit_element(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = require("org.babel.blocks")
  if lnum < 1 or lnum > #lines then
    return false
  end
  local line = lines[lnum]
  -- Literal block bodies can contain text resembling other editable
  -- elements. Resolve their containing block before fixed-width or LaTeX.
  local block = blocks.literal_block_at(lines, lnum)
  if block then
    local kind, s, e = block.kind, block.start, block.finish
    if kind == "src" or kind == "verse" then
      return false -- source blocks and inline objects are handled elsewhere
    end
    local body = blocks.unescape(vim.list_slice(lines, s + 1, e - 1))
    local switches = kind == "example" and lines[s]:match("^%s*#%+%a+_%a+%s*(.*)$") or nil
    local preserve = kind == "example" and blocks.preserve_indentation(switches)
    local ded = preserve and body or blocks.dedent(body)
    local content_indent = kind == "example" and (config.opts.edit_src_content_indentation or 0) or 0
    local prefix = preserve and "" or (lines[s]:match("^(%s*)") .. string.rep(" ", content_indent))
    local ft = kind == "comment" and "org" or nil
    if kind == "export" then
      local backend = lines[s]:lower():match("^%s*#%+begin_export%s+(%S+)") or ""
      ft = EXPORT_FT[backend] or backend
    end
    M.open({
      source_buf = bufnr,
      start_line = s + 1,
      end_line = e - 1,
      lines = #ded > 0 and ded or { "" },
      filetype = ft,
      name = kind,
      kind = kind,
      switches = switches,
      to_source = function(new)
        local out = {}
        for i, x in ipairs(blocks.escape(new)) do
          out[i] = x == "" and "" or prefix .. x
        end
        return out
      end,
    })
    return
  end
  -- table.el table (org-edit-table.el)
  if line:match("^[ \t]*[|+]") and require("org.table.el").bounds(lines, lnum) then
    return require("org.table.el").edit(bufnr, lnum)
  end
  -- fixed-width area
  local function fixed(l)
    return l and (l:match("^[ \t]*: ") or l:match("^[ \t]*:$"))
  end
  if fixed(line) then
    local s, e = lnum, lnum
    while fixed(lines[s - 1]) do
      s = s - 1
    end
    while fixed(lines[e + 1]) do
      e = e + 1
    end
    local indent = lines[s]:match("^(%s*)")
    local fw_mode = config.opts.edit_fixed_width_region_mode
    local content = {}
    for i = s, e do
      content[#content + 1] = lines[i]:match("^%s*: (.*)$") or ""
    end
    M.open({
      source_buf = bufnr,
      start_line = s,
      end_line = e,
      lines = content,
      name = "fixed-width",
      -- org-edit-fixed-width-region-mode: a filetype or a function
      filetype = type(fw_mode) == "string" and fw_mode or nil,
      exact_filetype = true,
      init = type(fw_mode) == "function" and fw_mode or nil,
      to_source = function(new)
        local out = {}
        for i, l in ipairs(new) do
          out[i] = indent .. (l == "" and ":" or (": " .. l))
        end
        return out
      end,
    })
    return
  end
  -- LaTeX environment
  for s = lnum, 1, -1 do
    local env = lines[s]:match("^%s*\\begin{([^}]+)}")
    if env then
      local e = s
      while e <= #lines and not lines[e]:find("\\end{" .. env .. "}", 1, true) do
        e = e + 1
      end
      if e <= #lines and e >= lnum then
        M.open({
          source_buf = bufnr,
          start_line = s,
          end_line = e,
          lines = vim.list_slice(lines, s, e),
          filetype = "tex",
          name = "latex-" .. env,
        })
        return
      end
      break
    end
    if s < lnum and (lines[s]:match("^%s*$") or lines[s]:match("^%*+%s")) then
      break
    end
  end

  return false
end

return M
