---@mod org.export.odt.convert ODT conversion and export
---
--- Converting the .odt file (org-odt-convert), exporting a LaTeX
--- fragment as an ODF formula, and writing the package.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local zip = require("org.export.zip")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw

local ocfg = shared.ocfg
local format_spec = shared.format_spec
local shellescape = shared.shellescape
local sh = shared.sh

---------------------------------------------------------------------------
-- Conversion (org-odt-convert)
---------------------------------------------------------------------------

--- org-odt-do-reachable-formats: { converter-cmd, output formats } list.
local function reachable_formats(in_fmt)
  local c = ocfg()
  local process = c.convert_process
  if process == nil then
    process = "LibreOffice"
  end
  if not process then
    return {}
  end
  local cmd
  for _, p in ipairs(c.convert_processes or M.CONVERT_PROCESSES) do
    if p[1]:lower() == tostring(process):lower() then
      cmd = p[2]
    end
  end
  if not cmd then
    return {}
  end
  local out = {}
  for _, cap in ipairs(c.convert_capabilities or M.CONVERT_CAPABILITIES) do
    if vim.tbl_contains(cap[2], in_fmt) then
      out[#out + 1] = { cmd, cap[3] }
    end
  end
  return out
end

--- Output formats `in_fmt` files can be converted to (org-odt-reachable-formats).
function M.reachable_formats(in_fmt)
  local out = {}
  for _, e in ipairs(reachable_formats(in_fmt)) do
    for _, f in ipairs(e[2]) do
      out[#out + 1] = f[1]
    end
  end
  return out
end

local function file_url(path)
  return "file://" .. (path:gsub("[^%w%-%._~/]", function(ch)
    return fmt("%%%02X", ch:byte())
  end))
end

--- Convert `in_file` to `out_fmt` with `export.odt.convert_process`
--- (org-odt-convert). Returns the converted file or nil. With `on_done`
--- the converter runs in the background: on_done(file|nil, err|nil) is
--- called when it is done and the running process is returned (see
--- org.export.process; nil when the conversion can't start).
---@param in_file string
---@param out_fmt string
---@param open? boolean open the converted file
---@param on_done? fun(file: string?, err: string?)
---@return any
function M.convert(in_file, out_fmt, open, on_done)
  local utils = require("org.utils")
  -- lint: allow expand: a file the caller or user named
  in_file = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(in_file), ":p"))
  if vim.fn.filereadable(in_file) == 0 then
    utils.error("Cannot read " .. in_file)
    return nil
  end
  local in_fmt = (in_file:match("%.([%w]+)$") or ""):lower()
  local how
  for _, e in ipairs(reachable_formats(in_fmt)) do
    for _, f in ipairs(e[2]) do
      if f[1] == out_fmt and not how then
        how = { e[1], f }
      end
    end
  end
  if not how then
    utils.error(fmt("Cannot convert from %s format to %s format?", in_fmt, out_fmt))
    return nil
  end
  local out_file = in_file:gsub("%.[^./]*$", "") .. "." .. (how[2][2] or out_fmt)
  local out_dir = vim.fn.fnamemodify(in_file, ":h") .. "/"
  local cmd = format_spec(how[1], {
    i = shellescape(in_file),
    I = file_url(in_file),
    f = out_fmt,
    o = shellescape(out_file),
    O = file_url(out_file),
    d = shellescape(out_dir),
    D = file_url(out_dir),
    x = how[2][3] or "",
  })
  if vim.fn.filereadable(out_file) == 1 then
    os.remove(out_file)
  end
  local function result(output, cancelled)
    if not cancelled and vim.fn.filereadable(out_file) == 1 then
      utils.notify("Exported to " .. out_file)
      if open then
        vim.ui.open(out_file)
      end
      return out_file
    end
    if cancelled then
      return nil, "Conversion to " .. out_file .. " cancelled"
    end
    local err = "Export to " .. out_file .. " failed\n" .. output
    utils.error(err)
    return nil, err
  end
  if on_done then
    utils.notify("Executing " .. cmd)
    local shell = vim.fn.has("win32") == 1 and { vim.o.shell, vim.o.shellcmdflag } or { "sh", "-c" }
    return require("org.export.process").run({ cmd }, { cwd = out_dir, shell = shell }, function(run)
      on_done(result(run:text(), run.cancelled))
    end)
  end
  local res = sh(cmd, out_dir)
  return (result((res.stdout or "") .. (res.stderr or "")))
end

--- org-odt-convert as a command: ask for the file (default the buffer's)
--- and one of the output formats it can be converted to; a count opens the
--- result (C-u).
function M.convert_command()
  local utils = require("org.utils")
  local current = vim.api.nvim_buf_get_name(0)
  local in_file = utils.input({ prompt = "File to be converted: ", default = current, completion = "file" })
  if not in_file or vim.trim(in_file) == "" then
    return nil
  end
  in_file = vim.trim(in_file)
  local in_fmt = (in_file:match("%.([%w]+)$") or ""):lower()
  local choices = M.reachable_formats(in_fmt)
  if #choices == 0 then
    utils.error(fmt("No known converter or no known output formats for %s files", in_fmt))
    return nil
  end
  local open = vim.v.count > 0
  local out_fmt = require("org.ui").choose({ prompt = "Output format: ", title = "Convert to", items = choices })
  if not out_fmt or out_fmt == "" then
    return nil
  end
  return M.convert(in_file, out_fmt, open)
end

--- The first LaTeX fragment of `s` (org-latex-regexps, in their order).
function M.find_latex_fragment(s)
  local a = s:match("^[ \t]*(\\begin{[%w*]+}.-\\end{[%w*]+}[ \t]*\n?)")
    or s:match("\n[ \t]*(\\begin{[%w*]+}.-\\end{[%w*]+}[ \t]*\n?)")
  if a then
    return a
  end
  for _, pat in ipairs({ "^%$[^ \t\r\n,;.$]%$", "^%$[^ \t\n,;.$][^$\n\r]-[^ \t\n,.$]%$" }) do
    for i = 1, #s do
      if s:sub(i, i) == "$" and (i == 1 or s:sub(i - 1, i - 1) ~= "$") then
        local m = s:sub(i):match(pat)
        if m then
          return m
        end
      end
    end
  end
  return s:match("(\\%(.-\\%))") or s:match("(\\%[.-\\%])") or s:match("(%$%$.-%$%$)")
end

--- Export a LaTeX fragment as an OpenDocument formula file
--- (org-odt-export-as-odf): the fragment is converted to MathML with
--- `export.odt.latex_to_mathml_convert_command` and written as the
--- content.xml of FILE.odf. Interactively the fragment comes from the
--- Visual selection (its first LaTeX fragment) or a prompt, and the file
--- name from a prompt (default: the buffer's name with .odf). The MathML is
--- copied like the export output (`export.copy_to_kill_ring`).
---@param latex_frag? string
---@param odf_file? string
---@return string? odf file
function M.export_as_odf(latex_frag, odf_file)
  local utils = require("org.utils")
  local src = vim.api.nvim_buf_get_name(0)
  local default_file = (src ~= "" and vim.fn.fnamemodify(src, ":p:r") or (vim.fn.getcwd() .. "/formula")) .. ".odf"
  local interactive = latex_frag == nil
  if interactive then
    local frag
    local m = vim.fn.mode()
    if m == "v" or m == "V" or m == "\22" then
      local srow, scol, erow, ecol, mode = utils.visual_range()
      utils.exit_visual()
      local text
      if mode == "v" then
        local last = vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or ""
        local e = math.min(#last, ecol)
        text = table.concat(vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, e, {}), "\n")
      else
        text = table.concat(vim.api.nvim_buf_get_lines(0, srow - 1, erow, false), "\n")
      end
      frag = M.find_latex_fragment(text)
    end
    latex_frag = utils.input({ prompt = "LaTeX Fragment: ", default = frag })
    if not latex_frag or latex_frag == "" then
      return nil
    end
    odf_file = utils.input({ prompt = "ODF filename: ", default = default_file, completion = "file" })
    if not odf_file or odf_file == "" then
      return nil
    end
  end
  -- lint: allow expand: a file the user typed
  odf_file = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(odf_file or default_file), ":p"))
  local mathml = M.latex_to_mathml(latex_frag)
  if not mathml then
    utils.error("No Math formula created")
    return nil
  end
  local mimetype = "application/vnd.oasis.opendocument.formula"
  local manifest = M.manifest_xml({ { "text/xml", "content.xml" }, { mimetype, "/", "1.2" } })
  vim.fn.mkdir(vim.fn.fnamemodify(odf_file, ":h"), "p")
  local ok, err = zip.write(odf_file, {
    { name = "mimetype", data = mimetype },
    { name = "content.xml", data = mathml },
    { name = "META-INF/" },
    { name = "META-INF/manifest.xml", data = manifest },
  })
  if not ok then
    utils.error("OpenDocument formula export failed: " .. tostring(err))
    return nil
  end
  require("org.export").maybe_copy(mathml, interactive)
  utils.notify("Created " .. odf_file)
  return odf_file
end

--- org-odt-export-as-odf-and-open
function M.export_as_odf_and_open()
  local out = M.export_as_odf()
  if out then
    vim.ui.open(out)
  end
  return out
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- Write the OpenDocument package of an export to `out`.
---@return boolean ok, string? err
function M.write_package(out, content, info)
  local ok, entries = pcall(M.package_entries, content, info)
  if not ok then
    return false, tostring(entries)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
  return zip.write(out, entries)
end

--- Export `lines` to an .odt file (org-odt-export-to-odt).
--- A conversion to `preferred_output_format` runs in the background with
--- `opts.async` (by default `export.odt.async_convert` when there is a
--- UI): the .odt is returned with the running converter.
---@param lines string[]
---@param xopts table options of ox.export_as
---@param opts? { output?: string, open?: boolean, async?: boolean, on_done?: fun(file: string?, err: string?) }
---@param src? string visited file
---@return string? output path
---@return org.export.Process? converter running in the background
function M.export_file(lines, xopts, opts, src)
  opts = opts or {}
  local utils = require("org.utils")
  xopts = vim.tbl_extend("force", xopts or {}, { body_only = false })
  local ok, content, info = pcall(ox.export_as, "odt", lines, xopts)
  if not ok then
    utils.error("OpenDocument export failed: " .. tostring(content))
    return nil
  end
  local out = opts.output or require("org.export").output_file_name(src, "odt", info)
  local wok, err = M.write_package(out, content, info)
  if not wok then
    utils.error("OpenDocument export failed: " .. tostring(err))
    return nil
  end
  utils.notify("Created " .. out)
  local c = require("org.config").opts.export or {}
  local open = opts.open or c.open_after_export
  local preferred = ocfg().preferred_output_format
  local result = out
  if nw(preferred) and preferred ~= "odt" then
    local async = opts.async
    if async == nil then
      async = ocfg().async_convert ~= false and #vim.api.nvim_list_uis() > 0
    end
    if async then
      -- the converter runs in the background, on the export stack
      local export, entry, proc = require("org.export"), nil, nil
      proc = M.convert(out, preferred, false, function(file, err)
        if proc.cancelled then
          return export.stack_job_done(entry, opts, nil, err)
        end
        if open then
          vim.ui.open(file or out)
        end
        export.stack_job_done(entry, opts, file or out)
      end)
      if proc then
        entry = export.stack_job(proc, "odt", opts)
        return out, proc
      end
    else
      result = M.convert(out, preferred) or out
    end
  end
  if open then
    vim.ui.open(result)
  end
  return result
end
