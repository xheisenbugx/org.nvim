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
--- "auto" (the default) uses the first one that works. With the native
--- backend, the space under a line is reserved with virtual lines and the
--- images are placed on the screen after every redraw, so they follow
--- scrolling, folding and window changes.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

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
---@field handle? any snacks / image.nvim object
---@field backend string

---@type table<integer, table<integer, org.images.Preview>>
local previews = {}
local next_id = 0

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
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local words = l:match("^%s*#%+[sS][tT][aA][rR][tT][uU][pP]:(.*)$")
    for w in (words or ""):gmatch("%S+") do
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
  local key = vim.fn.sha256(path .. ":" .. (st and st.mtime.sec or 0))
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

---------------------------------------------------------------------------
-- The elements of a buffer (just enough of org-element)
---------------------------------------------------------------------------

local OPAQUE_BLOCKS = { src = true, example = true, export = true, comment = true }
local PARSED_KEYWORDS = { title = true, caption = true, author = true, date = true, subtitle = true }
local AFFILIATED =
  { attr = true, name = true, caption = true, header = true, plot = true, results = true, label = true }

---@class org.images.Line
---@field skip? boolean no links or LaTeX fragments here
---@field para? integer paragraph id
---@field env? integer LaTeX environment id

--- Per line: what may hold previews, which paragraph it belongs to, and
--- the paragraphs' affiliated keywords (#+ATTR_ORG ...). Paragraphs of list
--- items get no keywords (those belong to the list).
---@return org.images.Line[] lines, table<integer, { first: integer, last: integer, attrs: string[] }> paras, table<integer, { first: integer, last: integer, name: string }> envs
function M.scan(lines)
  local info, paras, envs = {}, {}, {}
  local block, dynamic, props = nil, false, false
  local pending = {} -- affiliated keyword lines waiting for their element
  local para -- current paragraph
  local function other(li, keep_pending)
    -- a line that is not part of a paragraph
    para = nil
    if not keep_pending then
      pending = {}
    end
    return li
  end
  local function text(li, i)
    if not para then
      para = #paras + 1
      paras[para] = { first = i, last = i, attrs = pending }
      pending = {}
    end
    paras[para].last = i
    li.para = para
  end
  local i = 1
  while i <= #lines do
    local l = lines[i]
    local low = l:lower()
    local li = {}
    info[i] = li
    local key = low:match("^%s*#%+([%w_-]+)%[?[^:]*%]?:")
    local env = l:match("^[ \t]*\\begin{([%w*]+)}")
    local stop
    if env and not block and not props then
      for r = i + 1, #lines do
        if lines[r]:match("^%*+%s") then
          break
        end
        if lines[r]:lower():match("^[ \t]*\\end{" .. vim.pesc(env:lower()) .. "}[ \t]*$") then
          stop = r
          break
        end
      end
    end
    if block then
      if low:match("^%s*#%+end_" .. vim.pesc(block) .. "%f[^%w_-]") then
        li.skip = true
        block = nil
        other(li)
      elseif OPAQUE_BLOCKS[block] then
        li.skip = true
      elseif l:match("^%s*$") then
        other(li)
      else
        text(li, i)
      end
    elseif props then
      li.skip = true
      if low:match("^%s*:end:%s*$") then
        props = false
      end
    elseif low:match("^%s*#%+begin_([%w_-]+)") then
      li.skip = true
      block = low:match("^%s*#%+begin_([%w_-]+)")
      other(li)
    elseif low:match("^%s*#%+begin:") then
      li.skip, dynamic = true, true
      other(li)
    elseif dynamic and low:match("^%s*#%+end:") then
      li.skip, dynamic = true, false
      other(li)
    elseif key then
      local base = key:match("^attr_") and "attr" or key
      -- links and fragments show in parsed keywords (TITLE, CAPTION...)
      li.skip = not PARSED_KEYWORDS[key] or nil
      if AFFILIATED[base] then
        pending[#pending + 1] = l
        other(li, true)
      else
        other(li)
      end
    elseif l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%s*:%s") or l:match("^%s*:$") then
      li.skip = true -- comments, fixed-width lines
      other(li)
    elseif low:match("^%s*:properties:%s*$") then
      li.skip, props = true, true
      other(li)
    elseif l:match("^%s*:[%w_-]+:%s*$") or l:match("^%s*%-%-%-%-%-+%s*$") or l:match("^%s*CLOCK:") then
      li.skip = true -- drawer delimiters, rules, clock lines
      other(li)
    elseif l:match("^%s*$") then
      other(li)
    elseif stop then
      envs[#envs + 1] = { first = i, last = stop, name = env }
      for r = i, stop do
        info[r] = { env = #envs, skip = true }
      end
      other(li)
      i = stop
    elseif l:match("^%*+%s") or l:match("^%s*|") or l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") then
      -- headlines and table rows hold objects but no paragraph
      other(li)
    elseif l:match("^%s*[-+]%s") or l:match("^%s+%*%s") or l:match("^%s*%d+[.)]%s") or l:match("^%s*%a[.)]%s") then
      -- a list item starts a paragraph of its own; the keywords above
      -- belong to the list
      para = #paras + 1
      paras[para] = { first = i, last = i, attrs = {} }
      li.para = para
      pending = {}
    else
      text(li, i)
    end
    i = i + 1
  end
  return info, paras, envs
end

---------------------------------------------------------------------------
-- Image links
---------------------------------------------------------------------------

local function is_image(path, exts)
  local ext = path:match("%.([%w]+)$")
  return ext and vim.tbl_contains(exts, ext:lower())
end

--- `:width` (or `:align`, `:center`) of an #+ATTR_x line, as written.
local function attr_value(line, key)
  local v = line:match(":" .. key .. "%s+([^%s]+)")
  return v
end

--- Whether an ATTR :width value can be read (org-display-inline-image--width).
local function width_readable(v)
  if type(v) ~= "string" then
    return false
  end
  if v == "t" then
    return true
  end
  local s = v:gsub("^%+", "")
  local n = tonumber(s:match("^[%d.]+"))
  if s:match("^%d+$") or s:match("^%d+px$") then
    return true
  elseif s:match("^[%d.]+%%") then
    return true
  elseif s:match("^%d*%.%d+") then
    return n ~= nil and n >= 0 and n <= 2
  end
  return false
end

--- The value of `ui.images.actual_width` for `row`, or of an inherited
--- ORG-IMAGE-ACTUAL-WIDTH property (org-property-or-variable-value).
local function actual_width(bufnr, row)
  local v = opts().actual_width
  if v == nil then
    v = true
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  if ok then
    local hl = file:headline_at(row)
    local p = hl and hl:get_property("ORG-IMAGE-ACTUAL-WIDTH", true)
      or (file.settings.properties or {})["ORG-IMAGE-ACTUAL-WIDTH"]
    if p then
      p = vim.trim(p)
      if p == "t" then
        v = true
      elseif p == "nil" then
        v = false
      elseif p:match("^%(%s*[%d.]+%s*%)$") then
        v = { tonumber(p:match("[%d.]+")) }
      elseif tonumber(p) then
        v = tonumber(p)
      end
    end
  end
  return v
end

--- The width an image link asks for: nil (its natural size), `{ px = n }`
--- or `{ fraction = f }` of the text width (org-display-inline-image--width).
function M.image_width(bufnr, row, attrs)
  local actual = actual_width(bufnr, row)
  if actual == true then
    return nil
  elseif type(actual) == "number" then
    return { px = actual }
  end
  -- nil or a list: #+ATTR_ORG, else another #+ATTR_x, else the list's car
  local org_w, other_w
  for _, a in ipairs(attrs or {}) do
    local backend = a:lower():match("^%s*#%+attr_([%w_-]+):")
    if backend then
      local v = attr_value(a, "width")
      if backend == "org" then
        org_w = org_w or v
      elseif not other_w and width_readable(v) then
        other_w = v
      end
    end
  end
  local w = width_readable(org_w) and org_w or other_w
  local n
  if w == "t" then
    return nil
  elseif not width_readable(w) then
    n = type(actual) == "table" and actual[1] or nil
  elseif w:match("^%+?[%d.]+%%") then
    n = tonumber(w:match("[%d.]+")) / 100
    return { fraction = n }
  else
    n = tonumber((w:gsub("^%+", ""):match("^[%d.]+")))
    if w:match("^%+?%d*%.%d") then
      return { fraction = n }
    end
  end
  return n and { px = n } or nil
end

--- "center" or "right" for a stand-alone image link (org-image--align).
function M.image_align(lines, lk, para)
  if not para or para.first ~= para.last then
    return nil
  end
  local line = lines[para.first]
  local before, after = line:sub(1, lk.col), line:sub(lk.end_col + 1)
  if not before:match("^%s*$") or not after:match("^%s*$") then
    return nil
  end
  local found
  for _, a in ipairs(para.attrs) do
    local backend = a:lower():match("^%s*#%+attr_([%w_-]+):")
    if backend then
      local v = (a:match(":center%s+t%f[%W]") and "center") or attr_value(a, "align")
      if v == "left" or v == "center" or v == "right" then
        found = v
        if backend == "org" then
          break
        end
      end
    end
  end
  if found then
    return (found == "center" or found == "right") and found or nil
  end
  local g = opts().align
  return (g == "center" or g == "right") and g or nil
end

local function link_file(bufnr, row, lk)
  local links = require("org.links")
  local path = (lk.path or ""):gsub("::.*$", "")
  if lk.type == "file" then
    return links.resolve_path(path, bufnr)
  elseif lk.type == "attachment" then
    local ok, p = pcall(require("org.attach").resolve_attachment, path, { bufnr = bufnr, lnum = row })
    return ok and p or nil
  end
end

--- A description that is a sole plain or angle file/attachment link.
local function description_link(desc)
  local d = vim.trim(desc or "")
  local target = d:match("^<([^<>]+)>$") or d
  local scheme, rest = target:match("^(%a+):(%S+)$")
  if scheme and (scheme:lower() == "file" or scheme:lower() == "attachment") then
    return { type = scheme:lower(), path = rest }
  end
end

--- Image links of rows `first..last` (1-based), in the range `range`
--- ({ row, col, end_row, end_col }, 0-based columns) when given. Like
--- org-link-preview-region: file and attachment links to image files,
--- without a description unless `include_linked`, or whose description is
--- a sole image link.
---@return { row: integer, col: integer, end_col: integer, path: string, text: string, width?: table, align?: string }[]
function M.find_image_links(bufnr, first, last, include_linked, range)
  local links = require("org.links")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info, paras = M.scan(lines)
  local exts = opts().extensions or M.IMAGE_EXTENSIONS
  local out = {}
  for row = math.max(1, first), math.min(last, #lines) do
    local line = lines[row]
    if not info[row].skip and (line:find(":", 1, true) or line:find("[[", 1, true)) then
      for _, lk in ipairs(links.real_links(line)) do
        local col, end_col = lk.start_col - 1, lk.end_col
        local inside = not range
          or (
            (row > range.row + 1 or (row == range.row + 1 and end_col > range.col))
            and (row < range.end_row + 1 or (row == range.end_row + 1 and col < range.end_col))
          )
        if inside then
          local target
          local desc = lk.desc ~= nil and lk.desc ~= ""
          if include_linked or not desc then
            target = lk
          else
            target = description_link(lk.desc)
          end
          local path = target and link_file(bufnr, row, target)
          if path and is_image(path, exts) and vim.uv.fs_stat(path) then
            local para = info[row].para and paras[info[row].para]
            local spec = { row = row, col = col, end_col = end_col }
            out[#out + 1] = {
              row = row,
              col = col,
              end_col = end_col,
              path = path,
              text = line:sub(col + 1, end_col),
              width = M.image_width(bufnr, row, para and para.attrs),
              align = M.image_align(lines, spec, para),
            }
          end
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- LaTeX fragments
---------------------------------------------------------------------------

--- Byte ranges of `text` no fragment may start in: verbatim and code
--- markup, and the targets of bracket links.
local function excluded_ranges(text)
  local ex = {}
  for _, sp in ipairs(require("org.links").verbatim_spans(text)) do
    ex[#ex + 1] = sp
  end
  local init = 1
  while true do
    local s = text:find("[[", init, true)
    if not s then
      break
    end
    local e = text:find("]", s + 2, true)
    if not e then
      break
    end
    ex[#ex + 1] = { s, e }
    init = e + 1
  end
  return ex
end

--- LaTeX fragments of `text` (org-element-latex-fragment-parser, for the
--- delimiters org-latex-preview renders): `\(..\)`, `\[..\]`, `$$..$$`
--- and `$..$`, which may span lines of the same paragraph.
---@return { [1]: integer, [2]: integer }[]
function M.fragments_in(text)
  local out = {}
  local ex = excluded_ranges(text)
  local function excluded(p)
    for _, r in ipairs(ex) do
      if p >= r[1] and p <= r[2] then
        return true
      end
    end
  end
  local i = 1
  while true do
    local s = text:find("[%$\\]", i)
    if not s then
      break
    end
    local e
    if not excluded(s) then
      local c, n = text:sub(s, s), text:sub(s + 1, s + 1)
      if c == "\\" then
        if n == "(" then
          local _, x = text:find("\\)", s + 2, true)
          e = x
        elseif n == "[" then
          local _, x = text:find("\\]", s + 2, true)
          e = x
        end
      elseif n == "$" then
        local _, x = text:find("$$", s + 2, true)
        e = x
      elseif text:sub(s - 1, s - 1) ~= "$" and n ~= "" and not n:match("[ \t\n,.;]") then
        local close = text:find("$", s + 1, true)
        if close then
          local pb, after = text:sub(close - 1, close - 1), text:sub(close + 1, close + 1)
          if
            not pb:match("[ \t\n,.]")
            and (after == "" or (after:match("[%s%p]") and after ~= "_" and after ~= "\\"))
          then
            e = close
          end
        end
      end
    end
    if e then
      out[#out + 1] = { s, e }
      i = e + 1
    else
      i = s + 1
    end
  end
  return out
end

--- LaTeX fragments and environments of rows `first..last`, in `range`
--- when given (see `find_image_links`).
---@return { row: integer, col: integer, end_row: integer, end_col: integer, text: string }[]
function M.find_latex_fragments(bufnr, first, last, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info, paras, envs = M.scan(lines)
  last = math.min(last, #lines)
  local out = {}
  local function add(f)
    local inside = not range
      or (
        (f.end_row > range.row + 1 or (f.end_row == range.row + 1 and f.end_col > range.col))
        and (f.row < range.end_row + 1 or (f.row == range.end_row + 1 and f.col < range.end_col))
      )
    if inside and f.end_row >= first and f.row <= last then
      out[#out + 1] = f
    end
  end
  for _, env in ipairs(envs) do
    local text = table.concat(vim.list_slice(lines, env.first, env.last), "\n")
    add({
      row = env.first,
      col = #lines[env.first]:match("^%s*"),
      end_row = env.last,
      end_col = #lines[env.last],
      text = text,
    })
  end
  -- runs of lines scanned together: a paragraph, or a single line of a
  -- headline, table row or parsed keyword
  local row = 1
  while row <= #lines do
    local li = info[row]
    local stop = row
    if li.para then
      stop = paras[li.para].last
    end
    if not li.skip and not li.env and stop >= first and row <= last then
      local chunk = vim.list_slice(lines, row, stop)
      local text = table.concat(chunk, "\n")
      if text:find("[%$\\]") then
        -- byte offset -> row / column
        local starts, off = {}, 1
        for k, l in ipairs(chunk) do
          starts[k] = off
          off = off + #l + 1
        end
        local function pos(o)
          local k = #starts
          while k > 1 and starts[k] > o do
            k = k - 1
          end
          return row + k - 1, o - starts[k]
        end
        for _, f in ipairs(M.fragments_in(text)) do
          local r1, c1 = pos(f[1])
          local r2, c2 = pos(f[2])
          add({ row = r1, col = c1, end_row = r2, end_col = c2 + 1, text = text:sub(f[1], f[2]) })
        end
      end
    end
    row = stop + 1
  end
  table.sort(out, function(a, b)
    return a.row < b.row or (a.row == b.row and a.col < b.col)
  end)
  return out
end

---------------------------------------------------------------------------
-- Rendering LaTeX (org-create-formula-image)
---------------------------------------------------------------------------

--- The header Emacs uses (org-format-latex-header).
M.DEFAULT_HEADER = [[
\documentclass{article}
\usepackage[usenames]{color}
[DEFAULT-PACKAGES]
[PACKAGES]
\pagestyle{empty}             % do not remove
% The settings below are copied from fullpage.sty
\setlength{\textwidth}{\paperwidth}
\addtolength{\textwidth}{-3cm}
\setlength{\oddsidemargin}{1.5cm}
\addtolength{\oddsidemargin}{-2.54cm}
\setlength{\evensidemargin}{\oddsidemargin}
\setlength{\textheight}{\paperheight}
\addtolength{\textheight}{-\headheight}
\addtolength{\textheight}{-\headsep}
\addtolength{\textheight}{-\footskip}
\addtolength{\textheight}{-3cm}
\setlength{\topmargin}{1.5cm}
\addtolength{\topmargin}{-2.54cm}]]

local STANDALONE_HEADER = [=[
\documentclass[preview,border=1pt]{standalone}
\usepackage[usenames]{color}
[DEFAULT-PACKAGES]
[PACKAGES]]=]

--- The processes of org-preview-latex-process-alist, plus "tectonic" and
--- "pdflatex" (a PDF made to the size of the formula, turned into a PNG
--- by pdftocairo). `ui.latex_preview.processes` adds or replaces entries.
--- In commands, %f is the input file, %F its full path, %b its base name,
--- %o the output directory, %O the output file, %D the DPI and %S the
--- scale (DPI / 140).
M.PROCESSES = {
  dvipng = {
    programs = { "latex", "dvipng" },
    message = "you need to install the programs: latex and dvipng.",
    image_input_type = "dvi",
    image_output_type = "png",
    image_size_adjust = { 1.0, 1.0 },
    latex_compiler = { "latex -interaction nonstopmode -output-directory %o %f" },
    image_converter = { "dvipng -D %D -T tight -o %O %f" },
    transparent_image_converter = { "dvipng -D %D -T tight -bg Transparent -o %O %f" },
  },
  dvisvgm = {
    programs = { "latex", "dvisvgm" },
    message = "you need to install the programs: latex and dvisvgm.",
    image_input_type = "dvi",
    image_output_type = "svg",
    image_size_adjust = { 1.7, 1.5 },
    latex_compiler = { "latex -interaction nonstopmode -output-directory %o %f" },
    image_converter = { "dvisvgm %f --no-fonts --exact-bbox --scale=%S --output=%O" },
  },
  xelatex = {
    programs = { "xelatex", "dvisvgm" },
    message = "you need to install the programs: xelatex and dvisvgm.",
    image_input_type = "xdv",
    image_output_type = "svg",
    image_size_adjust = { 1.7, 1.5 },
    latex_compiler = { "xelatex -no-pdf -interaction nonstopmode -output-directory %o %f" },
    image_converter = { "dvisvgm %f --no-fonts --exact-bbox --scale=%S --output=%O" },
  },
  imagemagick = {
    programs = { "latex", "convert" },
    message = "you need to install the programs: latex and imagemagick.",
    image_input_type = "pdf",
    image_output_type = "png",
    image_size_adjust = { 1.0, 1.0 },
    latex_compiler = { "pdflatex -interaction nonstopmode -output-directory %o %f" },
    image_converter = { "convert -density %D -trim -antialias %f -quality 100 %O" },
  },
  tectonic = {
    programs = { "tectonic", "pdftocairo" },
    message = "you need to install the programs: tectonic and pdftocairo (poppler).",
    image_input_type = "pdf",
    image_output_type = "png",
    image_size_adjust = { 1.0, 1.0 },
    latex_header = STANDALONE_HEADER,
    latex_compiler = { "tectonic -X compile --outdir %o %f" },
    image_converter = { "pdftocairo -png -singlefile -r %D %f %o%b" },
    transparent_image_converter = { "pdftocairo -png -singlefile -transp -r %D %f %o%b" },
  },
  pdflatex = {
    programs = { "pdflatex", "pdftocairo" },
    message = "you need to install the programs: pdflatex and pdftocairo (poppler).",
    image_input_type = "pdf",
    image_output_type = "png",
    image_size_adjust = { 1.0, 1.0 },
    latex_header = STANDALONE_HEADER,
    latex_compiler = { "pdflatex -interaction nonstopmode -output-directory %o %f" },
    image_converter = { "pdftocairo -png -singlefile -r %D %f %o%b" },
    transparent_image_converter = { "pdftocairo -png -singlefile -transp -r %D %f %o%b" },
  },
}

local function processes()
  return vim.tbl_extend("force", M.PROCESSES, latex_opts().processes or {})
end

--- The process used to render LaTeX (org-preview-latex-default-process):
--- `latex_preview.process`, or with "auto" the first one installed.
---@return string? name, string? err
function M.latex_process()
  local p = latex_opts().process or "auto"
  local all = processes()
  local order = p == "auto" and { "dvipng", "dvisvgm", "tectonic", "pdflatex", "imagemagick" } or { p }
  for _, name in ipairs(order) do
    local spec = all[name]
    local ok = spec ~= nil
    for _, prog in ipairs(spec and spec.programs or {}) do
      ok = ok and executable(prog)
    end
    if ok then
      return name
    end
  end
  if p == "auto" then
    return nil, "no LaTeX renderer found (install latex and dvipng, or tectonic and poppler)"
  end
  return nil,
    all[p] and (all[p].message or ("programs for the '" .. p .. "' process are missing"))
      or ("unknown LaTeX process: " .. p)
end

--- `r,g,b` (0-1) of a color: "#rrggbb", a color name, or nil.
local function latex_rgb(color)
  local n
  if type(color) == "number" then
    n = color
  elseif type(color) == "string" then
    n = color:match("^#%x%x%x%x%x%x$") and tonumber(color:sub(2), 16) or vim.api.nvim_get_color_by_name(color)
    if n == -1 then
      n = nil
    end
  end
  if not n then
    return nil
  end
  local r, g, b = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
  return string.format("%.3f,%.3f,%.3f", r / 255, g / 255, b / 255)
end

local function hl_color(group, key)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and hl[key] or nil
end

--- The foreground (org-format-latex-options :foreground): "default" (the
--- Normal text), "auto" (the text at the fragment) or a color.
local function foreground(bufnr, row, col)
  local fg = latex_opts().foreground or "default"
  if fg == "auto" and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local ok, pos = pcall(vim.inspect_pos, bufnr, row, col)
    local groups = {}
    if ok then
      for _, list in ipairs({ pos.extmarks or {}, pos.treesitter or {}, pos.syntax or {} }) do
        for _, x in ipairs(list) do
          groups[#groups + 1] = x.hl_group or (x.opts and x.opts.hl_group)
        end
      end
    end
    for k = #groups, 1, -1 do
      local c = groups[k] and hl_color(groups[k], "fg")
      if c then
        return latex_rgb(c)
      end
    end
    fg = "default"
  end
  if fg == "default" then
    return latex_rgb(hl_color("Normal", "fg")) or (vim.o.background == "dark" and "0.878,0.886,0.918" or "0,0,0")
  end
  return latex_rgb(fg) or "0,0,0"
end

--- The background (:background): "default" (Normal), "Transparent" or a
--- color, as LaTeX `r,g,b` and `#rrggbb`; nil means transparent.
local function background()
  local bg = latex_opts().background or "default"
  local n
  if bg == "Transparent" then
    return nil
  elseif bg == "default" then
    n = hl_color("Normal", "bg")
  elseif type(bg) == "string" then
    n = bg:match("^#%x%x%x%x%x%x$") and tonumber(bg:sub(2), 16) or vim.api.nvim_get_color_by_name(bg)
  end
  if not n or n == -1 then
    return nil
  end
  return latex_rgb(n), string.format("#%06x", n)
end

--- The preamble: the process's header or `latex_preview.header` (else
--- org-format-latex-header), made like org-latex-make-preamble with the
--- packages of the LaTeX export and the file's #+LATEX_HEADER lines.
local function preamble(bufnr, template)
  local ok, res = pcall(function()
    local ox = require("org.export.ox")
    local latex = require("org.export.latex")
    local name = vim.api.nvim_buf_get_name(bufnr)
    local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
    local keywords = ox.collect_keywords(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), dir)
    local info = ox.environment({
      keywords = keywords,
      backend = latex.backend,
      parse_secondary = function(s)
        return s
      end,
    })
    return latex.make_preamble(info, template, true)
  end)
  if ok and type(res) == "string" then
    return res
  end
  -- without the exporter: drop the placeholders, add #+LATEX_HEADER
  local out = template:gsub("%[N?O?%-?DEFAULT%-PACKAGES%]", ""):gsub("%[N?O?%-?PACKAGES%]", "")
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local h = l:match("^%s*#%+[lL][aA][tT][eE][xX]_[hH][eE][aA][dD][eE][rR]:%s?(.*)$")
    if h then
      out = out .. "\n" .. h
    end
  end
  return out
end

--- Where images are written (org-preview-latex-image-directory): relative
--- to the file's directory, or the cache for buffers without a file.
local function image_dir(bufnr)
  local lo = latex_opts()
  local dir = lo.cache_dir or lo.image_directory or "ltximg/"
  local name = bufnr and vim.api.nvim_buf_get_name(bufnr) or ""
  if not dir:match("^/") and not dir:match("^%a:[/\\]") and not dir:match("^~") then
    if name == "" or name:match("^%a[%w+.-]*://") then
      return cache_root()
    end
    dir = vim.fn.fnamemodify(name, ":p:h") .. "/" .. dir
  end
  dir = vim.fs.normalize(vim.fn.expand(dir))
  vim.fn.mkdir(dir, "p")
  return dir
end

local LOG = "*Org Preview LaTeX Output*"

--- Write the output of a failed step to the *Org Preview LaTeX Output* buffer.
local function log_failure(cmd, res)
  local buf = vim.fn.bufnr(LOG)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, LOG)
  end
  local text = { "$ " .. cmd, "" }
  vim.list_extend(text, vim.split((res.stdout or "") .. (res.stderr or ""), "\n"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
end

local function substitute(cmd, spec)
  return (
    cmd:gsub("%%(%a)", function(c)
      local v = spec[c]
      if v == nil then
        return "%" .. c
      end
      return v
    end)
  )
end

-- A few renders at a time; one job per image, shared by its callers.
local MAX_JOBS = 4
local running, queue, waiting = 0, {}, {}

local function pump()
  while running < MAX_JOBS and #queue > 0 do
    local job = table.remove(queue, 1)
    running = running + 1
    job(function()
      running = running - 1
      vim.schedule(pump)
    end)
  end
end

--- Render `text` (a fragment of `bufnr` at `row`/`col`, 0-based) to an
--- image in the image directory and call `cb(path)` or `cb(nil, err)`.
function M.render_latex(text, bufnr, cb, row, col)
  local process, err = M.latex_process()
  if not process then
    return cb(nil, err)
  end
  local spec = processes()[process]
  local lo = latex_opts()
  local adjust = spec.image_size_adjust or { 1.0, 1.0 }
  local scale = (lo.scale or 1) * (adjust[1] or 1)
  -- a 10pt formula about as tall as a text line
  local dpi = math.floor(6 * cell.h * scale + 0.5)
  local fg, bg, bg_hex = foreground(bufnr, row or 0, col or 0), background()
  -- pdftocairo can only trim a transparent page: the background is
  -- added after trimming
  local cropped_later = process == "tectonic" or process == "pdflatex"
  local page_bg = not cropped_later and bg or nil
  local header = preamble(bufnr, spec.latex_header or lo.header or M.DEFAULT_HEADER)
  local body = text:sub(-1) == "\n" and (text:sub(1, -2) .. "%") or (text .. "%")
  local doc = table.concat({
    header,
    "\\begin{document}",
    "\\definecolor{fg}{rgb}{" .. fg .. "}%",
    page_bg and ("\\definecolor{bg}{rgb}{" .. page_bg .. "}%\n\n\\pagecolor{bg}%") or "",
    "",
    "{\\color{fg}",
    body,
    "}",
    "",
    "\\end{document}",
    "",
  }, "\n")
  local ext = spec.image_output_type or "png"
  local key = vim.fn.sha256(table.concat({ "v3", process, dpi, doc, bg or "" }, "\0")):sub(1, 40)
  local out = image_dir(bufnr) .. "/org-ltximg_" .. key .. "." .. ext
  if vim.uv.fs_stat(out) then
    return cb(out)
  end
  if waiting[out] then
    table.insert(waiting[out], cb)
    return
  end
  waiting[out] = { cb }
  local function finish(path, e)
    local cbs = waiting[out] or {}
    waiting[out] = nil
    for _, f in ipairs(cbs) do
      f(path, e)
    end
  end
  queue[#queue + 1] = function(done)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local base = "orgtex"
    vim.fn.writefile(vim.split(doc, "\n"), dir .. "/" .. base .. ".tex")
    local input = spec.image_input_type or "dvi"
    local converter = (not page_bg and spec.transparent_image_converter) or spec.image_converter
    local steps = {}
    local function add_steps(cmds, src, out_ext)
      for _, c in ipairs(cmds or {}) do
        local s = {
          b = base,
          f = vim.fn.shellescape(base .. "." .. src),
          F = vim.fn.shellescape(dir .. "/" .. base .. "." .. src),
          o = vim.fn.shellescape(dir .. "/"),
          O = vim.fn.shellescape(dir .. "/" .. base .. "." .. out_ext),
          D = tostring(dpi),
          S = string.format("%.3f", dpi / 140),
        }
        -- %o%b: one path, not two quoted halves
        local cmd = c:gsub("%%o%%b", vim.fn.shellescape(dir .. "/" .. base))
        steps[#steps + 1] = { cmd = substitute(cmd, s), expect = dir .. "/" .. base .. "." .. out_ext }
      end
    end
    add_steps(spec.latex_compiler, "tex", input)
    add_steps(converter, input, ext)
    -- pdftocairo keeps the whole page: trim the empty margins, then paint
    -- the background
    local magick = magick_cmd()
    if magick and ext == "png" and cropped_later then
      local png = vim.fn.shellescape(dir .. "/" .. base .. ".png")
      local paint = bg_hex and (" -background '" .. bg_hex .. "' -flatten") or ""
      steps[#steps + 1] = {
        cmd = magick .. " " .. png .. " -trim +repage" .. paint .. " " .. png,
        expect = dir .. "/" .. base .. ".png",
      }
    end
    local adjust_msg = string.format("Please adjust `%s' part of `ui.latex_preview.processes'.", process)
    local function run(i)
      if i > #steps then
        local produced = dir .. "/" .. base .. "." .. ext
        local tmp = out .. ".tmp"
        local ok = vim.uv.fs_copyfile(produced, tmp) and vim.uv.fs_rename(tmp, out)
        vim.fn.delete(dir, "rf")
        done()
        return finish(ok and out or nil, not ok and ("File " .. produced .. " wasn't produced. " .. adjust_msg) or nil)
      end
      local shell = vim.fn.has("win32") == 1 and { vim.o.shell, vim.o.shellcmdflag } or { "sh", "-c" }
      vim.system(vim.list_extend(vim.deepcopy(shell), { steps[i].cmd }), { cwd = dir, text = true }, function(res)
        vim.schedule(function()
          if not vim.uv.fs_stat(steps[i].expect) then
            log_failure(steps[i].cmd, res)
            vim.fn.delete(dir, "rf")
            done()
            return finish(
              nil,
              "File " .. steps[i].expect .. " wasn't produced. " .. adjust_msg .. " (see " .. LOG .. ")"
            )
          end
          run(i + 1)
        end)
      end)
    end
    run(1)
  end
  pump()
end

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

local backends = {}

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

-- Native: images are placed on the screen by `sync()`; `show`/`hide` only
-- reserve (or free) the rows under the line. The reservation sits at the
-- end of the link, so splitting the line before it moves both.
backends.native = {
  name = "native",
  needs_png = true,
  show = function(bufnr, p, row, col)
    local vl = {}
    for _ = 1, p.height do
      vl[#vl + 1] = { { "", "Normal" } }
    end
    p.lines = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
      id = p.lines,
      virt_lines = vl,
      right_gravity = false,
      invalidate = true,
      undo_restore = false,
    })
  end,
  hide = function(bufnr, p)
    if p.lines then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.lines)
      p.lines = nil
    end
  end,
}

backends.snacks = {
  name = "snacks",
  show = function(bufnr, p, row, col, x, start_row)
    p.handle = Snacks.image.placement.new(bufnr, p.src, {
      pos = { start_row + 1, x },
      -- the whole link: snacks then draws the image under it, at its column
      range = { start_row + 1, x, row + 1, col },
      inline = true,
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
    return nil, "this terminal does not support the Kitty graphics protocol (vim.ui.img)"
  end
  return nil, "no image backend: needs Neovim 0.13+ in a Kitty-graphics terminal, snacks.nvim (image) or image.nvim"
end

--- A description of the backend for `:checkhealth org`.
function M.status()
  local b, why = M.backend()
  return b and b.name or nil, why
end

---------------------------------------------------------------------------
-- Previews
---------------------------------------------------------------------------

-- LaTeX renders waiting for their image: pending[bufnr][mark] = text
local pending = {}

local function buf_previews(bufnr)
  previews[bufnr] = previews[bufnr] or {}
  return previews[bufnr]
end

local function mark_pos(bufnr, mark)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, { details = true })
  if not m[1] or (m[3] and m[3].invalid) then
    return nil
  end
  return m[1], m[2], m[3]
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

local placed ---@type table<string, { id: integer, opts: table }>
local data_cache = {} ---@type table<string, string>

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

--- Previews of `kind` in rows `first..last` (1-based), or overlapping
--- `range` ({ row, col, end_row, end_col }, 0-based) when given.
local function previews_in(bufnr, first, last, kind, range)
  local out = {}
  for id, p in pairs(previews[bufnr] or {}) do
    local r, c, d = mark_pos(bufnr, p.mark)
    if (not kind or p.kind == kind) and r then
      local mr = { row = r, col = c, end_row = d and d.end_row or r, end_col = d and d.end_col or c }
      local hit
      if range then
        hit = overlaps(mr, range)
          or (
            range.row == range.end_row
            and range.col == range.end_col
            and mr.row == range.row
            and mr.col <= range.col
            and mr.end_col >= range.col
          )
      else
        hit = mr.end_row + 1 >= first and mr.row + 1 <= last
      end
      if hit then
        out[#out + 1] = id
      end
    end
  end
  return out
end

--- Remove the previews of `kind` (all when nil) in rows `first..last`,
--- or overlapping `range`. Pending LaTeX renders there are dropped too.
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
  return #ids
end

--- The cells an image takes: its size spec -> width, height.
local function size_of(win, s)
  if not s.pw then
    return max_width(win), math.min(opts().max_height or 24, 10)
  end
  local want
  if s.width and s.width.px then
    want = math.max(1, math.floor(s.width.px / cell.w + 0.5))
  elseif s.width and s.width.fraction then
    local bufnr = vim.api.nvim_win_get_buf(win)
    local base = vim.bo[bufnr].textwidth > 0 and vim.bo[bufnr].textwidth or text_columns(win)
    want = math.max(1, math.floor(s.width.fraction * base + 0.5))
  end
  local maxw = max_width(win)
  if s.kind == "latex" then
    maxw = text_columns(win) - 1
  end
  return M.fit(s.pw, s.ph, maxw, opts().max_height, want)
end

--- Show preview `p` with backend `b` where its extmark is now: the rows
--- are reserved at the end of the link or fragment, the image starts at
--- its first column (at the line start when it spans lines).
local function show(b, bufnr, p)
  local r, c, d = mark_pos(bufnr, p.mark)
  local end_row = d and d.end_row or r
  local line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local end_col = math.min(d and d.end_col or c, #line)
  local x = r == end_row and c or #line:match("^%s*")
  return b.show(bufnr, p, end_row, end_col, x, r)
end

local function add(bufnr, kind, spec, src, backend)
  local win = vim.fn.bufwinid(bufnr)
  win = win ~= -1 and win or vim.api.nvim_get_current_win()
  local file = src
  if backend.needs_png then
    file = as_png(src)
    if not file then
      return false, "can't convert " .. vim.fn.fnamemodify(src, ":t") .. " to PNG (install ImageMagick)"
    end
  end
  local pw, ph = M.png_size(file)
  local size = { pw = pw, ph = ph, width = spec.width, kind = kind }
  local w, h = size_of(win, size)
  local end_row = (spec.end_row or spec.row) - 1
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
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, spec.row - 1, spec.col, {
      end_row = end_row,
      end_col = spec.end_col,
      invalidate = true,
      undo_restore = false,
    }),
  }
  local ok, err = pcall(show, backend, bufnr, p)
  if not ok then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.mark)
    return false, tostring(err)
  end
  buf_previews(bufnr)[p.id] = p
  M.attach(bufnr)
  M._schedule_sync()
  return true
end

--- Show the image links of rows `first..last` (or of `range`), replacing
--- the previews there. Returns the number shown.
function M.show_links(bufnr, first, last, include_linked, range)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b, why = M.backend()
  if not b then
    utils.warn(why)
    return 0
  end
  ask_cell_size()
  M.clear(bufnr, first, last, "link", range)
  local n, failed = 0, nil
  for _, lk in ipairs(M.find_image_links(bufnr, first, last, include_linked, range)) do
    local ok, err = add(bufnr, "link", lk, lk.path, b)
    if ok then
      n = n + 1
    else
      failed = err
    end
  end
  if failed then
    utils.warn(failed)
  end
  return n
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

--- Size every preview again (the font or the window changed).
function M.refit()
  for bufnr, list in pairs(previews) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then
        for _, p in pairs(list) do
          local w, h = size_of(win, p.size)
          if w ~= p.width or h ~= p.height then
            p.width, p.height = w, h
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
  M.sync(true)
end

---------------------------------------------------------------------------
-- Native placement
---------------------------------------------------------------------------

placed = {}

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
local function row_after(win, info, lnum)
  if lnum < info.topline or lnum > info.botline then
    return nil
  end
  local above = 0
  if lnum > info.topline then
    above = vim.api.nvim_win_text_height(win, { start_row = info.topline - 1, end_row = lnum - 2 }).all
  end
  local own = vim.api.nvim_win_text_height(win, { start_row = lnum - 1, end_row = lnum - 1 })
  return info.winrow + (info.winbar or 0) + above + (own.all - own.fill)
end

--- Where every native preview should be on the screen right now.
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
          local r, c, d = mark_pos(bufnr, p.mark)
          if r then
            local anchor = d and d.end_row or r
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
        if y then
          table.sort(items, function(a, b)
            return a.row < b.row or (a.row == b.row and a.col < b.col)
          end)
          for _, it in ipairs(items) do
            local p = it.p
            local x
            if p.align == "center" then
              x = left + math.floor((right - left + 1 - p.width) / 2)
            elseif p.align == "right" then
              x = right - p.width + 1
            else
              local sp = vim.fn.screenpos(win, it.row + 1, it.col + 1)
              x = sp.col > 0 and sp.col or left
            end
            x = math.max(left, math.min(x, right - p.width + 1))
            local visible = y >= top and y + p.height - 1 <= bottom
            for _, r in ipairs(rects) do
              -- a float covers the windows under it, not itself
              if r.win ~= win and (not is_float or r.z > (cfg.zindex or 50)) then
                visible = visible and not hidden_by(r, y, x, p.width, p.height)
              end
            end
            if visible then
              want[win .. ":" .. p.id] = {
                src = p.src,
                opts = { row = y, col = x, width = p.width, height = p.height, zindex = 50 },
              }
            end
            y = y + p.height
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
vim.api.nvim_create_autocmd({ "VimResized", "VimResume", "FocusGained", "UIEnter" }, {
  group = vim.api.nvim_create_augroup("org.images", { clear = true }),
  callback = function(ev)
    if ev.event == "VimResized" then
      cell.asked = false
      ask_cell_size()
    end
    if next(placed) or next(previews) then
      vim.schedule(M.refit)
    end
  end,
})

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- Rows of the entry at the cursor: its headline to the line before the
--- next headline (the part before the first headline counts as one).
local function section_rows(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = 1, #lines
  for i = lnum, 1, -1 do
    if lines[i]:match("^%*+%s") then
      first = i
      break
    end
  end
  for i = lnum + 1, #lines do
    if lines[i]:match("^%*+%s") then
      last = i - 1
      break
    end
  end
  return first, last
end

--- The Visual selection as rows, leaving Visual mode.
local function visual_rows()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    return math.min(a, b), math.max(a, b)
  end
end

local function count_arg()
  local c = vim.v.count
  return c ~= 0 and c or nil
end

local function notify(msg)
  utils.notify(msg)
end

--- Link previews of rows `first..last` (or `range`) on (`remove` false) or
--- off, with the messages of org-link-preview.
local function toggle_links(bufnr, first, last, scope, remove_them, include, range)
  if remove_them then
    local n = M.clear(bufnr, first, last, "link", range)
    notify(string.format("[%s] Inline link previews turned off (removed %d images)", scope, n))
    return
  end
  local n = M.show_links(bufnr, first, last, include, range)
  if not M.backend() then
    return
  end
  if n > 0 then
    notify(
      string.format(
        "[%s] Displaying %d images inline%s",
        scope,
        n,
        include and " (including images with description)" or ""
      )
    )
  elseif scope == "buffer" then
    notify("[buffer] No images to display inline")
  else
    notify(
      string.format("[%s] No images to display inline.  Use a count of 16 or 11 to preview the whole buffer", scope)
    )
  end
end

--- The link under the cursor: its row and 0-based column range.
local function link_at(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  for _, lk in ipairs(require("org.links").real_links(line)) do
    if col >= lk.start_col - 1 and col < lk.end_col then
      return { row = lnum - 1, col = lk.start_col - 1, end_row = lnum - 1, end_col = lk.end_col }
    end
  end
end

--- org-link-preview (C-c C-x C-v): the link at the cursor, else the
--- current entry, or the rows `rows` ({ first, last }: a Visual selection
--- or an ex range). `arg` is the Emacs prefix as a count: 4 hides (the
--- preview at the cursor, else the entry or rows), 16 or 11 previews the
--- whole buffer, 64 hides it all, 1 and 11 (and other counts) also preview
--- links with a description; a plain call on an entry or rows always
--- displays, on a link toggles it.
function M.link_preview(arg, rows)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local include = arg ~= nil and arg ~= 4 and arg ~= 16 and arg ~= 64
  local first, last
  if rows then
    first, last = rows[1], rows[2]
  else
    first, last = visual_rows()
  end
  if first then
    return toggle_links(bufnr, first, last, "region", arg == 4, include)
  elseif arg == 4 then
    local here =
      previews_in(bufnr, 1, math.huge, "link", { row = lnum - 1, col = col, end_row = lnum - 1, end_col = col })
    if #here > 0 then
      for _, id in ipairs(here) do
        remove(bufnr, id)
      end
      return notify(string.format("[preview at point] Inline link previews turned off (removed %d images)", #here))
    end
    local s, e = section_rows(bufnr, lnum)
    return toggle_links(bufnr, s, e, "current section", true)
  elseif arg == 11 or arg == 16 then
    return toggle_links(bufnr, 1, math.huge, "buffer", false, arg == 11)
  elseif arg == 64 then
    return toggle_links(bufnr, 1, math.huge, "buffer", true)
  elseif arg == nil or arg == 1 then
    local lk = link_at(bufnr, lnum, col)
    if lk then
      local on = #previews_in(bufnr, 1, math.huge, "link", lk) > 0
      return toggle_links(bufnr, lnum, lnum, "image at point", on, include, lk)
    end
    local s, e = section_rows(bufnr, lnum)
    return toggle_links(bufnr, s, e, "current section", false, include)
  end
  -- any other count: the whole buffer, with described links
  return toggle_links(bufnr, 1, math.huge, "region", false, true)
end

--- org-link-preview-refresh (C-c C-x C-M-v): preview every image link of
--- the buffer again (after the files changed).
function M.link_preview_refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  data_cache = {}
  M.show_links(bufnr, 1, math.huge)
  M.sync(true)
end

--- org-link-preview-region: preview the image links of `rows` (default
--- the whole buffer); `include_linked` also previews described links,
--- `refresh` replaces existing previews (they are replaced anyway).
function M.link_preview_region(include_linked, rows)
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last = rows and rows[1] or 1, rows and rows[2] or math.huge
  M.show_links(bufnr, first, last, include_linked)
end

--- org-link-preview-clear: remove the link previews of `rows` (default
--- the whole buffer).
function M.link_preview_clear(rows)
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear(bufnr, rows and rows[1] or 1, rows and rows[2] or math.huge, "link")
end

--- org-clear-latex-preview: remove the LaTeX previews of `rows` (default
--- the whole buffer). Returns whether there were any.
function M.clear_latex_preview(rows)
  local bufnr = vim.api.nvim_get_current_buf()
  return M.clear(bufnr, rows and rows[1] or 1, rows and rows[2] or math.huge, "latex") > 0
end

local function latex_done(what)
  return function(n, err)
    if err then
      utils.warn("LaTeX preview: " .. err)
    end
    notify(string.format("Creating LaTeX preview%s... done.", what))
    return n
  end
end

--- The LaTeX fragment or environment under the cursor.
local function fragment_at(bufnr, lnum, col)
  for _, f in ipairs(M.find_latex_fragments(bufnr, 1, math.huge)) do
    local inside = (lnum > f.row or (lnum == f.row and col >= f.col))
      and (lnum < f.end_row or (lnum == f.end_row and col < f.end_col))
    if inside then
      return f
    end
  end
end

--- org-latex-preview (C-c C-x C-l): with the cursor on a fragment, toggle
--- its preview; else preview the current entry, or the rows `rows` (a
--- Visual selection or an ex range). 4 hides the entry's (or rows')
--- previews, 16 previews the whole buffer, 64 hides it all.
function M.latex_preview(arg, rows)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local first, last
  if rows then
    first, last = rows[1], rows[2]
  else
    first, last = visual_rows()
  end
  if arg == 64 then
    M.clear(bufnr, 1, math.huge, "latex")
    return notify("LaTeX previews removed from buffer")
  elseif arg == 16 then
    notify("Creating LaTeX previews in buffer...")
    return M.show_latex(bufnr, 1, math.huge, latex_done("s in buffer"))
  elseif arg == 4 then
    if not first then
      first, last = section_rows(bufnr, lnum)
    end
    M.clear(bufnr, first, last, "latex")
    return
  elseif first then
    notify("Creating LaTeX previews in region...")
    return M.show_latex(bufnr, first, last, latex_done("s in region"))
  end
  local f = fragment_at(bufnr, lnum, col)
  if f then
    local range = { row = f.row - 1, col = f.col, end_row = f.end_row - 1, end_col = f.end_col }
    if M.clear(bufnr, 1, math.huge, "latex", range) > 0 then
      return notify("LaTeX preview removed")
    end
    notify("Creating LaTeX preview...")
    return M.show_latex(bufnr, f.row, f.end_row, latex_done(""), range)
  end
  local s, e = section_rows(bufnr, lnum)
  notify("Creating LaTeX previews in section...")
  M.show_latex(bufnr, s, e, latex_done("s in section"))
end

--- org-cycle-display-link-previews (on org-cycle-hook): with
--- `ui.images.cycle_display`, TAB to CHILDREN previews the entry's links,
--- to SUBTREE those of the subtree, and FOLDED removes them.
---@param state "children"|"subtree"|"folded"
---@param line integer the headline
---@param end_line integer the subtree's last line
---@param first_child? integer the first child headline
function M.cycle_display(state, line, end_line, first_child)
  if not opts().cycle_display then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if state == "children" then
    M.show_links(bufnr, line, first_child and first_child - 1 or end_line)
  elseif state == "subtree" then
    M.show_links(bufnr, line, end_line)
  elseif state == "folded" then
    M.clear(bufnr, line, end_line, "link")
  end
end

--- `:[range]Org` handler for the preview commands: `args` is the text after
--- the name, `cmd` the user command's opts.
function M.command(name, args, cmd)
  local rows = cmd and cmd.range and cmd.range > 0 and { cmd.line1, cmd.line2 } or nil
  local n = tonumber((args or ""):match("^%s*(%d+)"))
  local linked = (args or ""):match("linked") ~= nil
  if name == "link_preview" or name == "toggle_inline_images" then
    return M.link_preview(n or (linked and 1) or nil, rows)
  elseif name == "link_preview_region" then
    return M.link_preview_region(linked or (n ~= nil), rows)
  elseif name == "link_preview_clear" or name == "remove_inline_images" then
    return M.link_preview_clear(rows)
  elseif name == "link_preview_refresh" or name == "redisplay_inline_images" then
    return M.link_preview_refresh()
  elseif name == "latex_preview" or name == "toggle_latex_fragment" or name == "preview_latex_fragment" then
    return M.latex_preview(n, rows)
  elseif name == "clear_latex_preview" then
    return M.clear_latex_preview(rows)
  end
end

-- `:Org <name>` entries (org.commands), each called with the arguments and
-- the user command's opts.
for _, name in ipairs({
  "link_preview",
  "link_preview_region",
  "link_preview_clear",
  "link_preview_refresh",
  "latex_preview",
  "clear_latex_preview",
  "toggle_inline_images",
  "remove_inline_images",
  "redisplay_inline_images",
  "toggle_latex_fragment",
  "preview_latex_fragment",
}) do
  M["ex_" .. name] = function(args, cmd)
    return M.command(name, args, cmd)
  end
end

return M
