---@mod org.ui.images.preview Previews
---
--- Adding and removing previews, the link preview queue, showing links
--- and LaTeX fragments, refitting.
--- Part of org.ui.images, which loads it.

local utils = require("org.utils")
local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local as_png = shared.as_png
local ask_cell_size = shared.ask_cell_size
local backends = shared.backends
local buf_win = shared.buf_win
local cell = shared.cell
local in_place = shared.in_place
local mark_pos = shared.mark_pos
local max_width = shared.max_width
local ns = shared.ns
local opts = shared.opts
local previews = shared.previews
local text_columns = shared.text_columns

---------------------------------------------------------------------------
-- Previews
---------------------------------------------------------------------------

local next_id = 0

-- LaTeX renders waiting for their image: pending[bufnr][mark] = text
local pending = {}

-- Link previews waiting for their batch or their image (a download):
-- lqueue[bufnr] = items in order, lwaiting[bufnr][mark] = item
local lqueue, lwaiting, batch_timer = {}, {}, {}

local function buf_previews(bufnr)
  previews[bufnr] = previews[bufnr] or {}
  return previews[bufnr]
end

--- The text of an extmark's range now.
local function mark_text(bufnr, mark)
  local r, c, d = mark_pos(bufnr, mark)
  if not r or not d or not d.end_row then
    return nil
  end
  local ok, t = pcall(vim.api.nvim_buf_get_text, bufnr, r, c, d.end_row, d.end_col, {})
  return ok and table.concat(t, "\n") or nil
end

local function backend_of(p)
  return M._backend or backends[p.backend]
end

local function remove(bufnr, id)
  local list = previews[bufnr]
  local p = list and list[id]
  if not p then
    return
  end
  local b = backend_of(p)
  if b then
    pcall(b.hide, bufnr, p)
  end
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.mark)
  list[id] = nil
  M._schedule_sync()
end

local function overlaps(r1, r2)
  -- two { row, col, end_row, end_col } ranges (0-based, end exclusive)
  local a_before_b = r1.end_row < r2.row or (r1.end_row == r2.row and r1.end_col <= r2.col)
  local b_before_a = r2.end_row < r1.row or (r2.end_row == r1.row and r2.end_col <= r1.col)
  return not a_before_b and not b_before_a
end

--- Whether the extmark at `r`, `c` (details `d`) is in rows `first..last`
--- (1-based), or overlaps `range` ({ row, col, end_row, end_col }, 0-based)
--- when given (a zero-width range: the mark holds its column).
local function mark_in(r, c, d, first, last, range)
  local mr = { row = r, col = c, end_row = d and d.end_row or r, end_col = d and d.end_col or c }
  if range then
    return overlaps(mr, range)
      or (
        range.row == range.end_row
        and range.col == range.end_col
        and mr.row == range.row
        and mr.col <= range.col
        and mr.end_col >= range.col
      )
  end
  return mr.end_row + 1 >= first and mr.row + 1 <= last
end

