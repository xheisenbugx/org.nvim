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

--- Image file extensions previewed by default (Emacs `image-types`).
M.IMAGE_EXTENSIONS = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tif", "tiff", "avif" }

---@class org.images.Preview
---@field id integer
---@field kind "link"|"latex"
---@field mark integer extmark on the link / fragment (tracks edits)
---@field src string PNG (native) or source image file
---@field width integer cells
---@field height integer cells
---@field lines? integer extmark reserving the space under the line (native)
---@field handle? any snacks / image.nvim object

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

--- Whether `#+STARTUP` or the configuration turns previews on at startup.
local function startup(bufnr)
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  local st = ok and file.settings.startup or {}
  local links = opts().startup
  if st.inlineimages or st.linkpreviews then
    links = true
  elseif st.noinlineimages or st.nolinkpreviews then
    links = false
  end
  local latex = latex_opts().startup
  if st.latexpreview then
    latex = true
  elseif st.nolatexpreview then
    latex = false
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
  local request = vim.fn.has("mac") == 1 and 0x40087468
    or (vim.fn.has("bsd") == 1 and 0x40087468)
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
    local h, w = resp:match("^\27%[6;(%d+);(%d+)t")
    if h then
      cell.h, cell.w = tonumber(h), tonumber(w)
      return true
    end
  end)
end

---@return { w: integer, h: integer }
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

local function cache_dir()
  local dir = latex_opts().cache_dir or (vim.fn.stdpath("cache") .. "/org/ltximg")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

--- A PNG for `path`: the file itself, or a copy converted with ImageMagick
--- (the native backend only draws PNG). nil when it can't be converted.
local function as_png(path)
  if path:lower():match("%.png$") then
    return path
  end
  local magick = executable("magick") and { "magick" } or executable("convert") and { "convert" } or nil
  if not magick then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  local key = vim.fn.sha256(path .. ":" .. (st and st.mtime.sec or 0))
  local out = cache_dir() .. "/img-" .. key:sub(1, 20) .. ".png"
  if vim.uv.fs_stat(out) then
    return out
  end
  local cmd = vim.list_extend(vim.deepcopy(magick), { path .. "[0]", out })
  local res = vim.system(cmd):wait()
  return res.code == 0 and vim.uv.fs_stat(out) and out or nil
end

--- Size in cells of an image of `pw` x `ph` pixels: its natural size,
--- scaled down to fit `max_w` x `max_h` cells, keeping the aspect ratio.
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

--- Widest image in columns for window `win` (org-image-max-width).
local function max_width(win)
  local o = opts().max_width
  local info = vim.fn.getwininfo(win)[1]
  local room = info and (info.width - info.textoff - 1) or 80
  local w
  if o == "window" or o == nil or o == false then
    w = room
  elseif o == "fill-column" then
    local tw = vim.bo[vim.api.nvim_win_get_buf(win)].textwidth
    w = tw > 0 and tw or 80
  elseif type(o) == "number" and o > 0 and o < 1 then
    w = math.floor(room * o)
  elseif type(o) == "number" then
    w = o
  else
    w = room
  end
  return math.max(1, math.min(w, room))
end

---------------------------------------------------------------------------
-- Finding image links and LaTeX fragments
---------------------------------------------------------------------------

--- Lines Emacs never previews in: blocks other than quote/center/verse,
--- property drawers and comments.
local function skipped_lines(lines)
  local skip, block = {}, nil
  for i, l in ipairs(lines) do
    local low = l:lower()
    if block then
      skip[i] = true
      if low:match("^%s*#%+end_" .. block) then
        block = nil
      end
    else
      local kind = low:match("^%s*#%+begin_(%a+)")
      if kind and kind ~= "quote" and kind ~= "center" and kind ~= "verse" then
        block = kind
        skip[i] = true
      elseif l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%s*:%u+:") then
        skip[i] = true
      end
    end
  end
  return skip
end

local function is_image(path, exts)
  local ext = path:match("%.([%w]+)$")
  return ext and vim.tbl_contains(exts, ext:lower())
end

--- Width in pixels from `#+ATTR_ORG: :width N` (or ATTR_HTML/ATTR_LATEX
--- when there is no ATTR_ORG) on the affiliated lines above `row`.
local function attr_width(lines, row)
  local found
  local i = row - 1
  while i >= 1 do
    local l = lines[i]
    local key, rest = l:match("^%s*#%+[aA][tT][tT][rR]_(%w+):(.*)$")
    if not key and not l:match("^%s*#%+%w+:") then
      break
    end
    local w = rest and rest:match(":width%s+(%d+)")
    if w and (key:lower() == "org" or not found) then
      found = tonumber(w)
      if key:lower() == "org" then
        return found
      end
    end
    i = i - 1
  end
  return found
