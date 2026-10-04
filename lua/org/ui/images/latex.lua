---@mod org.ui.images.latex LaTeX fragments
---
--- Finding LaTeX fragments and rendering them to images
--- (org-create-formula-image).
--- Part of org.ui.images, which loads it.

local utils = require("org.utils")
local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local cache_root = shared.cache_root
local cell = shared.cell
local executable = shared.executable
local latex_opts = shared.latex_opts
local magick_cmd = shared.magick_cmd

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
    local keywords =
      ox.collect_keywords(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), dir, nil, nil, name ~= "" and name or nil)
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
  dir = vim.fs.normalize(utils.expand_vars(dir))
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
  local key = utils.sha256(table.concat({ "v3", process, dpi, doc, bg or "" }, "\0")):sub(1, 40)
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
        local cmd = c:gsub("%%o%%b", utils.gsub_escape(vim.fn.shellescape(dir .. "/" .. base)))
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
