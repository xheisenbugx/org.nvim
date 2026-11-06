---@mod org.ui.images Inline image and LaTeX previews
---
--- org-link-preview (image links shown under the link) and
--- org-latex-preview (LaTeX fragments rendered to images). The images are
--- drawn by a backend, chosen with `ui.images.backend`:
---
---   "native"      `vim.ui.img` (Neovim 0.13+), in terminals that speak the
---                 Kitty graphics protocol (kitty, Ghostty, WezTerm...).
---   "snacks"      Snacks.image (folke/snacks.nvim), for older Neovim or
---                 terminals the native backend can't reach (tmux).
---   "image.nvim"  3rd/image.nvim.
---
--- "auto" (the default) uses the first one that works. Like Emacs, an image
--- is drawn in place of its link or fragment (`ui.images.placement`
--- "inline"): the text is concealed behind blank inline text as wide as
--- the image, and shows again (with the image under it) while the cursor is
--- on its line. The other lines of a fragment over several lines are hidden
--- (`conceal_lines`, Neovim 0.11+). With the native backend, the rows the image needs under the
--- line are reserved with virtual lines and the images are placed on the
--- screen after every redraw, so they follow scrolling, folding and window
--- changes.
---
--- This file holds the options, the terminal cell size and the image file
--- helpers the parts share; it loads the rest from org/ui/images/: scan
--- (the elements of a buffer), links (image links, preview functions),
--- latex (fragments, rendering), backends, preview (adding and removing
--- previews), place (native placement after every redraw, the autocommands)
--- and commands.

local config = require("org.config")
local utils = require("org.utils")

local M = {}
-- The parts in org/ui/images/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.ui.images"] = M

local ns = vim.api.nvim_create_namespace("org.images")

--- Image file extensions previewed by default (Emacs `image-file-name-regexp`).
M.IMAGE_EXTENSIONS = {
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "bmp",
  "svg",
  "tif",
  "tiff",
  "avif",
  "xbm",
  "xpm",
  "pbm",
  "pgm",
  "ppm",
  "pnm",
}

---@class org.images.Preview
---@field id integer
---@field kind "link"|"latex"
---@field mark integer extmark on the link / fragment (tracks edits)
---@field text string the link / fragment text when previewed
---@field src string PNG (native) or source image file
---@field width integer cells
---@field height integer cells
---@field align? "center"|"right"
---@field size table what the size was computed from (see `size_of`)
---@field lines? integer extmark reserving the space under the line (native)
---@field inline? boolean drawn in place of its text
---@field multi? boolean its text spans several lines
---@field revealed? boolean its text shown (the cursor is on it): drawn below
---@field pad? integer extmark concealing the text in place (native)
---@field fold? integer extmark hiding the other lines of its text (native)
---@field shown? boolean shown by the native backend
---@field handle? any snacks / image.nvim object
---@field backend string

---@type table<integer, table<integer, org.images.Preview>>
local previews = {}

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function opts()
  return config.opts.ui.images or {}
end

local function latex_opts()
  return config.opts.ui.latex_preview or {}
end

-- `#+STARTUP` words of the buffer (org.ui.images.startup)
local startup = require("org.ui.images.startup").startup

---------------------------------------------------------------------------
-- Terminal cell size
---------------------------------------------------------------------------

-- Pixel size of a terminal cell: from the terminal's window size
-- (TIOCGWINSZ), else asked with `CSI 16 t`, else a common 10x20.
local cell = { w = 10, h = 20, asked = false }

--- Cell size from ioctl(TIOCGWINSZ) on the terminal, like snacks.nvim.
local function ioctl_cell_size()
  local request = (vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1) and 0x40087468
    or (vim.fn.has("linux") == 1 and 0x5413)
    or nil
  local ok_ffi, ffi = pcall(require, "ffi")
  if not request or not ok_ffi then
    return nil
  end
  pcall(
    ffi.cdef,
    [[
    typedef struct { unsigned short row, col, xpixel, ypixel; } org_winsize;
    int ioctl(int, unsigned long, ...);
  ]]
  )
  for _, fd in ipairs({ 1, 0, 2 }) do
    local ok, w, h = pcall(function()
      local sz = ffi.new("org_winsize") --[[@as { row: integer, col: integer, xpixel: integer, ypixel: integer }]]
      if ffi.C.ioctl(fd, request, sz) ~= 0 or sz.col == 0 or sz.row == 0 or sz.xpixel == 0 then
        return nil
      end
      return sz.xpixel / sz.col, sz.ypixel / sz.row
    end)
    if ok and w then
      return w, h
    end
  end
