---@mod org.ui.images.backends Image backends
---
--- The native (vim.ui.img), snacks and image.nvim backends.
--- Part of org.ui.images, which loads it.

local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local ns = shared.ns
local opts = shared.opts
local previews = shared.previews

---------------------------------------------------------------------------
-- Backends
---------------------------------------------------------------------------

---@class org.images.Backend
---@field name string
--- `row`/`col`: the end of the link or fragment (where the native backend
--- reserves its rows); `x`: the column the image starts at; `start_row`:
--- the first row of the link or fragment.
---@field show fun(bufnr: integer, p: org.images.Preview, row: integer, col: integer, x: integer, start_row: integer)
---@field hide fun(bufnr: integer, p: org.images.Preview)
---@field needs_png? boolean
---@field inline? boolean can draw images in place of their text

local backends = {}
M._backends = backends

--- Position of extmark `mark`: row, col, details (nil when it was deleted
--- or its text was).
local function mark_pos(bufnr, mark)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, { details = true })
  if not m[1] or (m[3] and m[3].invalid) then
    return nil
  end
  return m[1], m[2], m[3]
end

local function native_img()
  local ok, img = pcall(function()
    return vim.ui.img
  end)
  if ok and type(img) == "table" and type(img.set) == "function" then
    return img
  end
end

local native_ok ---@type boolean?

--- Whether `vim.ui.img` exists and the terminal answers the Kitty graphics
--- query (asked once, blocking up to 1 s like `vim.ui.img._supported`).
local function native_supported()
  if native_ok ~= nil then
    return native_ok
  end
  local img = native_img()
  if not img or #vim.api.nvim_list_uis() == 0 then
    native_ok = false
  elseif type(img._supported) == "function" then
    local ok, res = pcall(img._supported, { timeout = 1000 })
    native_ok = ok and res == true
  else
    native_ok = true
  end
  return native_ok
end

--- Whether preview `p` is drawn in place of its text right now.
local function in_place(p)
  return p.inline and not p.revealed and not p.below
end

--- Hidden text needs 'conceallevel' 2 in the windows showing `bufnr`.
local function ensure_conceal(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].conceallevel < 2 then
      vim.wo[win].conceallevel = 2
    end
  end
end

--- The row the native rows of `p` hang from: the last row of its text, or
--- its first row when a fragment over several lines is drawn in place (its
--- other lines are hidden).
local function anchor_of(bufnr, p)
  local r, _, d = mark_pos(bufnr, p.mark)
  if r and p.multi and in_place(p) then
    return r
  end
  return r and (d and d.end_row or r)
end

--- Reserve the rows under `row` for its native previews: images in place
--- of their text share the rows under the line (the tallest one's height
--- less the line itself), images below the line are stacked after them.
--- The virtual lines sit at the end of each link, so splitting the line
--- before it moves them along.
local function restack(bufnr, row)
  if not row or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local items = {}
  for _, q in pairs(previews[bufnr] or {}) do
    if q.shown and q.backend == "native" and anchor_of(bufnr, q) == row then
      items[#items + 1] = q
    end
  end
  table.sort(items, function(a, b)
    return a.id < b.id
  end)
  local extra, carrier = 0, nil
  for _, q in ipairs(items) do
    if in_place(q) then
      carrier = carrier or q
      extra = math.max(extra, q.height - 1)
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  for _, q in ipairs(items) do
    local n = q.height
    if in_place(q) then
      n = q == carrier and extra or 0
    end
    if n == 0 then
      if q.lines then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, q.lines)
        q.lines = nil
      end
    else
      local vl = {}
      for _ = 1, n do
        vl[#vl + 1] = { { "", "Normal" } }
      end
      local _, c, d = mark_pos(bufnr, q.mark)
      q.lines = vim.api.nvim_buf_set_extmark(bufnr, ns, row, math.min(d and d.end_col or c, #line), {
        id = q.lines,
        virt_lines = vl,
        right_gravity = false,
        invalidate = true,
        undo_restore = false,
      })
    end
  end
end

--- Restack every row of `bufnr` holding native previews.
local function restack_all(bufnr)
  local rows = {}
  for _, q in pairs(previews[bufnr] or {}) do
    local r = q.shown and anchor_of(bufnr, q)
    if r then
      rows[r] = true
    end
  end
  for r in pairs(rows) do
    restack(bufnr, r)
  end
end

-- Native: images are placed on the screen by `sync()`; `show`/`hide` only
-- hide the text of an image drawn in place (concealed, with blank inline
-- text as wide as the image) and reserve (or free) the rows under the line.
backends.native = {
  name = "native",
  needs_png = true,
  inline = true,
  show = function(bufnr, p, row, col, x, start_row)
    if in_place(p) and row > start_row then
      -- over several lines: the first line's text from the fragment on is
      -- concealed behind the blank columns (and the text after the
      -- fragment on its last line), the other lines are not drawn
      local first = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
      local last = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local vt = { { string.rep(" ", p.width) } }
      if col < #last then
        vt[2] = { last:sub(col + 1) }
      end
      p.pad = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, x, {
        id = p.pad,
        end_row = start_row,
        end_col = #first,
        conceal = "",
        virt_text = vt,
        virt_text_pos = "inline",
        invalidate = true,
        undo_restore = false,
      })
      p.fold = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row + 1, 0, {
        id = p.fold,
        end_row = row,
        end_col = #last,
        conceal_lines = "",
        invalidate = true,
        undo_restore = false,
      })
      ensure_conceal(bufnr)
    elseif in_place(p) then
      p.pad = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, x, {
        id = p.pad,
        end_row = row,
        end_col = col,
        conceal = "",
        virt_text = { { string.rep(" ", p.width) } },
        virt_text_pos = "inline",
        invalidate = true,
        undo_restore = false,
      })
      ensure_conceal(bufnr)
    end
    p.shown = true
    restack(bufnr, anchor_of(bufnr, p))
  end,
  hide = function(bufnr, p)
    local row = anchor_of(bufnr, p)
    p.shown = false
    for _, key in ipairs({ "pad", "fold", "lines" }) do
      if p[key] then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p[key])
        p[key] = nil
      end
    end
    restack(bufnr, row)
  end,
}