--- Previews of `kind` in rows `first..last` (1-based), or overlapping
--- `range` ({ row, col, end_row, end_col }, 0-based) when given.
local function previews_in(bufnr, first, last, kind, range)
  local out = {}
  for id, p in pairs(previews[bufnr] or {}) do
    local r, c, d = mark_pos(bufnr, p.mark)
    if (not kind or p.kind == kind) and r and mark_in(r, c, d, first, last, range) then
      out[#out + 1] = id
    end
  end
  return out
end

--- Drop the link previews still waiting in rows `first..last` (or
--- `range`); all of them when `first` is nil.
local function drop_waiting(bufnr, first, last, range)
  for mark, item in pairs(lwaiting[bufnr] or {}) do
    local r, c, d = mark_pos(bufnr, mark)
    if not first or not r or mark_in(r, c, d, first, last, range) then
      item.cancelled = true
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
      lwaiting[bufnr][mark] = nil
    end
  end
end

--- Remove the previews of `kind` (all when nil) in rows `first..last`,
--- or overlapping `range`. Pending LaTeX renders and link previews
--- waiting there are dropped too (org-link-preview-clear).
function M.clear(bufnr, first, last, kind, range)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  first, last = first or 1, last or math.huge
  local ids = previews_in(bufnr, first, last, kind, range)
  for _, id in ipairs(ids) do
    remove(bufnr, id)
  end
  if kind ~= "link" then
    for mark in pairs(pending[bufnr] or {}) do
      local r = mark_pos(bufnr, mark)
      if not r or (r + 1 >= first and r + 1 <= last) then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
        pending[bufnr][mark] = nil
      end
    end
  end
  if kind ~= "latex" then
    drop_waiting(bufnr, first, last, range)
  end
  return #ids
end

--- The cells an image takes: its size spec -> width, height. An image in
--- place of its text fits in the columns after it (`indent`); `max_h`
--- caps the rows (1 for inline LaTeX: as tall as the line).
local function size_of(win, s)
  local maxh = opts().max_height
  if s.max_h then
    maxh = math.min(maxh or s.max_h, s.max_h)
  end
  local maxw = max_width(win)
  if s.kind == "latex" then
    maxw = text_columns(win) - 1
  end
  if s.indent then
    -- the columns left on the screen row the text starts on: with 'wrap'
    -- the text before it may take whole rows of its own
    local cols = text_columns(win)
    local indent = vim.wo[win].wrap and s.indent % cols or s.indent
    maxw = math.max(1, math.min(maxw, cols - 1 - indent))
  end
  if not s.pw then
    return maxw, math.min(maxh or 24, 10)
  end
  local want
  if s.width and s.width.px then
    want = math.max(1, math.floor(s.width.px / cell.w + 0.5))
  elseif s.width and s.width.fraction then
    local bufnr = vim.api.nvim_win_get_buf(win)
    local base = vim.bo[bufnr].textwidth > 0 and vim.bo[bufnr].textwidth or text_columns(win)
    want = math.max(1, math.floor(s.width.fraction * base + 0.5))
  end
  return M.fit(s.pw, s.ph, maxw, maxh, want)
end

--- Whether the line of image `p`, drawn in place of its text, wraps after
--- the image's screen row: the image would cover the line's own wrapped
--- text, as its rows can only be reserved after the whole line. Emacs makes
--- that screen line as tall as the image instead; here the image goes under
--- the line, as with `placement = "below"`.
local function wraps_after(bufnr, p)
  if not p.inline or p.multi or p.height <= 1 then
    return false
  end
  local win = buf_win(bufnr)
  local r, c, d = mark_pos(bufnr, p.mark)
  if win == -1 or not r or not vim.wo[win].wrap then
    return false
  end
  local cols = text_columns(win)
  local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ""
  local before = vim.fn.strdisplaywidth(line:sub(1, c)) % cols
  local rest = line:sub((d and d.end_col or c) + 1):gsub("%s+$", "")
  local after = vim.fn.strdisplaywidth(rest, before + p.width)
  return before + p.width + after > cols
end

--- Show preview `p` with backend `b` where its extmark is now: the rows
--- are reserved at the end of the link or fragment, the image starts at
--- its first column (under a fragment over several lines shown as text, at
--- the start of its last line).
local function show(b, bufnr, p)
  if b == backends.native then
    p.below = wraps_after(bufnr, p)
  end
  local r, c, d = mark_pos(bufnr, p.mark)
  local end_row = d and d.end_row or r
  local line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local end_col = math.min(d and d.end_col or c, #line)
  local x = (r == end_row or in_place(p)) and c or #line:match("^%s*")
  return b.show(bufnr, p, end_row, end_col, x, r)
end

--- Whether the cursor of the current window is on rows `r..er` (0-based)
--- of `bufnr`: the text of an image drawn in place shows there.
local function cursor_on(bufnr, r, er)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end
  local l = vim.api.nvim_win_get_cursor(0)[1] - 1
  return l >= r and l <= er
end

--- Whether an image drawn in place of rows `r..er` (0-based) of `bufnr`
--- shows its text instead: on the cursor line, and (native, taller than a
--- line) on the first line of a closed fold in the current window, where
--- the rows under the line can't be reserved.
local function want_revealed(bufnr, backend, height, r, er)
  if cursor_on(bufnr, r, er) then
    return true
  end
  return backend == "native"
    and height > 1
    and vim.api.nvim_get_current_buf() == bufnr
    and vim.fn.foldclosed(r + 1) == r + 1
end

--- Inline LaTeX (`$..$`, `\(..\)`) is drawn as tall as the line.
local function inline_math(text)
  return text:match("^%$[^$]") ~= nil or text:match("^\\%(") ~= nil
end

local function add(bufnr, kind, spec, src, backend)
  local win = buf_win(bufnr)
  win = win ~= -1 and win or vim.api.nvim_get_current_win()
  local file = src
  if backend.needs_png then
    file = as_png(src)
    if not file then
      return false, "can't convert " .. vim.fn.fnamemodify(src, ":t") .. " to PNG (install ImageMagick)"
    end
  end
  local end_row = (spec.end_row or spec.row) - 1
  local multi = end_row > spec.row - 1
  -- in place of the text (org-link-preview's display property) when the
  -- backend can
  local inline = opts().placement ~= "below" and backend.inline == true
  local pw, ph = M.png_size(file)
  local size = { pw = pw, ph = ph, width = spec.width, kind = kind }
  if inline then
    local line = vim.api.nvim_buf_get_lines(bufnr, spec.row - 1, spec.row, false)[1] or ""
    size.indent = vim.fn.strdisplaywidth(line:sub(1, spec.col))
    if kind == "latex" and inline_math(spec.text or "") then
      size.max_h = 1
    end
  end
  local w, h = size_of(win, size)
  next_id = next_id + 1
  local p = {
    id = next_id,
    kind = kind,
    src = file,
    width = w,
    height = h,
    align = spec.align,
    size = size,
    backend = backend.name,
    text = spec.text,
    inline = inline,
    multi = multi,
    revealed = inline and want_revealed(bufnr, backend.name, h, spec.row - 1, end_row),
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, spec.row - 1, spec.col, {
      end_row = end_row,
      end_col = spec.end_col,
      invalidate = true,
      undo_restore = false,
    }),
  }
  local list = buf_previews(bufnr)
  list[p.id] = p
  local ok, err = pcall(show, backend, bufnr, p)
  if not ok then
    list[p.id] = nil
    pcall(backend.hide, bufnr, p)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.mark)
    return false, tostring(err)
  end
  M.attach(bufnr)
  M._schedule_sync()
  return true
end

--- Make the preview of a waiting link `item` with the image `file` (nil:
--- nothing to show), if its link is still there unchanged.
local function place_link(bufnr, item, file)
  local waiting = lwaiting[bufnr]
  if waiting then
    waiting[item.mark] = nil
  end
  local ok_valid = vim.api.nvim_buf_is_valid(bufnr)
  local r, c, d
  if ok_valid then
    r, c, d = mark_pos(bufnr, item.mark)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, item.mark)
  end
  if item.cancelled or not file or not r or not d then
    return false
  end
  local ok_t, t = pcall(vim.api.nvim_buf_get_text, bufnr, r, c, d.end_row, d.end_col, {})
  if not ok_t or table.concat(t, "\n") ~= item.spec.text then
    return false
  end
  local spec = vim.tbl_extend("force", item.spec, { row = r + 1, col = c, end_col = d.end_col })
  local ok, err = add(bufnr, "link", spec, file, item.backend)
  if not ok then
    utils.warn(err)
  end
  return ok