end

local function ask_cell_size()
  if cell.asked or #vim.api.nvim_list_uis() == 0 then
    return
  end
  cell.asked = true
  local w, h = ioctl_cell_size()
  if w then
    cell.w, cell.h = w, h
    return
  end
  local ok, tty = pcall(require, "vim.tty")
  if not ok or type(tty.request) ~= "function" then
    return
  end
  pcall(tty.request, "\27[16t", { timeout = 1000 }, function(resp)
    local ph, pw = resp:match("^\27%[6;(%d+);(%d+)t")
    if ph then
      cell.h, cell.w = tonumber(ph), tonumber(pw)
      vim.schedule(M.refit)
      return true
    end
  end)
end

---@return { w: number, h: number }
function M.cell_size()
  return { w = cell.w, h = cell.h }
end

---------------------------------------------------------------------------
-- Image files
---------------------------------------------------------------------------

local function u16be(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

local function u16le(s, i)
  local a, b = s:byte(i, i + 1)
  return b * 256 + a
end

local function u24le(s, i)
  local a, b, c = s:byte(i, i + 2)
  return (c * 256 + b) * 256 + a
end

local function u32le(s, i)
  return u16le(s, i + 2) * 65536 + u16le(s, i)
end

--- Pixel size of a JPEG from its first SOF segment: the markers before it
--- (APPn, EXIF, tables) are skipped by their lengths.
---@param f file*
---@return integer? width, integer? height
local function jpeg_size(f)
  local pos = 2
  while true do
    f:seek("set", pos)
    local seg = f:read(9)
    if not seg or #seg < 4 or seg:byte(1) ~= 0xFF then
      return nil
    end
    local marker = seg:byte(2)
    if marker == 0xFF then
      -- fill byte before the marker
      pos = pos + 1
    elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
      -- TEM, RSTn, SOI: no length
      pos = pos + 2
    elseif marker == 0xD9 or marker == 0xDA then
      -- EOI, or SOS (the image data) before any SOF
      return nil
    elseif marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
      if #seg < 9 then
        return nil
      end
      return u16be(seg, 8), u16be(seg, 6)
    else
      pos = pos + 2 + u16be(seg, 3)
    end
  end
end

--- Pixel size of a PNG, JPEG, GIF, BMP or WebP file, from its header
--- (Emacs shows an image at its own size whatever its format). nil for
--- another format or a file that can't be read.
---@param path string
---@return integer? width, integer? height
function M.image_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(30) or ""
  local w, h
  if head:sub(1, 8) == "\137PNG\r\n\26\n" and #head >= 24 then
    w, h = u16be(head, 17) * 65536 + u16be(head, 19), u16be(head, 21) * 65536 + u16be(head, 23)
  elseif head:sub(1, 2) == "\255\216" then
    w, h = jpeg_size(f)
  elseif head:match("^GIF8[79]a") and #head >= 10 then
    w, h = u16le(head, 7), u16le(head, 9)
  elseif head:sub(1, 2) == "BM" and #head >= 26 then
    if u32le(head, 15) == 12 then
      w, h = u16le(head, 19), u16le(head, 21)
    else
      w, h = u32le(head, 19), u32le(head, 23)
      -- a negative height: the rows are stored top-down
      h = h >= 2147483648 and 4294967296 - h or h
    end
  elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
    local chunk = head:sub(13, 16)
    if chunk == "VP8 " and #head >= 30 and head:sub(24, 26) == "\157\1\42" then
      w, h = u16le(head, 27) % 16384, u16le(head, 29) % 16384
    elseif chunk == "VP8L" and #head >= 25 and head:byte(21) == 0x2F then
      local bits = u32le(head, 22)
      w, h = bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
    elseif chunk == "VP8X" and #head >= 30 then
      w, h = u24le(head, 25) + 1, u24le(head, 28) + 1
    end
  end
  f:close()
  if w and h and w > 0 and h > 0 then
    return w, h
  end
  return nil
end

--- Pixel size of a PNG file, from its IHDR chunk.
---@param path string
---@return integer? width, integer? height
function M.png_size(path)
  local f = io.open(path, "rb")
  local head = f and f:read(8)
  if f then
    f:close()
  end
  if head ~= "\137PNG\r\n\26\n" then
    return nil
  end
  return M.image_size(path)
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

--- ImageMagick's command: `magick`, or `convert` (not on Windows, where
--- convert.exe is a disk tool).
local function magick_cmd()
  if executable("magick") then
    return "magick"
  elseif vim.fn.has("win32") == 0 and executable("convert") then
    return "convert"
  end