backends.snacks = {
  name = "snacks",
  inline = true,
  show = function(bufnr, p, row, col, x, start_row)
    p.handle = Snacks.image.placement.new(bufnr, p.src, {
      pos = { start_row + 1, x },
      -- the whole link: snacks then draws the image under it, at its column
      range = { start_row + 1, x, row + 1, col },
      inline = true,
      -- in place: snacks hides the text and draws over it (the lines of
      -- a fragment over several lines too)
      conceal = in_place(p),
      auto_resize = true,
      max_width = p.width,
      max_height = p.height,
    })
  end,
  hide = function(_, p)
    if p.handle then
      pcall(p.handle.close, p.handle)
      p.handle = nil
    end
  end,
}

backends["image.nvim"] = {
  name = "image.nvim",
  show = function(bufnr, p, row, _, x)
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      -- image.nvim needs a window; show it when the buffer is displayed
      p.deferred = true
      return
    end
    local image = require("image").from_file(p.src, {
      window = win,
      buffer = bufnr,
      inline = true,
      with_virtual_padding = true,
      x = x,
      y = row,
      width = p.width,
      height = p.height,
    })
    if image then
      image:render()
      p.handle = image
    end
  end,
  hide = function(_, p)
    p.deferred = nil
    if p.handle then
      pcall(p.handle.clear, p.handle)
      p.handle = nil
    end
  end,
}

local function snacks_ok()
  if type(_G.Snacks) ~= "table" then
    return false
  end
  local ok, res = pcall(function()
    local term = Snacks.image.terminal
    local env = term and term.env and term.env() or {}
    -- without unicode placeholders snacks draws at the window's corner
    return Snacks.image.placement ~= nil and Snacks.image.supports_terminal() and env.placeholders ~= false
  end)
  return ok and res == true
end

local function image_nvim_ok()
  return package.loaded["image"] ~= nil or pcall(require, "image")
end

--- The backend in use, or nil and why there is none.
---@return org.images.Backend?, string?
function M.backend()
  if M._backend then
    return M._backend
  end
  local want = opts().backend
  if want == nil then
    want = "auto"
  end
  if want == false then
    return nil, "image previews are disabled (ui.images.backend = false)"
  end
  local checks = {
    native = native_supported,
    snacks = snacks_ok,
    ["image.nvim"] = image_nvim_ok,
  }
  if want ~= "auto" then
    if not checks[want] then
      return nil, "unknown image backend: " .. tostring(want)
    end
    if checks[want]() then
      return backends[want]
    end
    return nil, "the " .. want .. " image backend is not available in this Neovim or terminal"
  end
  for _, name in ipairs({ "native", "snacks", "image.nvim" }) do
    if checks[name]() then
      return backends[name]
    end
  end
  if native_img() then
    if vim.env.TMUX or vim.env.ZELLIJ then
      return nil,
        (vim.env.TMUX and "tmux" or "zellij")
          .. " does not pass vim.ui.img images to the terminal, and no other image backend is available"
    end
    return nil, "this terminal does not support the Kitty graphics protocol (vim.ui.img)"
  end
  return nil, "no image backend: needs Neovim 0.13+ in a Kitty-graphics terminal, snacks.nvim (image) or image.nvim"
end

--- A description of the backend for `:checkhealth org`.
function M.status()
  local b, why = M.backend()
  return b and b.name or nil, why
end

shared.anchor_of = anchor_of
shared.backends = backends
shared.in_place = in_place
shared.mark_pos = mark_pos
shared.native_img = native_img
shared.restack_all = restack_all