end

--- Run the preview function of a waiting link: its image now, later (the
--- function returned true), or none.
local function run_link(bufnr, item)
  if item.cancelled then
    return
  end
  local spec = item.spec
  if not spec.preview then
    return place_link(bufnr, item, spec.path)
  end
  local r, c = mark_pos(bufnr, item.mark)
  if not r then
    return place_link(bufnr, item, nil)
  end
  local done = false
  local ctx = {
    bufnr = bufnr,
    row = r + 1,
    col = c,
    end_col = spec.end_col,
    type = spec.type,
    link = spec.link,
    refresh = item.refresh == true,
    callback = function(file)
      if done then
        return
      end
      done = true
      vim.schedule(function()
        place_link(bufnr, item, type(file) == "string" and file or nil)
      end)
    end,
  }
  local ok, res = pcall(spec.preview, spec.link_path, ctx)
  if not ok then
    utils.warn("link preview (" .. tostring(spec.type) .. "): " .. tostring(res))
    return place_link(bufnr, item, nil)
  elseif res ~= true then
    done = true
    return place_link(bufnr, item, type(res) == "string" and res or nil)
  end
end

--- Preview the next batch of queued links of `bufnr`, and schedule the
--- one after (org-link-preview--process-queue).
local function process_queue(bufnr)
  batch_timer[bufnr] = nil
  local queue = lqueue[bufnr]
  if not queue or not vim.api.nvim_buf_is_valid(bufnr) then
    lqueue[bufnr] = nil
    return
  end
  local size = opts().batch_size or 6
  local n = 0
  while #queue > 0 and (size <= 0 or n < size) do
    local item = table.remove(queue, 1)
    if not item.cancelled then
      n = n + 1
      run_link(bufnr, item)
    end
  end
  if #queue == 0 then
    lqueue[bufnr] = nil
  else
    batch_timer[bufnr] = true
    vim.defer_fn(function()
      process_queue(bufnr)
    end, math.floor((opts().preview_delay or 0.05) * 1000))
  end