end

--- Image links of `lines[first..last]` (1-based): file and attachment links
--- to existing image files. Only links without a description unless
--- `include_linked` (org-link-preview with a count of 1 or 11).
---@return { row: integer, col: integer, end_col: integer, path: string, width?: integer }[]
function M.find_image_links(bufnr, first, last, include_linked)
  local links = require("org.links")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local skip = skipped_lines(lines)
  local exts = opts().extensions or M.IMAGE_EXTENSIONS
  local out = {}
  for row = first, math.min(last, #lines) do
    local line = lines[row]
    if not skip[row] and line:find("[:/%.]") then
      for _, lk in ipairs(links.parse_links(line)) do
        local path
        if lk.type == "file" or lk.type == "file+sys" or lk.type == "file+emacs" then
          path = links.resolve_path((lk.path:gsub("::.*$", "")), bufnr)
        elseif lk.type == "attachment" then
          local ok, p = pcall(require("org.attach").resolve_attachment, (lk.path:gsub("::.*$", "")), {
            bufnr = bufnr,
            lnum = row,
          })
          path = ok and p or nil
        end
        if
          path
          and (include_linked or not lk.desc or lk.desc == "")
          and is_image(path, exts)
          and vim.uv.fs_stat(path)
        then
          out[#out + 1] = {
            row = row,
            col = lk.start_col - 1,
            end_col = lk.end_col,
            path = path,
            width = attr_width(lines, row),
          }
        end
      end
    end
  end
  return out
end

--- Inline fragments of `line` (row `row`): `\(x\)`, `\[x\]`, `$$x$$`, `$x$`.
local function inline_fragments(line, row, out)
  local taken = {}
  local function add(s, e)
    for i = s, e do
      if taken[i] then
        return
      end
    end
    for i = s, e do
      taken[i] = true
    end
    out[#out + 1] = { row = row, col = s - 1, end_row = row, end_col = e, text = line:sub(s, e) }
  end
  for _, p in ipairs({ { "\\%(", "\\%)" }, { "\\%[", "\\%]" }, { "%$%$", "%$%$" } }) do
    local init = 1
    while true do
      local s, os_ = line:find(p[1], init)
      if not s then
        break
      end
      local _, e = line:find(p[2], os_ + 1)
      if not e then
        break
      end
      add(s, e)
      init = e + 1
    end
  end
  -- $x$ (org-latex-regexps): no blank after the opening or before the
  -- closing dollar, and the closing one not followed by a word character
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
      not taken[s]
      and inner ~= ""
      and not inner:match("^[%s,.;]")
      and not inner:match("[%s,.]$")
      and not line:sub(s - 1, s - 1):match("[%w$]")
      and not line:sub(e + 1, e + 1):match("[%w$]")
    then
      add(s, e)
      init = e + 1
    else
      init = s + 1
    end
  end
end

--- LaTeX fragments of `lines[first..last]`: `$x$`, `$$x$$`, `\(x\)`,
--- `\[x\]` and `\begin{env}...\end{env}` environments.
---@return { row: integer, col: integer, end_row: integer, end_col: integer, text: string }[]
function M.find_latex_fragments(bufnr, first, last)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local skip = skipped_lines(lines)
  local out = {}
  local row = first
  last = math.min(last, #lines)
  while row <= last do
    local line = lines[row]
    local env = not skip[row] and line:match("^%s*\\begin{([%a*]+)}")
    local stop
    for r = row, env and #lines or 0 do
      if lines[r]:find("\\end{" .. env .. "}", 1, true) then
        stop = r
        break
      end
    end
    if stop then
      local text = table.concat(vim.list_slice(lines, row, stop), "\n")
      out[#out + 1] = { row = row, col = #line:match("^%s*"), end_row = stop, end_col = #lines[stop], text = text }
      row = stop + 1
    else
      if not skip[row] and line:find("[%$\\]") then
        inline_fragments(line, row, out)
      end
      row = row + 1
    end
  end
  table.sort(out, function(a, b)
    return a.row < b.row or (a.row == b.row and a.col < b.col)
  end)
  return out
end

---------------------------------------------------------------------------
-- Rendering LaTeX (org-preview-latex-process-alist)
---------------------------------------------------------------------------

local DEFAULT_HEADER = [[
\documentclass[preview,border=1pt]{standalone}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{xcolor}
]]

--- The process used to render LaTeX: `latex_preview.process`, or with
--- "auto" the first one whose programs are installed.
function M.latex_process()
  local p = latex_opts().process or "auto"
  local need = {
    dvipng = { "latex", "dvipng" },
    tectonic = { "tectonic", "pdftocairo" },
    pdflatex = { "pdflatex", "pdftocairo" },
    imagemagick = { "pdflatex", "magick" },
  }
  local order = p == "auto" and { "dvipng", "tectonic", "pdflatex", "imagemagick" } or { p }
  for _, name in ipairs(order) do
    local ok = need[name] ~= nil
    for _, prog in ipairs(need[name] or {}) do
      ok = ok and executable(prog)
    end
    if ok then
      return name
    end
  end
  return nil,
    p == "auto" and "no LaTeX renderer found (install latex + dvipng, or tectonic + poppler)"
      or ("programs for the '" .. p .. "' LaTeX process are missing")
end

--- Foreground color of the rendered formulas as RRGGBB.
local function foreground()
  local fg = latex_opts().foreground
  if type(fg) == "string" and fg:match("^#%x%x%x%x%x%x$") then
    return fg:sub(2):upper()
  end
  local hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if hl.fg then
    return string.format("%06X", hl.fg)
  end
  return vim.o.background == "dark" and "E0E2EA" or "14161B"
end

--- Header lines from `#+LATEX_HEADER:` keywords of the buffer.
local function buffer_header(bufnr)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local h = l:match("^%s*#%+[lL][aA][tT][eE][xX]_[hH][eE][aA][dD][eE][rR]:%s?(.*)$")
    if h then
      out[#out + 1] = h
    end
  end
  return table.concat(out, "\n")
end

--- Render `text` to a PNG in the cache directory and call `cb(path)` (or
--- `cb(nil, err)`). Cached by content, colors, scale and process.
function M.render_latex(text, bufnr, cb)
  local process, err = M.latex_process()
  if not process then
    return cb(nil, err)
  end
  local lo = latex_opts()
  local fg = foreground()
  local scale = lo.scale or 1
  -- a 10pt formula a little taller than a text line
  local dpi = math.floor(6 * cell.h * scale + 0.5)
  local header = (lo.header or DEFAULT_HEADER) .. "\n" .. buffer_header(bufnr)
  local doc = table.concat({
    header,
    "\\begin{document}",
    "\\definecolor{orgfg}{HTML}{" .. fg .. "}\\color{orgfg}",
    text,
    "\\end{document}",
    "",
  }, "\n")
  local key = vim.fn.sha256(table.concat({ "v2", process, dpi, doc }, "\0")):sub(1, 24)
  local out = cache_dir() .. "/ltx-" .. key .. ".png"
  if vim.uv.fs_stat(out) then
    return cb(out)
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tex = dir .. "/f.tex"
  vim.fn.writefile(vim.split(doc, "\n"), tex)
  local steps
  if process == "dvipng" then
    steps = {
      { "latex", "-interaction", "nonstopmode", "-halt-on-error", "-output-directory", dir, tex },
      { "dvipng", "-D", tostring(dpi), "-T", "tight", "-bg", "Transparent", "-o", out, dir .. "/f.dvi" },
    }
  else
    local compile = process == "tectonic" and { "tectonic", "-X", "compile", "--outdir", dir, tex }
      or { "pdflatex", "-interaction", "nonstopmode", "-halt-on-error", "-output-directory", dir, tex }
    local convert = process == "imagemagick"
        and { "magick", "-density", tostring(dpi), dir .. "/f.pdf", "-trim", "+repage", out }
      or { "pdftocairo", "-png", "-singlefile", "-transp", "-r", tostring(dpi), dir .. "/f.pdf", out:sub(1, -5) }
    steps = { compile, convert }
    -- displayed math is as wide as the line: trim the empty margins
    local magick = executable("magick") and "magick" or executable("convert") and "convert" or nil
    if magick and process ~= "imagemagick" then
      steps[#steps + 1] = { magick, out, "-trim", "+repage", out }
    end
  end
  local function run(i)
    if i > #steps then
      vim.fn.delete(dir, "rf")
      if vim.uv.fs_stat(out) then
        return cb(out)
      end
      return cb(nil, "the LaTeX renderer made no image")
    end
    vim.system(steps[i], { cwd = dir, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          vim.fn.delete(dir, "rf")
          local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
          local line = msg:match("\n(![^\n]*)") or msg:match("error:[^\n]*") or msg:match("[^\n]*$")
          return cb(nil, steps[i][1] .. " failed: " .. (line or ("exit " .. res.code)))
        end
        run(i + 1)
      end)
    end)
  end
  run(1)
end

---------------------------------------------------------------------------
-- Backends
---------------------------------------------------------------------------

---@class org.images.Backend
---@field name string
---@field show fun(bufnr: integer, p: org.images.Preview, row: integer, col: integer)
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
-- reserve (or free) the rows under the line.
backends.native = {
  name = "native",
  needs_png = true,
  show = function(bufnr, p, row, _)
    p.lines = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      id = p.lines,
      virt_lines = vim.fn["repeat"]({ { { "", "Normal" } } }, p.height),
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
  show = function(bufnr, p, row, col)
    p.handle = Snacks.image.placement.new(bufnr, p.src, {
      pos = { row + 1, col },
      inline = true,
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
  show = function(bufnr, p, row, col)
    local win = vim.fn.bufwinid(bufnr)
    local image = require("image").from_file(p.src, {
      window = win ~= -1 and win or nil,
      buffer = bufnr,
      inline = true,
      with_virtual_padding = true,
      x = col,
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
    if p.handle then
      pcall(p.handle.clear, p.handle)
      p.handle = nil
    end
  end,
}

local function snacks_ok()
  return type(_G.Snacks) == "table"
    and pcall(function()
      return Snacks.image.placement
    end)
    and Snacks.image.supports_terminal()
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

local function buf_previews(bufnr)
  previews[bufnr] = previews[bufnr] or {}
  return previews[bufnr]
end

local function mark_pos(bufnr, p)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, p.mark, { details = true })
  if not m[1] or (m[3] and m[3].invalid) then
    return nil
  end
  return m[1], m[2], m[3]
end

local function remove(bufnr, id)
  local list = previews[bufnr]
  local p = list and list[id]
  if not p then
    return
  end
  local b = M._backend or backends[p.backend]
  if b then
    pcall(b.hide, bufnr, p)
  end
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.mark)
  list[id] = nil
  M._schedule_sync()
end

--- Previews of `kind` overlapping rows `first..last` (1-based).
local function previews_in(bufnr, first, last, kind)
  local out = {}
  for id, p in pairs(previews[bufnr] or {}) do
    local row = mark_pos(bufnr, p)
    if (not kind or p.kind == kind) and row and row + 1 >= first and row + 1 <= last then
      out[#out + 1] = id
    end
  end
  return out
end

--- Remove the previews of `kind` (all when nil) in rows `first..last`.
function M.clear(bufnr, first, last, kind)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local ids = previews_in(bufnr, first or 1, last or math.huge, kind)
  for _, id in ipairs(ids) do
    remove(bufnr, id)
  end
  return #ids
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
  local mw = max_width(win)
  local w, h
  if pw then
    local want = spec.width and math.max(1, math.floor(spec.width / cell.w + 0.5)) or nil
    w, h = M.fit(pw, ph, mw, opts().max_height, want)
  else
    w, h = mw, math.min(opts().max_height or 20, 10)
  end
  next_id = next_id + 1
  local p = {
    id = next_id,
    kind = kind,
    src = file,
    width = w,
    height = h,
    backend = backend.name,
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, spec.row - 1, spec.col, {
      end_row = (spec.end_row or spec.row) - 1,
      end_col = spec.end_col,
      invalidate = true,
      undo_restore = false,
    }),
  }
  local ok, err = pcall(backend.show, bufnr, p, (spec.end_row or spec.row) - 1, spec.col)
  if not ok then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, p.mark)
    return false, tostring(err)
  end
  buf_previews(bufnr)[p.id] = p
  M.attach(bufnr)
  M._schedule_sync()
  return true
end

--- Show image links in rows `first..last`. Returns the number shown.
function M.show_links(bufnr, first, last, include_linked)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b, why = M.backend()
  if not b then
    utils.warn(why)
    return 0
  end
  ask_cell_size()
  M.clear(bufnr, first, last, "link")
  local n, failed = 0, nil
  for _, lk in ipairs(M.find_image_links(bufnr, first, last, include_linked)) do
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

--- Render and show the LaTeX fragments in rows `first..last`. Rendering is
--- asynchronous; `done(n)` is called with the number shown.
function M.show_latex(bufnr, first, last, done)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b, why = M.backend()
  if not b then
    utils.warn(why)
    return
  end
  ask_cell_size()
  M.clear(bufnr, first, last, "latex")
  local frags = M.find_latex_fragments(bufnr, first, last)
  if #frags == 0 then
    if done then
      done(0)
    end
    return
  end
  local left, n, failed = #frags, 0, nil
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  for _, f in ipairs(frags) do
    M.render_latex(f.text, bufnr, function(png, err)
      left = left - 1
      if png and vim.api.nvim_buf_is_valid(bufnr) then
        -- the fragment must still be there
        local now = vim.api.nvim_buf_get_changedtick(bufnr) == tick
          or (vim.api.nvim_buf_get_lines(bufnr, f.row - 1, f.row, false)[1] or ""):find(
            vim.split(f.text, "\n")[1],
            1,
            true
          )
        if now then
          local ok, e = add(bufnr, "latex", f, png, b)
          n = n + (ok and 1 or 0)
          failed = failed or (not ok and e) or nil
        end
      else
        failed = failed or err
      end
      if left == 0 then
        if failed then
          utils.warn("LaTeX preview: " .. failed)
        end
        if done then
          done(n)
        end
      end
    end)
  end
end

---------------------------------------------------------------------------
-- Native placement
---------------------------------------------------------------------------

-- placed["win:id"] = { id = vim.ui.img id, opts = {...} }
local placed = {}
local data_cache = {} ---@type table<string, string>

local function float_rects()
  local rects = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative and cfg.relative ~= "" and not cfg.hide then
      local pos = vim.api.nvim_win_get_position(w)
      local border = cfg.border and cfg.border ~= "none" and cfg.border ~= "" and 1 or 0
      rects[#rects + 1] = {
        top = pos[1] + 1 - border,
        left = pos[2] + 1 - border,
        bottom = pos[1] + vim.api.nvim_win_get_height(w) + border,
        right = pos[2] + vim.api.nvim_win_get_width(w) + border,
      }
    end
  end
  return rects
end

local function overlaps(r, row, col, w, h)
  return not (row > r.bottom or row + h - 1 < r.top or col > r.right or col + w - 1 < r.left)
end

--- Where every native preview should be on the screen right now.
---@return table<string, { src: string, opts: vim.ui.img.Opts }>
function M._layout()
  local want = {}
  local floats = float_rects()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local list = previews[bufnr]
    local cfg = vim.api.nvim_win_get_config(win)
    if list and next(list) and (cfg.relative == nil or cfg.relative == "") then
      local info = vim.fn.getwininfo(win)[1]
      local top, bottom = info.winrow, info.winrow + info.height - 1
      local right = info.wincol + info.width - 1
      local rows = {}
      for _, p in pairs(list) do
        if p.backend == "native" then
          local r, c, d = mark_pos(bufnr, p)
          if r then
            local anchor = (d and d.end_row or r)
            rows[anchor] = rows[anchor] or {}
            table.insert(rows[anchor], { p = p, col = c })
          end
        end
      end
      for anchor, items in pairs(rows) do
        local lnum = anchor + 1
        if lnum >= info.topline and lnum <= info.botline then
          local folded = vim.api.nvim_win_call(win, function()
            return vim.fn.foldclosed(lnum)
          end)
          local line = vim.api.nvim_buf_get_lines(bufnr, anchor, anchor + 1, false)[1] or ""
          local last = vim.fn.screenpos(win, lnum, math.max(1, #line))
          if folded == -1 and last.row > 0 then
            table.sort(items, function(a, b)
              return a.col < b.col
            end)
            local y = last.row + 1
            for _, it in ipairs(items) do
              local p = it.p
              local x = vim.fn.screenpos(win, lnum, math.min(it.col + 1, math.max(1, #line))).col
              if x == 0 then
                x = info.wincol + info.textoff
              end
              if x + p.width - 1 > right then
                x = math.max(info.wincol + info.textoff, right - p.width + 1)
              end
              local visible = y >= top and y + p.height - 1 <= bottom
              for _, r in ipairs(floats) do
                visible = visible and not overlaps(r, y, x, p.width, p.height)
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
  for key, w in pairs(want) do
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
      any = any or next(list) ~= nil
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

--- Watch the buffer for edits that remove previewed links, and show the
--- `#+STARTUP` previews.
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
        if not mark_pos(bufnr, p) then
          remove(bufnr, id)
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
      attached[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

--- Called for every org buffer: show startup previews once it is visible.
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

-- A floating window (a menu waiting for a key) must not be covered by an
-- image: place them at once, a scheduled sync would only run after the key.
vim.api.nvim_create_autocmd("WinNew", {
  group = vim.api.nvim_create_augroup("org.images.floats", { clear = true }),
  callback = function()
    if next(placed) then
      pcall(M.sync)
    end
  end,
})

-- The terminal forgets images when the screen is cleared or resized.
vim.api.nvim_create_autocmd({ "VimResized", "VimResume", "FocusGained", "UIEnter" }, {
  group = vim.api.nvim_create_augroup("org.images", { clear = true }),
  callback = function(ev)
    if ev.event == "VimResized" then
      -- the font size may have changed too
      cell.asked = false
    end
    if next(placed) then
      vim.schedule(function()
        M.sync(true)
      end)
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

--- org-link-preview (C-c C-x C-v): preview the image link at the cursor,
--- the links of the Visual selection or of the current entry; again to
--- hide them. Counts like the Emacs prefix argument: 4 hides the entry's
--- previews, 16 shows the whole buffer, 64 hides the whole buffer; 1 and
--- 11 also preview links with a description (entry / buffer).
function M.link_preview(arg)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local include = arg == 1 or arg == 11
  local vfirst, vlast = visual_rows()
  if arg == 64 then
    local n = M.clear(bufnr, 1, math.huge, "link")
    utils.notify(n > 0 and "Link previews removed from the buffer" or "No link previews to remove")
    return
  elseif arg == 16 or arg == 11 then
    local n = M.show_links(bufnr, 1, math.huge, include)
    utils.notify(
      n > 0 and string.format("%d link preview%s in the buffer", n, n == 1 and "" or "s") or "No images to preview"
    )
    return
  end
  local first, last
  if vfirst then
    first, last = vfirst, vlast
  else
    -- the link at the cursor alone
    for _, lk in ipairs(M.find_image_links(bufnr, lnum, lnum, true)) do
      if col >= lk.col and col < lk.end_col then
        first, last = lnum, lnum
        break
      end
    end
    if not first then
      first, last = section_rows(bufnr, lnum)
    end
  end
  if arg == 4 or (not arg and #previews_in(bufnr, first, last, "link") > 0) then
    local n = M.clear(bufnr, first, last, "link")
    if n > 0 or arg == 4 then
      utils.notify(n > 0 and "Link previews removed" or "No link previews to remove")
      return
    end
  end
  local n = M.show_links(bufnr, first, last, include)
  if n == 0 and M.backend() then
    utils.notify("No images to preview here")
  end
end

--- org-link-preview-refresh (C-c C-x C-M-v): preview every image link of
--- the buffer again (after the files changed).
function M.link_preview_refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  data_cache = {}
  local n = M.show_links(bufnr, 1, math.huge)
  M.sync(true)
  utils.notify(string.format("%d link preview%s refreshed", n, n == 1 and "" or "s"))
end

--- org-latex-preview (C-c C-x C-l): preview the fragment at the cursor, or
--- the fragments of the Visual selection or the current entry; again to
--- hide them. 4 hides the entry's previews, 16 previews the whole buffer,
--- 64 hides the whole buffer.
function M.latex_preview(arg)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local vfirst, vlast = visual_rows()
  if arg == 64 then
    M.clear(bufnr, 1, math.huge, "latex")
    utils.notify("LaTeX previews removed from buffer")
    return
  elseif arg == 16 then
    utils.notify("Creating LaTeX previews in buffer...")
    M.show_latex(bufnr, 1, math.huge, function(n)
      utils.notify(string.format("Creating LaTeX previews in buffer... done (%d)", n))
    end)
    return
  end
  local first, last
  if vfirst then
    first, last = vfirst, vlast
  else
    for _, f in ipairs(M.find_latex_fragments(bufnr, lnum, lnum)) do
      if f.row == lnum and col >= f.col and col < f.end_col then
        first, last = f.row, f.end_row
        break
      end
    end
    if not first then
      first, last = section_rows(bufnr, lnum)
    end
  end
  if arg == 4 or (not arg and #previews_in(bufnr, first, last, "latex") > 0) then
    M.clear(bufnr, first, last, "latex")
    utils.notify("LaTeX previews removed")
    return
  end
  M.show_latex(bufnr, first, last, function(n)
    if n == 0 then
      utils.notify("No LaTeX fragments to preview here")
    end
  end)
end

return M
