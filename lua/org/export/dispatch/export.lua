---@mod org.export.dispatch.export Exporting a buffer
---
--- Export a buffer to a file or a temporary buffer with a native back-end
--- or pandoc (org-export-to-file, org-export-to-buffer), and render to a
--- string (org-export-as).
---
--- Part of org.export, which loads it.

local utils = require("org.utils")
local shared = require("org.export.dispatch.shared")

local M = require("org.export")

local PANDOC_EXT = shared.PANDOC_EXT
local FILETYPES = shared.FILETYPES
local cfg = shared.cfg
local ox = shared.ox
local buffer_lines = shared.buffer_lines
local resolve = shared.resolve
local open_scratch = shared.open_scratch
local write_text = shared.write_text
local run = shared.run
local pandoc_cmd = shared.pandoc_cmd

--- The output formats the pandoc fallback knows (`pandoc
--- --list-output-formats`), or nil when pandoc can't be run.
---@return string[]|nil
function M.pandoc_output_formats()
  local cmd = pandoc_cmd()
  if not cmd[1] or vim.fn.executable(cmd[1]) == 0 then
    return nil
  end
  cmd[#cmd + 1] = "--list-output-formats"
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(10000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.split(res.stdout or "", "%s+", { trimempty = true })
end

--- Render with a native back-end.
---@return string|nil text, table|nil info, string|nil err
local function render(backend, lines, opts)
  local ok, text, info = pcall(ox().export_as, backend, lines, opts)
  if not ok then
    return nil, nil, tostring(text)
  end
  return text, info
end

--- Export a buffer.
--- With a compiler or converter left running in the background (PDF with
--- `export.latex.async_compile`, ODT conversion with
--- `export.odt.async_convert`, or `opts.async`), the process is returned
--- too, and `opts.on_done(result|nil, err|nil)` is called when it is done.
---@param format string html|md|gfm|txt|ascii|latin1|utf8|latex|pdf|beamer|org|ics|<pandoc format>
---@param opts? { bufnr?: integer, subtree?: boolean, subtree_line?: integer, body_only?: boolean, visible_only?: boolean, to_buffer?: boolean, hidden?: boolean, interactive?: boolean, open?: boolean, output?: string, async?: boolean, ext?: table, options?: table, on_done?: fun(result: string?, err: string?) }
---@return string|nil output path (or "buffer") / nil on failure
---@return org.export.Process? process running in the background
function M.export(format, opts)
  opts = opts or {}
  local bufnr, subtree_line = resolve(opts)
  local lines = buffer_lines(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local src = bufname ~= "" and bufname or nil
  local spec = M.FORMATS[format]
  if spec and spec[1] == "texinfo" and not spec.info and (cfg().texinfo or {}).use_pandoc then
    spec = nil -- pandoc fallback (export.texinfo.use_pandoc)
  end
  if spec and spec[1] == "icalendar" then
    return require("org.export.icalendar").export_file(bufnr, opts --[[@as table]])
  end
  local ext = vim.tbl_extend("force", opts.ext or {}, opts.options or {})
  local xopts = {
    filename = src,
    bufnr = bufnr,
    subtree_line = subtree_line,
    body_only = opts.body_only,
    visible_only = opts.visible_only,
    ext = ext,
  }
  if spec and spec[1] == "odt" then
    if (cfg().odt or {}).use_pandoc then
      spec = nil
    else
      return require("org.export.odt").export_file(lines, xopts, opts, src)
    end
  end
  if not spec then
    -- pandoc: convert the Org export of the buffer
    local text, info, err = render("org", lines, xopts)
    if not text then
      utils.error("Export failed: " .. err)
      return nil
    end
    local cmd, extra = pandoc_cmd()
    if vim.fn.executable(cmd[1]) == 0 then
      utils.error("pandoc not found (needed for " .. format .. " export). Install pandoc or set export.pandoc.cmd")
      return nil
    end
    -- named by #+EXPORT_FILE_NAME / the subtree's property like native exports
    local out = opts.output or M.output_file_name(src, PANDOC_EXT[format] or format, info)
    vim.list_extend(cmd, { "-f", "org", "-t", format, "-o", out })
    if not opts.body_only then
      cmd[#cmd + 1] = "--standalone"
    end
    vim.list_extend(cmd, extra)
    local cwd = src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd()
    local res = run(cmd, { stdin = text, cwd = cwd, text = true })
    if res.code ~= 0 then
      utils.error("pandoc failed:\n" .. (res.stderr or ""))
      return nil
    end
    utils.notify("Exported to " .. out)
    if opts.open or cfg().open_after_export then
      vim.ui.open(out)
    end
    return out
  end
  local backend, extension, charset = spec[1], spec[2], spec[3]
  if backend == "html" then
    extension = (cfg().html or {}).extension or "html"
  end
  if charset then
    ext.ascii_charset = charset
  end
  if backend == "texinfo" and not opts.to_buffer and ext.output_file == nil then
    -- @setfilename / @direntry name the output file (relative to the source)
    ext.texinfo_output_file = function(info)
      local out = opts.output or M.output_file_name(src, extension, info)
      local dir = src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd()
      local rel = ox().relative_path(out, dir)
      return rel:match("^%.%./") and out or rel
    end
  end
  local text, info, err = render(backend, lines, xopts)
  if not text then
    utils.error("Export failed: " .. err)
    return nil
  end
  if opts.to_buffer then
    local name = backend == "org" and "Org ORG Export" or ("Org " .. backend:upper() .. " Export")
    M.last_buffer = open_scratch(text, FILETYPES[backend], name, opts.hidden)
    M.maybe_copy(text, opts.interactive)
    return "buffer"
  end
  local out = opts.output or M.output_file_name(src, extension, info)
  write_text(out, text)
  M.maybe_copy(text, opts.interactive)
  if spec.pdf then
    return M.compile_pdf(out, vim.tbl_extend("force", opts, { backend = backend }))
  end
  if spec.info then
    return M.compile_info(out, opts)
  end
  if spec.man_pdf then
    return M.compile_man_pdf(out, opts)
  end
  utils.notify("Exported to " .. out)
  if opts.open or cfg().open_after_export then
    vim.ui.open(out)
  end
  return out
end

--- Render a buffer (or `opts.lines`) to a string without writing
--- anything (for tests / API). Native formats only.
---
--- ```lua
--- local html = require("org.export").to_string("html", { body_only = true })
--- ```
---@param format string
---@param opts? { bufnr?: integer, lines?: string[], filename?: string, subtree_line?: integer, body_only?: boolean, visible_only?: boolean, no_final_newline?: boolean, ext?: table, options?: table }
---@return string
function M.to_string(format, opts)
  opts = opts or {}
  local spec = M.FORMATS[format]
  if not spec then
    error("to_string: unsupported format " .. tostring(format))
  end
  local bufnr = opts.bufnr
  if not opts.lines then
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if bufnr == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    end
  end
  local lines = opts.lines or buffer_lines(bufnr)
  local ext = vim.tbl_extend("force", opts.ext or {}, opts.options or {})
  if spec[1] == "odt" then
    require("org.export.odt")
  end
  if spec[3] then
    ext.ascii_charset = spec[3]
  end
  local filename = opts.filename
  if not filename and bufnr and not opts.lines then
    local n = vim.api.nvim_buf_get_name(bufnr)
    filename = n ~= "" and n or nil
  end
  return (
    ox().export_as(spec[1], lines, {
      filename = filename,
      bufnr = bufnr,
      subtree_line = opts.subtree_line,
      body_only = opts.body_only,
      visible_only = opts.visible_only,
      no_final_newline = opts.no_final_newline,
      ext = ext,
    })
  )
end