end

--- Show the image links of rows `first..last` (or of `range`), replacing
--- the previews there. The first `ui.images.batch_size` links are shown at
--- once, the others in batches after. `refresh` asks remote images again.
--- Returns the number shown or on their way.
function M.show_links(bufnr, first, last, include_linked, range, refresh)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b, why = M.backend()
  if not b then
    utils.warn(why)
    return 0
  end
  ask_cell_size()
  M.clear(bufnr, first, last, "link", range)
  M.attach(bufnr)
  lwaiting[bufnr] = lwaiting[bufnr] or {}
  local queue = lqueue[bufnr] or {}
  lqueue[bufnr] = queue
  local items = {}
  for _, lk in ipairs(M.find_image_links(bufnr, first, last, include_linked, range)) do
    -- remember where the link is while it waits
    local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, lk.row - 1, lk.col, {
      end_row = lk.row - 1,
      end_col = lk.end_col,
      invalidate = true,
      undo_restore = false,
    })
    local item = { mark = mark, spec = lk, backend = b, refresh = refresh }
    lwaiting[bufnr][mark] = item
    queue[#queue + 1] = item
    items[#items + 1] = item
  end
  if not batch_timer[bufnr] then
    process_queue(bufnr)
  end
  local n = 0
  for _, item in ipairs(items) do
    if not item.cancelled and (lwaiting[bufnr] or {})[item.mark] then
      n = n + 1
    end
  end
  return n + #previews_in(bufnr, first, last, "link", range)
end

--- Render and show the LaTeX fragments of rows `first..last` (or of
--- `range`), replacing the previews there. Rendering is asynchronous;
--- `done(n, err)` is called with the number shown.
function M.show_latex(bufnr, first, last, done, range)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b, why = M.backend()
  if not b then
    utils.warn(why)
    return
  end
  ask_cell_size()
  M.clear(bufnr, first, last, "latex", range)
  local frags = M.find_latex_fragments(bufnr, first, last, range)
  if #frags == 0 then
    if done then
      done(0)
    end
    return
  end
  pending[bufnr] = pending[bufnr] or {}
  local left, n, failed = #frags, 0, nil
  for _, f in ipairs(frags) do
    -- remember where the fragment is while it renders
    local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, f.row - 1, f.col, {
      end_row = f.end_row - 1,
      end_col = f.end_col,
      invalidate = true,
      undo_restore = false,
    })
    pending[bufnr][mark] = f.text
    M.render_latex(f.text, bufnr, function(png, err)
      left = left - 1
      local still = vim.api.nvim_buf_is_valid(bufnr) and pending[bufnr] and pending[bufnr][mark]
      if still then
        pending[bufnr][mark] = nil
        local r, c, d = mark_pos(bufnr, mark)
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
        if png and r and d then
          local ok_t, t = pcall(vim.api.nvim_buf_get_text, bufnr, r, c, d.end_row, d.end_col, {})
          if ok_t and table.concat(t, "\n") == f.text then
            local spec = { row = r + 1, col = c, end_row = d.end_row + 1, end_col = d.end_col, text = f.text }
            local ok, e = add(bufnr, "latex", spec, png, b)
            n = n + (ok and 1 or 0)
            failed = failed or (not ok and e) or nil
          end
        elseif not png then
          failed = failed or err
        end
      end
      if left == 0 and done then
        done(n, failed)
      end
    end, f.row - 1, f.col)
  end
end

--- Size every preview again (the font or the window changed). `keep`: the
--- terminal still has the images (a window was resized), only move them.
function M.refit(keep)
  for bufnr, list in pairs(previews) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local win = buf_win(bufnr)
      if win ~= -1 then
        for _, p in pairs(list) do
          local w, h = size_of(win, p.size)
          local resized = w ~= p.width or h ~= p.height
          p.width, p.height = w, h
          if resized or (p.backend == "native" and p.shown and wraps_after(bufnr, p) ~= (p.below == true)) then
            local b = backend_of(p)
            if mark_pos(bufnr, p.mark) and b then
              pcall(b.hide, bufnr, p)
              pcall(show, b, bufnr, p)
            end
          end
        end
      end
    end
  end
  M.sync(not keep)
end

shared.backend_of = backend_of
shared.drop_waiting = drop_waiting
shared.lqueue = lqueue
shared.lwaiting = lwaiting
shared.mark_text = mark_text
shared.pending = pending
shared.previews_in = previews_in
shared.remove = remove
shared.show = show
shared.want_revealed = want_revealed
