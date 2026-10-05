---@mod org.ui.images.place Native placement
---
--- Placing native images on the screen after every redraw, revealing
--- the text under the cursor, attaching to buffers, and the autocommands.
--- Part of org.ui.images, which loads it.

local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local anchor_of = shared.anchor_of
local ask_cell_size = shared.ask_cell_size
local backend_of = shared.backend_of
local cell = shared.cell
local drop_waiting = shared.drop_waiting
local in_place = shared.in_place
local lqueue = shared.lqueue
local lwaiting = shared.lwaiting
local mark_pos = shared.mark_pos
local mark_text = shared.mark_text
local native_img = shared.native_img
local ns = shared.ns
local pending = shared.pending
local previews = shared.previews
local remove = shared.remove
local restack_all = shared.restack_all
local show = shared.show
local startup = shared.startup
local want_revealed = shared.want_revealed
local win_info = shared.win_info

---------------------------------------------------------------------------
-- Native placement
---------------------------------------------------------------------------

local placed = {} ---@type table<string, { id: integer, opts: table }>
local data_cache = {} ---@type table<string, string>

--- Forget the image bytes read for native placement
--- (link_preview_refresh: the files may have changed).
local function clear_data_cache()
  data_cache = {}
end

--- Screen rectangles that cover windows below them: floating windows and
--- the popup menu.
local function covers()
  local rects = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative and cfg.relative ~= "" and not cfg.hide then
      local pos = vim.api.nvim_win_get_position(w)
      local border = cfg.border and cfg.border ~= "none" and cfg.border ~= "" and 1 or 0
      rects[#rects + 1] = {
        win = w,
        z = cfg.zindex or 50,
        top = pos[1] + 1 - border,
        left = pos[2] + 1 - border,
        bottom = pos[1] + vim.api.nvim_win_get_height(w) + border,
        right = pos[2] + vim.api.nvim_win_get_width(w) + border,
      }
    end
  end
  if vim.fn.pumvisible() == 1 then
    local pum = vim.fn.pum_getpos()
    if pum and pum.row then
      rects[#rects + 1] = {
        z = math.huge,
        top = pum.row + 1,
        left = pum.col + 1,
        bottom = pum.row + pum.height,
        right = pum.col + pum.width + (pum.scrollbar and 1 or 0),
      }
    end
  end
  return rects
end

local function hidden_by(r, row, col, w, h)
  return not (row > r.bottom or row + h - 1 < r.top or col > r.right or col + w - 1 < r.left)
end

--- Screen row (1-based) of the first line after the text of `lnum` in
--- `win`, or nil when it is not visible. Counts wrapped and virtual lines
--- with nvim_win_text_height, so concealed text is taken into account.
--- The virtual lines under a line count as filler above the next one: the
--- rows from the top line through `lnum` hold those of the lines before
--- it, not its own; of the filler above the top line only the part
--- scrolled into view (topfill) shows.
local function row_after(win, info, lnum)
  if lnum < info.topline or lnum > info.botline then
    return nil
  end
  local rows = vim.api.nvim_win_text_height(win, { start_row = info.topline - 1, end_row = lnum - 1 })
  local top = vim.api.nvim_win_text_height(win, { start_row = info.topline - 1, end_row = info.topline - 1 })
  local topfill = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topfill or 0
  end)
  return info.winrow + (info.winbar or 0) + rows.all - top.fill + topfill
end

-- concealed_before() results: key -> columns
local hidden_cache, hidden_count = {}, 0