end

local function cache_root()
  local dir = vim.fn.stdpath("cache") .. "/org/ltximg"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- A PNG for `path`: the file itself, or a copy converted with ImageMagick
--- (the native backend only draws PNG). nil when it can't be converted.
local function as_png(path)
  if path:lower():match("%.png$") then
    return path
  end
  local magick = magick_cmd()
  if not magick then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  local key = utils.sha256(path .. ":" .. (st and st.mtime.sec or 0))
  local out = cache_root() .. "/img-" .. key:sub(1, 20) .. ".png"
  if vim.uv.fs_stat(out) then
    return out
  end
  local tmp = out .. ".tmp.png"
  local res = vim.system({ magick, path .. "[0]", tmp }):wait()
  if res.code ~= 0 or not vim.uv.fs_stat(tmp) then
    return nil
  end
  vim.uv.fs_rename(tmp, out)
  return out
end

--- Size in cells of an image of `pw` x `ph` pixels: `want_w` columns (or
--- its natural size), scaled down to fit `max_w` x `max_h` cells, keeping
--- the aspect ratio.
function M.fit(pw, ph, max_w, max_h, want_w)
  local cs = M.cell_size()
  local w = want_w or math.ceil(pw / cs.w)
  local h = math.ceil(w * cs.w * ph / pw / cs.h)
  if max_w and w > max_w then
    w = max_w
    h = math.ceil(w * cs.w * ph / pw / cs.h)
  end
  if max_h and h > max_h then
    h = max_h
    w = math.max(1, math.floor(h * cs.h * pw / ph / cs.w))
  end
  return math.max(1, w), math.max(1, h)
end

local function win_info(win)
  return vim.fn.getwininfo(win)[1]
end

--- Columns of text in window `win`.
local function text_columns(win)
  local info = win_info(win)
  return info and math.max(1, info.width - info.textoff) or 80
end

--- The window previews of `bufnr` are sized for: the current window when
--- it shows the buffer, else the first one that does (-1: none).
local function buf_win(bufnr)
  if vim.api.nvim_get_current_buf() == bufnr then
    return vim.api.nvim_get_current_win()
  end
  return vim.fn.bufwinid(bufnr)
end

--- The fill column: 'textwidth', or 70 like Emacs `fill-column`.
local function fill_column(bufnr)
  local tw = vim.bo[bufnr].textwidth
  return tw > 0 and tw or 70
end

--- Widest image in columns (org-image-max-width): "fill-column", "window",
--- an integer number of pixels, a fraction of the window, or nil/false (no
--- limit but the window).
local function max_width(win)
  local o = opts().max_width
  local room = text_columns(win) - 1
  local w = room
  if o == "fill-column" then
    w = fill_column(vim.api.nvim_win_get_buf(win))
  elseif type(o) == "number" and o > 0 and o < 1 then
    w = math.floor(room * o)
  elseif type(o) == "number" and o >= 1 then
    w = math.floor(o / cell.w)
  end
  return math.max(1, math.min(w, room))
end

-- Local functions the parts below share
local shared = require("org.ui.images.shared")
shared.as_png = as_png
shared.ask_cell_size = ask_cell_size
shared.buf_win = buf_win
shared.cache_root = cache_root
shared.cell = cell
shared.executable = executable
shared.latex_opts = latex_opts
shared.magick_cmd = magick_cmd
shared.max_width = max_width
shared.ns = ns
shared.opts = opts
shared.previews = previews
shared.startup = startup
shared.text_columns = text_columns
shared.win_info = win_info

require("org.ui.images.scan")
require("org.ui.images.links")
require("org.ui.images.latex")
require("org.ui.images.backends")
require("org.ui.images.preview")
require("org.ui.images.place")
require("org.ui.images.commands")

return M
