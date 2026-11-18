---@mod org.export Export dispatcher
---
--- Native back-ends ported from Emacs Org 9.8 (ox-*.el): html, latex (and
--- pdf through latexmk/pdflatex), beamer, md (ox-md), gfm (GitHub
--- flavoured Markdown, plugin specific), ascii (plain text with the
--- ascii, latin1 or utf-8 charset), org, icalendar, odt (OpenDocument Text,
--- ox-odt), texinfo (and info through makeinfo), koma-letter (KOMA-Script
--- letters, ox-koma-letter, and their PDF) and man (ox-man, and man-pdf
--- through groff). Other formats are
--- produced by pandoc from the Org export of the buffer (odt too with
--- `export.odt.use_pandoc`).
---
--- This file holds the format tables and the helpers the whole dispatcher
--- shares (output file names, the temporary export buffer, writing files,
--- running pandoc); the rest loads from org/export/dispatch/: export
--- (exporting a buffer and rendering to a string), compile (PDF, Info and
--- man PDF compilation), stack (the export stack), async (exports in a
--- separate Neovim), region (converting a region in place), template (the
--- default export template) and menu (the dispatcher and the commands).

local utils = require("org.utils")

local M = {}
-- The parts in org/export/dispatch/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.export"] = M

--- format -> { backend, extension, charset? }
M.FORMATS = {
  html = { "html" },
  htm = { "html" },
  md = { "md", "md" },
  markdown = { "md", "md" },
  gfm = { "gfm", "md" },
  ["md-gfm"] = { "gfm", "md" },
  ascii = { "ascii", "txt", "ascii" },
  txt = { "ascii", "txt" },
  text = { "ascii", "txt" },
  latin1 = { "ascii", "txt", "latin1" },
  utf8 = { "ascii", "txt", "utf-8" },
  ["utf-8"] = { "ascii", "txt", "utf-8" },
  latex = { "latex", "tex" },
  tex = { "latex", "tex" },
  pdf = { "latex", "tex", pdf = true },
  beamer = { "beamer", "tex" },
  ["beamer-pdf"] = { "beamer", "tex", pdf = true },
  org = { "org", "org" },
  ics = { "icalendar", "ics" },
  icalendar = { "icalendar", "ics" },
  texinfo = { "texinfo", "texi" },
  texi = { "texinfo", "texi" },
  info = { "texinfo", "texi", info = true },
  odt = { "odt", "odt" },
  koma = { "koma-letter", "tex" },
  ["koma-letter"] = { "koma-letter", "tex" },
  ["koma-pdf"] = { "koma-letter", "tex", pdf = true },
  man = { "man", "man" },
  ["man-pdf"] = { "man", "man", man_pdf = true },
}

--- Kept for backward compatibility: native formats -> module.
M.BACKENDS = {
  html = "org.export.html",
  md = "org.export.markdown",
  gfm = "org.export.gfm",
  txt = "org.export.ascii",
  latex = "org.export.latex",
  beamer = "org.export.beamer",
  org = "org.export.org",
}

local PANDOC_EXT = {
  docx = "docx",
  odt = "odt",
  rst = "rst",
  epub = "epub",
  epub3 = "epub",
  rtf = "rtf",
  asciidoc = "adoc",
  mediawiki = "wiki",
  textile = "textile",
  jira = "jira",
  pptx = "pptx",
  typst = "typ",
  json = "json",
  revealjs = "html",
  dokuwiki = "txt",
  ipynb = "ipynb",
  texinfo = "texi",
}

local FILETYPES = {
  html = "html",
  md = "markdown",
  gfm = "markdown",
  ascii = "text",
  latex = "tex",
  beamer = "tex",
  org = "org",
  icalendar = "icalendar",
}
FILETYPES.texinfo = "texinfo"
FILETYPES["koma-letter"] = "tex"
FILETYPES.man = "nroff"

local function cfg()
  return require("org.config").opts.export or {}
end

local function ox()
  return require("org.export.ox")
end

