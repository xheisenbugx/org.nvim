---@mod org.export.odt.latex ODT LaTeX conversion
---
--- LaTeX fragments to MathML or images (org-odt--translate-latex-fragments),
--- and the shell helpers they run.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw

local ocfg = shared.ocfg
local read_file = shared.read_file
local format_spec = shared.format_spec

---------------------------------------------------------------------------
-- LaTeX conversion (org-odt--translate-latex-fragments)
---------------------------------------------------------------------------

--- Quote `s` for `sh -c` (see `sh` below). vim.fn.shellescape follows
--- 'shell' instead: with fish it doubles backslashes, with csh it escapes
--- "!", which `sh` would then keep literally (a LaTeX fragment's "\frac"
--- would reach the converter as "\\frac").
local function shellescape(s)
  if vim.fn.has("win32") == 1 then
    return vim.fn.shellescape(s)
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function sh(cmd, cwd)
  local shell = vim.fn.has("win32") == 1 and { vim.o.shell, vim.o.shellcmdflag } or { "sh", "-c" }
  local ok, res = pcall(function()
    return vim.system(vim.list_extend(shell, { cmd }), { cwd = cwd, text = true }):wait(120000)
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return res
end

local function mathml_command()
  local c = ocfg()
  return c.latex_to_mathml_convert_command, c.latex_to_mathml_jar_file
end

--- org-format-latex-mathml-available-p
function M.mathml_available()
  local cmd, jar = mathml_command()
  if not nw(cmd) then
    return false
  end
  local exe = vim.split(vim.trim(cmd), "%s+")[1]
  if vim.fn.executable(exe) == 0 then
    return false
  end
  if cmd:find("%j", 1, true) then
    -- lint: allow expand: the jar option
    return jar ~= nil and vim.fn.filereadable(vim.fn.expand(jar)) == 1
  end
  return true
end

--- org-create-math-formula: MathML of a LaTeX fragment, or nil.
function M.latex_to_mathml(frag)
  local cmd, jar = mathml_command()
  if not nw(cmd) then
    return nil
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tin, tout = dir .. "/ltxmathml-in", dir .. "/ltxmathml-out"
  local f = io.open(tin, "wb")
  if f then
    f:write(frag)
    f:close()
  end
  local full = format_spec(cmd, {
    -- lint: allow expand: the jar option
    j = jar and shellescape(vim.fn.fnamemodify(vim.fn.expand(jar), ":p")) or "",
    I = shellescape(tin),
    i = shellescape(frag),
    o = shellescape(tout),
  })
  local res = sh(full, dir)
  local out = read_file(tout) or ""
  vim.fn.delete(dir, "rf")
  local s = out:find('<math[^>]-xmlns="http://www.w3.org/1998/Math/MathML"[^>]->')
  local e
  if s then
    local p = s
    while true do
      local a, b = out:find("</math>", p, true)
      if not a then
        break
      end
      e, p = b, b + 1
    end
  end
  if not (s and e) then
    require("org.utils").warn("LaTeX to MathML conversion failed\n" .. (res.stdout or "") .. (res.stderr or ""))
    return nil
  end
  return '<?xml version="1.0" encoding="UTF-8"?>\n' .. out:sub(s, e)
end

--- Lisp printed form of a string (prin1-to-string).
local function prin1_string(s)
  if s == nil then
    return "nil"
  end
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The MathML cache file of a fragment (org-format-latex-as-mathml):
--- <org file dir>/<latex_mathml_directory><file>-formula-<sha1>.mathml.
function M.mathml_cache_file(frag, info)
  local input = info.input_file
  if not input then
    return nil
  end
  local cmd = mathml_command()
  local dir = ocfg().latex_mathml_directory or "ltxmathml/"
  if dir ~= "" and not dir:match("/$") then
    dir = dir .. "/"
  end
  local prefix = dir .. vim.fn.fnamemodify(input, ":t:r")
  local absprefix = require("org.utils").is_absolute(prefix) and prefix
    or (vim.fn.fnamemodify(input, ":p:h") .. "/" .. prefix)
  local id = require("org.babel.sha1").hex("(" .. prin1_string(frag) .. " " .. prin1_string(cmd) .. ")")
  return absprefix .. "-formula-" .. id .. ".mathml"
end

--- org-format-latex-as-mathml: the MathML of a fragment, converted once and
--- kept in `export.odt.latex_mathml_directory` (org-latex-mathml-directory).
function M.latex_to_mathml_cached(frag, info)
  local file = M.mathml_cache_file(frag, info)
  if file and vim.uv.fs_stat(file) then
    return read_file(file)
  end
  local mathml = M.latex_to_mathml(frag)
  if mathml and file then
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "wb")
    if f then
      f:write(mathml)
      f:close()
    end
  end
  return mathml
