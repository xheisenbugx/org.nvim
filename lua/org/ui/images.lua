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

--- `#+STARTUP` words of the buffer in order: the last of a pair wins.
local function startup(bufnr)
  local links, latex = opts().startup, latex_opts().startup
  local settings = require("org.files").get_buffer(bufnr).settings.keywords.STARTUP or {}
  for _, words in ipairs(settings) do
    for w in words:lower():gmatch("%S+") do
      if w == "inlineimages" or w == "linkpreviews" then
        links = true
      elseif w == "noinlineimages" or w == "nolinkpreviews" then
        links = false
      elseif w == "latexpreview" then
        latex = true
      elseif w == "nolatexpreview" then
        latex = false
      end
    end
  end
  return links, latex
end

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
      local sz = ffi.new("org_winsize")
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

--- Pixel size of a PNG file, from its IHDR chunk.
---@return integer? width, integer? height
function M.png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(i)
    local a, b, c, d = head:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
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