local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Resolve export options: { bufnr, subtree_line, visible_only, ... }.
local function resolve(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local subtree_line = opts.subtree_line
  if opts.subtree and not subtree_line then
    subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  end
  return bufnr, subtree_line
end

--- Output file name (org-export-output-file-name).
---@param src string|nil visited file
---@param ext string extension without dot
---@param info table|nil export info (EXPORT_FILE_NAME)
---@param pub_dir string|nil
function M.output_file_name(src, ext, info, pub_dir)
  local base
  if info then
    base = info.subtree_props and info.subtree_props.EXPORT_FILE_NAME
    if not base and info.keywords and info.keywords.EXPORT_FILE_NAME then
      base = info.keywords.EXPORT_FILE_NAME[1]
    end
  end
  local dir
  if base then
    base = utils.expand(base, src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd())
  else
    if not src or src == "" then
      base = vim.fn.getcwd() .. "/export"
    else
      base = vim.fn.fnamemodify(src, ":p"):gsub("%.gpg$", "")
    end
    if cfg().output_dir then
      dir = utils.expand(cfg().output_dir, src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd())
    end
  end
  -- file-name-sans-extension: the last extension, not a leading dot
  base = vim.fn.fnamemodify(base, ":r")
  local out = base .. "." .. ext
  if pub_dir then
    out = vim.fs.normalize(pub_dir .. "/" .. vim.fn.fnamemodify(out, ":t"))
  elseif dir then
    out = vim.fs.normalize(dir .. "/" .. vim.fn.fnamemodify(out, ":t"))
  end
  if src and vim.fs.normalize(vim.fn.fnamemodify(src, ":p")) == vim.fs.normalize(out) then
    out = out .. "." .. ext
  end
  return out
end

--- The temporary export buffer; shown in a split unless
--- `export.show_temporary_export_buffer` is false (or `hidden`).
local function open_scratch(text, ft, name, hidden)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
  vim.bo[buf].filetype = ft or ""
  pcall(vim.api.nvim_buf_set_name, buf, name .. " #" .. buf)
  vim.bo[buf].modified = false
  if not hidden and cfg().show_temporary_export_buffer ~= false then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
  return buf
end

--- Write `text` to `path` in `export.coding_system` (org-export-coding-system;
--- nil = UTF-8).
local function write_text(path, text)
  local coding = cfg().coding_system
  if coding and not coding:lower():match("^utf%-?8") then
    local converted = vim.fn.iconv(text, "utf-8", coding)
    if converted ~= "" or text == "" then
      text = converted
    end
  end
  utils.writefile(path, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
end

--- Push the export output to the unnamed register (and the clipboard when
--- available), like org-kill-new, as `export.copy_to_kill_ring` says:
--- true, "if-interactive" (exports started from the dispatcher or a
--- command) or false.
function M.maybe_copy(text, interactive)
  local v = cfg().copy_to_kill_ring
  if not (v == true or (v == "if-interactive" and interactive)) then
    return
  end
  if not text or not text:match("%S") then
    return
  end
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
end

local function run(cmd, opts)
  local ok, obj = pcall(function()
    return vim.system(cmd, opts or {}):wait(opts and opts.timeout or 120000)
  end)
  if not ok then
    return { code = -1, stderr = tostring(obj), stdout = "" }
  end
  return obj
end

local function pandoc_cmd()
  local p = cfg().pandoc or {}
  local cmd = p.cmd or "pandoc"
  local list = type(cmd) == "table" and vim.deepcopy(cmd) or vim.split(cmd, "%s+", { trimempty = true })
  return list, p.args or {}
end

local shared = require("org.export.dispatch.shared")
shared.PANDOC_EXT = PANDOC_EXT
shared.FILETYPES = FILETYPES
shared.cfg = cfg
shared.ox = ox
shared.buffer_lines = buffer_lines
shared.resolve = resolve
shared.open_scratch = open_scratch
shared.write_text = write_text
shared.run = run
shared.pandoc_cmd = pandoc_cmd

require("org.export.dispatch.export")
require("org.export.dispatch.compile")
require("org.export.dispatch.stack")
require("org.export.dispatch.async")
require("org.export.dispatch.region")
require("org.export.dispatch.template")
require("org.export.dispatch.menu")

return M