end

local LATEX_IMAGE_PACKAGES = [[
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage{amssymb}]]

local function latex_processes()
  local ok, images = pcall(require, "org.ui.images")
  local all = ok and vim.deepcopy(images.PROCESSES or {}) or {}
  local ui = (require("org.config").opts.ui or {}).latex_preview or {}
  for k, v in pairs(ui.processes or {}) do
    all[k] = v
  end
  return all, ok and images.DEFAULT_HEADER or nil
end

--- The spec of a LaTeX image process (org-preview-latex-process-alist
--- entry: dvipng, dvisvgm, imagemagick or a user process), or nil.
function M.latex_image_process(name)
  return type(name) == "string" and latex_processes()[name] or nil
end

--- Run a shell command (shell-command-to-string): stdout and stderr.
function M.shell_command_to_string(cmd, cwd)
  local res = sh(cmd, cwd)
  return (res.stdout or "") .. (res.stderr or "")
end

M.shellescape = shellescape
M.format_spec = format_spec

--- Programs of a LaTeX image process (org-preview-latex-process-alist)
--- are installed?
local function latex_process_available(name)
  local spec = latex_processes()[name]
  if not spec then
    return nil
  end
  for _, prog in ipairs(spec.programs or {}) do
    if vim.fn.executable(prog) == 0 then
      return false
    end
  end
  return true
end

--- Render a LaTeX fragment to a picture with `process` (org-create-formula-image).
function M.latex_to_image(frag, process, info)
  local all, default_header = latex_processes()
  local spec = all[process]
  if not spec then
    return nil
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local base = "orgtex"
  local header = (spec.latex_header or default_header or "\\documentclass{article}\n[DEFAULT-PACKAGES]\n[PACKAGES]")
    :gsub("%[N?O?%-?DEFAULT%-PACKAGES%]", function()
      return LATEX_IMAGE_PACKAGES
    end)
    :gsub("%[N?O?%-?PACKAGES%]", "")
  if nw(info.latex_header) then
    header = header .. "\n" .. info.latex_header
  end
  local doc = table.concat({
    header,
    "\\begin{document}",
    "\\definecolor{fg}{rgb}{0,0,0}%",
    "{\\color{fg}",
    frag,
    "}",
    "\\end{document}",
    "",
  }, "\n")
  local f = io.open(dir .. "/" .. base .. ".tex", "wb")
  if not f then
    return nil
  end
  f:write(doc)
  f:close()
  local dpi = 140 * (((require("org.config").opts.ui or {}).latex_preview or {}).scale or 1)
  local input = spec.image_input_type or "dvi"
  local ext = spec.image_output_type or "png"
  local function run(cmds, src, out_ext)
    for _, c in ipairs(cmds or {}) do
      local ob = shellescape(dir .. "/" .. base)
      local cmd = c:gsub("%%o%%b", function()
        return ob
      end)
      cmd = format_spec(cmd, {
        b = base,
        f = shellescape(base .. "." .. src),
        F = shellescape(dir .. "/" .. base .. "." .. src),
        o = shellescape(dir .. "/"),
        O = shellescape(dir .. "/" .. base .. "." .. out_ext),
        D = tostring(math.floor(dpi)),
        S = fmt("%.3f", dpi / 140),
      })
      sh(cmd, dir)
    end
    return vim.uv.fs_stat(dir .. "/" .. base .. "." .. out_ext) ~= nil
  end
  if not run(spec.latex_compiler, "tex", input) then
    return nil
  end
  if not run(spec.transparent_image_converter or spec.image_converter, input, ext) then
    return nil
  end
  return dir .. "/" .. base .. "." .. ext
end

-- Locals the later parts share
shared.shellescape = shellescape
shared.sh = sh
shared.latex_processes = latex_processes
shared.latex_process_available = latex_process_available