--- Screen columns hidden before byte `col` of line `lnum` in `win`, which
--- screenpos() still counts: text concealed by syntax (the brackets and
--- targets of links) and the text of images drawn in place (in `list`).
local function concealed_before(win, bufnr, lnum, col, list)
  local level = vim.wo[win].conceallevel
  if col == 0 or level < 2 then
    return 0
  end
  local ranges = {}
  for _, q in pairs(list) do
    if q.pad then
      local r, c, d = mark_pos(bufnr, q.mark)
      if r == lnum - 1 and d and d.end_col <= col then
        ranges[#ranges + 1] = { c, d.end_col }
      end
    end
  end
  -- the cursor line shows its text in the modes not in 'concealcursor'
  local syntax = true
  if win == vim.api.nvim_get_current_win() and vim.api.nvim_win_get_cursor(win)[1] == lnum then
    local mode = vim.fn.mode():sub(1, 1)
    mode = (mode == "V" or mode == "\22") and "v" or mode
    syntax = vim.wo[win].concealcursor:find(mode, 1, true) ~= nil
  end
  local parts = { win, bufnr, vim.b[bufnr].changedtick, lnum, col, level, tostring(syntax) }
  for _, r in ipairs(ranges) do
    parts[#parts + 1] = r[1] .. "-" .. r[2]
  end
  local key = table.concat(parts, ":")
  if hidden_cache[key] then
    return hidden_cache[key]
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local hidden = 0
  vim.api.nvim_win_call(win, function()
    local i, region = 0, nil
    while i < math.min(col, #line) do
      local len = vim.str_utf_end(line, i + 1) + 1
      local w = vim.fn.strdisplaywidth(line:sub(i + 1, i + len))
      local mine = false
      for _, r in ipairs(ranges) do
        mine = mine or (i >= r[1] and i < r[2])
      end
      if mine then
        hidden = hidden + w
        region = nil
      elseif syntax then
        local sc = vim.fn.synconcealed(lnum, i + 1)
        if sc[1] == 1 then
          hidden = hidden + w
          -- level 2 shows a replacement character once per region
          if level == 2 and sc[2] ~= "" and sc[3] ~= region then
            hidden = hidden - vim.fn.strdisplaywidth(sc[2])
          end
          region = sc[3]
        else
          region = nil
        end
      end
      i = i + len
    end
  end)
  if hidden_count > 500 then
    hidden_cache, hidden_count = {}, 0
  end
  hidden_cache[key], hidden_count = hidden, hidden_count + 1
  return hidden
end

--- Where every native preview should be on the screen right now: an image
--- in place of its text at the text's screen position, the rows under it
--- shared with the other images in place on the line; images below the
--- line stacked after those rows.
---@return table<string, { src: string, opts: table }>
function M._layout()
  local want = {}
  local rects = covers()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local list = previews[bufnr]
    local cfg = vim.api.nvim_win_get_config(win)
    local is_float = cfg.relative ~= nil and cfg.relative ~= ""
    if list and next(list) and not cfg.hide then
      local info = win_info(win)
      local top, bottom = info.winrow + (info.winbar or 0), info.winrow + info.height - 1
      local left = info.wincol + info.textoff
      local right = info.wincol + info.width - 1
      local rows = {}
      for _, p in pairs(list) do
        if p.backend == "native" then
          local r, c = mark_pos(bufnr, p.mark)
          if r then
            local anchor = anchor_of(bufnr, p)
            rows[anchor] = rows[anchor] or {}
            table.insert(rows[anchor], { p = p, row = r, col = c })
          end
        end
      end
      for anchor, items in pairs(rows) do
        local lnum = anchor + 1
        local folded = vim.api.nvim_win_call(win, function()
          return vim.fn.foldclosed(lnum)
        end)
        local y = folded == -1 and row_after(win, info, lnum) or nil
        if folded == lnum then
          -- the first line of a closed fold shows, but not the rows under
          -- it: only an image as tall as the line can stay in place there
          -- (the taller ones show their text, see want_revealed())
          items = vim.tbl_filter(function(it)
            return in_place(it.p) and it.p.height == 1
          end, items)
          y = #items > 0 and top or nil
        end
        if y then
          table.sort(items, function(a, b)
            return a.row < b.row or (a.row == b.row and a.col < b.col)
          end)
          for _, it in ipairs(items) do
            if in_place(it.p) and folded == -1 then
              y = math.max(y, row_after(win, info, lnum) + it.p.height - 1)
            end
          end
          for _, it in ipairs(items) do
            local p = it.p
            local sp = vim.fn.screenpos(win, it.row + 1, it.col + 1)
            local py = y
            if in_place(p) then
              py = sp.row > 0 and sp.row or nil
            else
              y = y + p.height
            end
            local x
            if p.align == "center" then
              x = left + math.floor((right - left + 1 - p.width) / 2)
            elseif p.align == "right" then
              x = right - p.width + 1
            else
              x = sp.col > 0 and sp.col - concealed_before(win, bufnr, it.row + 1, it.col, list) or left
            end
            x = math.max(left, math.min(x, right - p.width + 1))
            -- an image wider than this window (sized for another one, or
            -- before a resize) would cover the window next to it
            local visible = py ~= nil and py >= top and py + p.height - 1 <= bottom and x + p.width - 1 <= right
            for _, r in ipairs(rects) do
              -- a float covers the windows under it, not itself
              if visible and r.win ~= win and (not is_float or r.z > (cfg.zindex or 50)) then
                visible = not hidden_by(r, py, x, p.width, p.height)
              end
            end
            if visible then
              want[win .. ":" .. p.id] = {
                src = p.src,
                opts = { row = py, col = x, width = p.width, height = p.height, zindex = 50 },
              }
            end
          end
        end
      end
    end
  end
  return want
end

local function same(a, b)
  return a.row == b.row and a.col == b.col and a.width == b.width and a.height == b.height
end

--- Place, move and remove native images to match `_layout()`.
function M.sync(force)
  local img = M._img or native_img()
  if not img then
    return
  end
  -- a fold opened or closed since: show the text of the images on the
  -- first line of a closed fold
  M._update_reveal()
  local want = M._layout()
  for key, cur in pairs(placed) do
    if force or not want[key] then
      pcall(img.del, cur.id)
      placed[key] = nil
    end
  end
  local used = {}
  for key, w in pairs(want) do
    used[w.src] = true
    local cur = placed[key]
    if cur then
      if not same(cur.opts, w.opts) then
        pcall(img.set, cur.id, w.opts)
        cur.opts = w.opts
      end
    else
      local data = data_cache[w.src]
      if not data then
        local ok, blob = pcall(vim.fn.readblob, w.src)
        data = ok and blob or nil
        data_cache[w.src] = data
      end
      if data then
        local ok, id = pcall(img.set, data, w.opts)
        if ok then
          placed[key] = { id = id, opts = w.opts }
        end
      end
    end
  end
  -- forget the bytes of images no preview uses any more
  for src in pairs(data_cache) do
    local live = used[src]
    for _, list in pairs(previews) do
      for _, p in pairs(list) do
        live = live or p.src == src
      end
    end
    if not live then
      data_cache[src] = nil
    end
  end
end

local sync_pending = false
function M._schedule_sync()
  if sync_pending then
    return
  end
  sync_pending = true
  vim.schedule(function()
    sync_pending = false
    local any = next(placed) ~= nil
    for _, list in pairs(previews) do
      for _, p in pairs(list) do
        any = any or p.backend == "native"
      end
    end
    if any then
      M.sync()
    end
  end)
end

-- Every redraw may have moved the lines: place the images again (only the
-- ones that moved are sent to the terminal).
vim.api.nvim_set_decoration_provider(ns, {
  on_end = function()
    if next(previews) or next(placed) then
      M._schedule_sync()
    end
  end,
})

--- Show the text of the images drawn in place on the cursor line of the
--- current window (their image goes under the line, so the link or
--- fragment can be edited), and hide it again on the other lines.
function M._update_reveal()
  for bufnr, list in pairs(previews) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, p in pairs(list) do
        local r, _, d
        if p.inline then
          r, _, d = mark_pos(bufnr, p.mark)
        end
        if r then
          local want = want_revealed(bufnr, p.backend, p.height, r, d and d.end_row or r)
          if want ~= (p.revealed == true) then
            local b = backend_of(p)
            pcall(b.hide, bufnr, p)
            p.revealed = want
            pcall(show, b, bufnr, p)
            M._schedule_sync()
          end
        end
      end
    end
  end
end

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("org.images.reveal", { clear = true }),
  callback = function()
    if next(previews) then
      M._update_reveal()
    end
  end,
})

local attached = {}

--- Watch the buffer: an edit inside a previewed link or fragment removes
--- its preview (org-link-preview--remove-overlay).
function M.attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  local group = vim.api.nvim_create_augroup("org.images." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      for id, p in pairs(previews[bufnr] or {}) do
        local now = mark_text(bufnr, p.mark)
        if not now or (p.text and now ~= p.text) then
          remove(bufnr, id)
        end
      end
      -- lines split or joined: the rows under them again
      restack_all(bufnr)
      M._update_reveal()
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- image.nvim previews made while no window showed the buffer
      for _, p in pairs(previews[bufnr] or {}) do
        local b = backend_of(p)
        if p.deferred and b and mark_pos(bufnr, p.mark) then
          p.deferred = nil
          pcall(show, b, bufnr, p)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      for id in pairs(previews[bufnr] or {}) do
        remove(bufnr, id)
      end
      previews[bufnr] = nil
      pending[bufnr] = nil
      drop_waiting(bufnr)
      lwaiting[bufnr], lqueue[bufnr] = nil, nil
      attached[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

--- Called for every org buffer: show startup previews once it is visible
--- (org-startup-with-link-previews, org-startup-with-latex-preview).
function M.setup_buffer(bufnr)
  local links, latex = startup(bufnr)
  if not links and not latex then
    return
  end
  local function go()
    if links then
      M.show_links(bufnr, 1, math.huge)
    end
    if latex then
      M.show_latex(bufnr, 1, math.huge)
    end
  end
  if vim.fn.bufwinid(bufnr) ~= -1 then
    vim.schedule(go)
  else
    vim.api.nvim_create_autocmd("BufWinEnter", { buffer = bufnr, once = true, callback = vim.schedule_wrap(go) })
  end
end

-- A floating window (a menu waiting for a key) or the popup menu must not
-- be covered by an image: place them at once, a scheduled sync would only
-- run after the key.
vim.api.nvim_create_autocmd({ "WinNew", "CompleteChanged", "CompleteDone" }, {
  group = vim.api.nvim_create_augroup("org.images.floats", { clear = true }),
  callback = function()
    if next(placed) then
      pcall(M.sync)
    end
  end,
})

-- The terminal forgets images when the screen is cleared or resized, and
-- the cell size may have changed with the font.
vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "VimResume", "FocusGained", "UIEnter" }, {
  group = vim.api.nvim_create_augroup("org.images", { clear = true }),
  callback = function(ev)
    if ev.event == "VimResized" then
      cell.asked = false
      ask_cell_size()
    end
    if next(placed) or next(previews) then
      vim.schedule(function()
        M.refit(ev.event == "WinResized")
      end)
    end
  end,
})

shared.clear_data_cache = clear_data_cache
